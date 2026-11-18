use mimalloc::MiMalloc;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

mod cache;
mod config;
mod db;
mod errors;
mod handlers;
mod validation;

use axum::{
    body::Bytes,
    extract::Path,
    http::Uri,
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use cache::AppCache;
use config::Config;
use sqlx::PgPool;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::net::TcpListener;
use tracing::{info, warn};

/// Shared application state.
struct AppState {
    pool: Arc<PgPool>,
    cache: Arc<AppCache>,
    db_ready: Arc<AtomicBool>,
}

#[tokio::main]
async fn main() {
    // Init logging (warn level only — no per-request logging)
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .init();

    let config = Config::from_env();
    let db_ready = Arc::new(AtomicBool::new(false));

    // Create cache
    let cache = Arc::new(AppCache::new());

    // Connect to DB with retry
    let pool = Arc::new(db::create_pool(&config.database_url, config.db_pool_size).await);

    // Run migrations
    db::run_migrations(&pool).await;

    // Optionally preload products into cache
    preload_products(&pool, &cache).await;

    // Mark DB as ready
    db_ready.store(true, Ordering::SeqCst);
    info!("Database ready, starting HTTP server");

    let state = Arc::new(AppState {
        pool: pool.clone(),
        cache: cache.clone(),
        db_ready: db_ready.clone(),
    });

    // Build router — using closures to capture state, NOT axum extractors
    let app = build_router(state);

    // Bind
    let listener = TcpListener::bind(&config.listen_addr)
        .await
        .expect("Failed to bind");

    info!("Listening on {}", config.listen_addr);

    // Serve with TCP_NODELAY
    axum::serve(listener, app)
        .tcp_nodelay(true)
        .await
        .expect("Server failed");
}

fn build_router(state: Arc<AppState>) -> Router {
    let s = state.clone();
    let health_handler = move || {
        let pool = s.pool.clone();
        let db_ready = s.db_ready.clone();
        async move { handlers::health::health(pool, db_ready).await }
    };

    let s = state.clone();
    let create_product_handler = move |body: Bytes| {
        let pool = s.pool.clone();
        let cache = s.cache.clone();
        async move {
            if body.len() > 1_048_576 {
                return errors::AppError::ValidationError.into_response();
            }
            handlers::products::create_product(pool, cache, body).await
        }
    };

    let s = state.clone();
    let get_product_handler = move |Path(id): Path<String>| {
        let pool = s.pool.clone();
        let cache = s.cache.clone();
        async move { handlers::products::get_product(pool, cache, id).await }
    };

    let s = state.clone();
    let list_products_handler = move |uri: Uri| {
        let pool = s.pool.clone();
        let cache = s.cache.clone();
        async move {
            let query = uri.query().unwrap_or("").to_string();
            handlers::products::list_products(pool, cache, query).await
        }
    };

    let s = state.clone();
    let create_order_handler = move |body: Bytes| {
        let pool = s.pool.clone();
        let cache = s.cache.clone();
        async move {
            if body.len() > 1_048_576 {
                return errors::AppError::ValidationError.into_response();
            }
            handlers::orders::create_order(pool, cache, body).await
        }
    };

    let s = state.clone();
    let get_user_orders_handler = move |Path(user_id): Path<String>| {
        let pool = s.pool.clone();
        async move { handlers::orders::get_user_orders(pool, user_id).await }
    };

    Router::new()
        .route("/health", get(health_handler))
        .route("/products", post(create_product_handler).get(list_products_handler))
        .route("/products/:id", get(get_product_handler))
        .route("/orders", post(create_order_handler))
        .route("/users/:userId/orders", get(get_user_orders_handler))
}

/// Preload existing products into cache on startup.
async fn preload_products(pool: &PgPool, cache: &AppCache) {
    match sqlx::query_as::<_, (String, String, String, i64, i64)>(
        "SELECT id, name, category, price, stock FROM products"
    )
    .fetch_all(pool)
    .await
    {
        Ok(rows) => {
            let count = rows.len();
            for (id, name, category, price, stock) in rows {
                cache.products.insert(id.clone(), cache::ProductInfo {
                    id: id.clone(),
                    name: name.clone(),
                    category: category.clone(),
                    price,
                });
                cache.stock.insert(id.clone(), stock).await;
                if stock == 0 {
                    cache.mark_sold_out(&id);
                }
            }
            info!("Preloaded {} products into cache", count);
        }
        Err(e) => {
            warn!("Failed to preload products: {}", e);
        }
    }
}
