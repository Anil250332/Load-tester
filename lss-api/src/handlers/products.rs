use axum::response::{IntoResponse, Response};
use axum::http::StatusCode;
use bytes::Bytes;
use serde_json::Value;
use sqlx::PgPool;
use std::sync::Arc;

use crate::cache::{AppCache, ProductInfo, ProductFull};
use crate::errors::{AppError, internal_error};
use crate::validation;

/// POST /products — create a product.
pub async fn create_product(
    pool: Arc<PgPool>,
    cache: Arc<AppCache>,
    body: Bytes,
) -> Response {
    // Parse JSON manually
    let json: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return AppError::ValidationError.into_response(),
    };

    let obj = match json.as_object() {
        Some(o) => o,
        None => return AppError::ValidationError.into_response(),
    };

    // Validate all fields
    let id = match obj.get("id").and_then(|v| validation::validate_string(v, 64)) {
        Some(s) => s,
        None => return AppError::ValidationError.into_response(),
    };

    let name = match obj.get("name").and_then(|v| validation::validate_string(v, 200)) {
        Some(s) => s,
        None => return AppError::ValidationError.into_response(),
    };

    let category = match obj.get("category").and_then(|v| validation::validate_string(v, 64)) {
        Some(s) => s,
        None => return AppError::ValidationError.into_response(),
    };

    let price = match obj.get("price").and_then(|v| validation::validate_non_negative_integer(v)) {
        Some(n) => n,
        None => return AppError::ValidationError.into_response(),
    };

    let stock = match obj.get("stock").and_then(|v| validation::validate_non_negative_integer(v)) {
        Some(n) => n,
        None => return AppError::ValidationError.into_response(),
    };

    // Insert with ON CONFLICT DO NOTHING
    let result = sqlx::query_scalar::<_, i32>(
        "INSERT INTO products (id, name, category, price, stock) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (id) DO NOTHING RETURNING 1"
    )
    .bind(&id)
    .bind(&name)
    .bind(&category)
    .bind(price)
    .bind(stock)
    .fetch_optional(&*pool)
    .await;

    match result {
        Ok(Some(_)) => {
            // Successfully inserted — cache it
            let cat_clone = category.clone();
            cache.products.insert(id.clone(), ProductInfo {
                id: id.clone(),
                name: name.clone(),
                category: category.clone(),
                price,
            });
            cache.stock.insert(id.clone(), stock).await;
            // Invalidate list cache for this category
            cache.invalidate_category(&cat_clone);

            let body = serde_json::to_string(&ProductFull {
                id, name, category, price, stock,
            }).unwrap_or_default();

            (
                StatusCode::CREATED,
                [(axum::http::header::CONTENT_TYPE, "application/json")],
                body,
            )
                .into_response()
        }
        Ok(None) => {
            // Conflict — product already exists
            AppError::ProductExists.into_response()
        }
        Err(e) => {
            tracing::error!("DB error creating product: {}", e);
            internal_error()
        }
    }
}

/// GET /products/:id — get a single product.
pub async fn get_product(
    pool: Arc<PgPool>,
    cache: Arc<AppCache>,
    product_id: String,
) -> Response {
    // Try to get immutable info from cache
    let info = cache.products.get(&product_id).map(|r| r.clone());

    if let Some(info) = info {
        // Try stock from cache
        if let Some(stock) = cache.stock.get(&product_id).await {
            let body = serde_json::to_string(&ProductFull {
                id: info.id,
                name: info.name,
                category: info.category,
                price: info.price,
                stock,
            }).unwrap_or_default();

            return (
                StatusCode::OK,
                [(axum::http::header::CONTENT_TYPE, "application/json")],
                body,
            )
                .into_response();
        }

        // Stock not in cache, fetch from DB
        match sqlx::query_scalar::<_, i64>("SELECT stock FROM products WHERE id = $1")
            .bind(&product_id)
            .fetch_optional(&*pool)
            .await
        {
            Ok(Some(stock)) => {
                cache.stock.insert(product_id.clone(), stock).await;
                let body = serde_json::to_string(&ProductFull {
                    id: info.id,
                    name: info.name,
                    category: info.category,
                    price: info.price,
                    stock,
                }).unwrap_or_default();
                (
                    StatusCode::OK,
                    [(axum::http::header::CONTENT_TYPE, "application/json")],
                    body,
                )
                    .into_response()
            }
            Ok(None) => {
                // Product was deleted? Shouldn't happen but handle gracefully
                cache.products.remove(&product_id);
                AppError::ProductNotFound.into_response()
            }
            Err(e) => {
                tracing::error!("DB error fetching stock: {}", e);
                internal_error()
            }
        }
    } else {
        // Not in cache — full DB fetch (never cache 404s)
        match sqlx::query_as::<_, (String, String, String, i64, i64)>(
            "SELECT id, name, category, price, stock FROM products WHERE id = $1"
        )
        .bind(&product_id)
        .fetch_optional(&*pool)
        .await
        {
            Ok(Some((id, name, category, price, stock))) => {
                cache.products.insert(id.clone(), ProductInfo {
                    id: id.clone(),
                    name: name.clone(),
                    category: category.clone(),
                    price,
                });
                cache.stock.insert(id.clone(), stock).await;

                let body = serde_json::to_string(&ProductFull {
                    id, name, category, price, stock,
                }).unwrap_or_default();

                (
                    StatusCode::OK,
                    [(axum::http::header::CONTENT_TYPE, "application/json")],
                    body,
                )
                    .into_response()
            }
            Ok(None) => AppError::ProductNotFound.into_response(),
            Err(e) => {
                tracing::error!("DB error fetching product: {}", e);
                internal_error()
            }
        }
    }
}

