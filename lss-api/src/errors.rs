use serde::Serialize;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

/// The 5 error codes as specified.
#[derive(Debug, Clone, Copy)]
pub enum AppError {
    ValidationError,
    ProductNotFound,
    ProductExists,
    AlreadyPurchased,
    SoldOut,
}

#[derive(Serialize)]
struct ErrorBody {
    error: &'static str,
}

impl AppError {
    pub fn code(&self) -> &'static str {
        match self {
            AppError::ValidationError => "VALIDATION_ERROR",
            AppError::ProductNotFound => "PRODUCT_NOT_FOUND",
            AppError::ProductExists => "PRODUCT_EXISTS",
            AppError::AlreadyPurchased => "ALREADY_PURCHASED",
            AppError::SoldOut => "SOLD_OUT",
        }
    }

    pub fn status(&self) -> StatusCode {
        match self {
            AppError::ValidationError => StatusCode::BAD_REQUEST,
            AppError::ProductNotFound => StatusCode::NOT_FOUND,
            AppError::ProductExists => StatusCode::CONFLICT,
            AppError::AlreadyPurchased => StatusCode::CONFLICT,
            AppError::SoldOut => StatusCode::CONFLICT,
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let body = serde_json::to_string(&ErrorBody { error: self.code() })
            .unwrap_or_else(|_| r#"{"error":"VALIDATION_ERROR"}"#.to_string());
        (
            self.status(),
            [(axum::http::header::CONTENT_TYPE, "application/json")],
            body,
        )
            .into_response()
    }
}

/// Internal server error — returns 500 with a generic message.
pub fn internal_error() -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        [(axum::http::header::CONTENT_TYPE, "application/json")],
        r#"{"error":"INTERNAL_ERROR"}"#,
    )
        .into_response()
}
