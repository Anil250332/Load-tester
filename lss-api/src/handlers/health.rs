use axum::response::{IntoResponse, Response};
use axum::http::StatusCode;
use sqlx::PgPool;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::cache::AppCache;

/// Health check: 200 {"status":"ok"} when DB ready, else 503 {"status":"starting"}.
pub async fn health(
    pool: Arc<PgPool>,
    db_ready: Arc<AtomicBool>,
) -> Response {
    if db_ready.load(Ordering::Relaxed) {
        (
            StatusCode::OK,
            [(axum::http::header::CONTENT_TYPE, "application/json")],
            r#"{"status":"ok"}"#,
        )
            .into_response()
    } else {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            [(axum::http::header::CONTENT_TYPE, "application/json")],
            r#"{"status":"starting"}"#,
        )
            .into_response()
    }
}