/// GET /products?category=&page=&limit= — list products.
pub async fn list_products(
    pool: Arc<PgPool>,
    cache: Arc<AppCache>,
    query_string: String,
) -> Response {
    // Parse query params manually
    let params: Vec<(String, String)> = url_decode_params(&query_string);

    let category = match find_param(&params, "category") {
        Some(c) if !c.is_empty() => c,
        _ => return AppError::ValidationError.into_response(),
    };

    let page = match find_param(&params, "page") {
        Some(p) => match validation::parse_page(Some(&p)) {
            Ok(n) => n,
            Err(_) => return AppError::ValidationError.into_response(),
        },
        None => 1,
    };

    let limit = match find_param(&params, "limit") {
        Some(l) => match validation::parse_limit(Some(&l)) {
            Ok(n) => n,
            Err(_) => return AppError::ValidationError.into_response(),
        },
        None => 20,
    };

    let cache_key = (category.clone(), page, limit);

    // Check list cache
    if let Some((cached_bytes, _total)) = cache.list_pages.get(&cache_key).await {
        return (
            StatusCode::OK,
            [(axum::http::header::CONTENT_TYPE, "application/json")],
            cached_bytes,
        )
            .into_response();
    }

    let offset = (page - 1) * limit;

    // Get total count
    let total = match sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM products WHERE category = $1"
    )
    .bind(&category)
    .fetch_one(&*pool)
    .await
    {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("DB error counting products: {}", e);
            return internal_error();
        }
    };

    // Get items
    let items = match sqlx::query_as::<_, (String, String, String, i64, i64)>(
        "SELECT id, name, category, price, stock FROM products WHERE category = $1 ORDER BY price ASC, id COLLATE \"C\" ASC LIMIT $2 OFFSET $3"
    )
    .bind(&category)
    .bind(limit)
    .bind(offset)
    .fetch_all(&*pool)
    .await
    {
        Ok(rows) => rows,
        Err(e) => {
            tracing::error!("DB error listing products: {}", e);
            return internal_error();
        }
    };

    let mut products: Vec<ProductFull> = Vec::with_capacity(items.len());
    for (id, name, cat, price, stock) in items {
        // Also populate the product cache
        cache.products.entry(id.clone()).or_insert(ProductInfo {
            id: id.clone(),
            name: name.clone(),
            category: cat.clone(),
            price,
        });
        cache.stock.insert(id.clone(), stock).await;
        products.push(ProductFull { id, name, category: cat, price, stock });
    }

    #[derive(serde::Serialize)]
    struct ListResponse {
        items: Vec<ProductFull>,
        page: i64,
        limit: i64,
        total: i64,
    }

    let resp = ListResponse { items: products, page, limit, total };
    let body = serde_json::to_vec(&resp).unwrap_or_default();

    // Cache the response
    cache.list_pages.insert(cache_key, (body.clone(), total)).await;

    (
        StatusCode::OK,
        [(axum::http::header::CONTENT_TYPE, "application/json")],
        body,
    )
        .into_response()
}

/// Parse query string into key-value pairs with percent-decoding.
fn url_decode_params(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|s| !s.is_empty())
        .filter_map(|part| {
            let mut split = part.splitn(2, '=');
            let key = split.next()?;
            let value = split.next().unwrap_or("");
            let key = percent_encoding::percent_decode_str(key)
                .decode_utf8_lossy()
                .to_string();
            let value = percent_encoding::percent_decode_str(value)
                .decode_utf8_lossy()
                .to_string();
            Some((key, value))
        })
        .collect()
}

fn find_param(params: &[(String, String)], key: &str) -> Option<String> {
    params.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
}
