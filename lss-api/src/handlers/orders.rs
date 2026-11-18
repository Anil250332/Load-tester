use axum::response::{IntoResponse, Response};
use axum::http::StatusCode;
use bytes::Bytes;
use serde_json::Value;
use sqlx::PgPool;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::cache::AppCache;
use crate::errors::{AppError, internal_error};

/// Atomic counter for fast order ID generation.
static ORDER_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Per-process prefix to avoid collisions across restarts.
static ORDER_PREFIX: OnceLock<u64> = OnceLock::new();

fn get_order_prefix() -> u64 {
    *ORDER_PREFIX.get_or_init(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    })
}

fn generate_order_id() -> String {
    let n = ORDER_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("o{}-{}", get_order_prefix(), n)
}

/// Result type for the order transaction.
enum OrderResult {
    Success(String), // order_id
    AppErr(AppError),
    InternalErr(String),
}

/// POST /orders — buy exactly one unit.
pub async fn create_order(
    pool: Arc<PgPool>,
    cache: Arc<AppCache>,
    body: Bytes,
) -> Response {
    // 1. Validate body → 400
    let json: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return AppError::ValidationError.into_response(),
    };

    let obj = match json.as_object() {
        Some(o) => o,
        None => return AppError::ValidationError.into_response(),
    };

    let user_id = match obj.get("userId") {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        _ => return AppError::ValidationError.into_response(),
    };

    let product_id = match obj.get("productId") {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        _ => return AppError::ValidationError.into_response(),
    };

    // 2. Product existence check (cache, then DB on miss) → 404
    let product_exists = if cache.products.contains_key(&product_id) {
        true
    } else {
        // Check DB and populate cache
        match sqlx::query_as::<_, (String, String, String, i64)>(
            "SELECT id, name, category, price FROM products WHERE id = $1"
        )
        .bind(&product_id)
        .fetch_optional(&*pool)
        .await
        {
            Ok(Some((id, name, category, price))) => {
                cache.products.insert(id.clone(), crate::cache::ProductInfo {
                    id, name, category, price,
                });
                true
            }
            Ok(None) => false,
            Err(e) => {
                tracing::error!("DB error checking product existence: {}", e);
                return internal_error();
            }
        }
    };

    if !product_exists {
        return AppError::ProductNotFound.into_response();
    }

    // 3. Transaction: order insert + stock decrement
    // NOTE: We do NOT short-circuit on sold_out before the transaction because
    // ALREADY_PURCHASED must take priority over SOLD_OUT (spec: "retry → ALREADY_PURCHASED").
    // The transaction checks duplicate first (INSERT), then stock (UPDATE).
    // The sold_out flag is used INSIDE the transaction as an optimization to skip
    // the UPDATE query when we know stock is 0 (after the INSERT succeeds).
    let pool_clone = pool.clone();
    let cache_clone = cache.clone();
    let user_id_clone = user_id.clone();
    let product_id_clone = product_id.clone();

    let result = tokio::spawn(async move {
        do_order_transaction(&pool_clone, &cache_clone, &user_id_clone, &product_id_clone).await
    })
    .await;

    match result {
        Ok(OrderResult::Success(order_id)) => {
            #[derive(serde::Serialize)]
            struct OrderResponse {
                #[serde(rename = "orderId")]
                order_id: String,
                #[serde(rename = "userId")]
                user_id: String,
                #[serde(rename = "productId")]
                product_id: String,
            }

            let body = serde_json::to_string(&OrderResponse {
                order_id,
                user_id,
                product_id,
            }).unwrap_or_default();

            (
                StatusCode::CREATED,
                [(axum::http::header::CONTENT_TYPE, "application/json")],
                body,
            )
                .into_response()
        }
        Ok(OrderResult::AppErr(app_err)) => app_err.into_response(),
        Ok(OrderResult::InternalErr(msg)) => {
            tracing::error!("Order transaction failed: {}", msg);
            internal_error()
        }
        Err(e) => {
            tracing::error!("Order task panicked: {}", e);
            internal_error()
        }
    }
}

/// The core order transaction logic, isolated for spawn safety.
async fn do_order_transaction(
    pool: &PgPool,
    cache: &AppCache,
    user_id: &str,
    product_id: &str,
) -> OrderResult {
    let order_id = generate_order_id();

    let mut tx = match pool.begin().await {
        Ok(tx) => tx,
        Err(e) => return OrderResult::InternalErr(format!("begin: {}", e)),
    };

    // 4a. INSERT order with ON CONFLICT DO NOTHING (unique constraint on user_id, product_id)
    // This MUST come before the stock check so ALREADY_PURCHASED takes priority over SOLD_OUT.
    let inserted = match sqlx::query_scalar::<_, i32>(
        "INSERT INTO orders (order_id, user_id, product_id) VALUES ($1, $2, $3) ON CONFLICT (user_id, product_id) DO NOTHING RETURNING 1"
    )
    .bind(&order_id)
    .bind(user_id)
    .bind(product_id)
    .fetch_optional(&mut *tx)
    .await
    {
        Ok(r) => r,
        Err(e) => {
            tx.rollback().await.ok();
            return OrderResult::InternalErr(format!("insert order: {}", e));
        }
    };

    if inserted.is_none() {
        // Duplicate: user already purchased this product
        tx.rollback().await.ok();
        return OrderResult::AppErr(AppError::AlreadyPurchased);
    }

    // 4b. Check sold_out flag AFTER duplicate check (optimization: skip UPDATE if known sold out)
    if cache.is_sold_out(product_id) {
        tx.rollback().await.ok();
        return OrderResult::AppErr(AppError::SoldOut);
    }

    // 4c. UPDATE stock atomically
    let updated = match sqlx::query_scalar::<_, i64>(
        "UPDATE products SET stock = stock - 1 WHERE id = $1 AND stock > 0 RETURNING stock"
    )
    .bind(product_id)
    .fetch_optional(&mut *tx)
    .await
    {
        Ok(r) => r,
        Err(e) => {
            tx.rollback().await.ok();
            return OrderResult::InternalErr(format!("update stock: {}", e));
        }
    };

    match updated {
        Some(new_stock) => {
            // 4d. COMMIT
            if let Err(e) = tx.commit().await {
                return OrderResult::InternalErr(format!("commit: {}", e));
            }

            // Update stock cache with new value
            cache.stock.insert(product_id.to_string(), new_stock).await;

            // If stock hit 0, mark as sold out
            if new_stock == 0 {
                cache.mark_sold_out(product_id);
            }

            OrderResult::Success(order_id)
        }
        None => {
            // No stock — rollback (removes the order from 4a)
            tx.rollback().await.ok();
            cache.mark_sold_out(product_id);
            OrderResult::AppErr(AppError::SoldOut)
        }
    }
}

/// GET /users/:userId/orders — get user's orders.
pub async fn get_user_orders(
    pool: Arc<PgPool>,
    user_id: String,
) -> Response {
    match sqlx::query_as::<_, (String, String)>(
        "SELECT order_id, product_id FROM orders WHERE user_id = $1"
    )
    .bind(&user_id)
    .fetch_all(&*pool)
    .await
    {
        Ok(rows) => {
            #[derive(serde::Serialize)]
            struct OrderItem {
                #[serde(rename = "orderId")]
                order_id: String,
                #[serde(rename = "productId")]
                product_id: String,
            }

            #[derive(serde::Serialize)]
            struct UserOrdersResponse {
                #[serde(rename = "userId")]
                user_id: String,
                orders: Vec<OrderItem>,
            }

            let orders: Vec<OrderItem> = rows
                .into_iter()
                .map(|(order_id, product_id)| OrderItem { order_id, product_id })
                .collect();

            let body = serde_json::to_string(&UserOrdersResponse {
                user_id,
                orders,
            }).unwrap_or_default();

            (
                StatusCode::OK,
                [(axum::http::header::CONTENT_TYPE, "application/json")],
                body,
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("DB error fetching user orders: {}", e);
            internal_error()
        }
    }
}
