use dashmap::DashMap;
use dashmap::DashSet;
use moka::future::Cache;
use serde::Serialize;
use std::time::Duration;

/// Immutable product data (never changes after creation).
#[derive(Debug, Clone, Serialize)]
pub struct ProductInfo {
    pub id: String,
    pub name: String,
    pub category: String,
    pub price: i64,
}

/// Full product data including stock (for cached responses).
#[derive(Debug, Clone, Serialize)]
pub struct ProductFull {
    pub id: String,
    pub name: String,
    pub category: String,
    pub price: i64,
    pub stock: i64,
}

/// Cache for list pages: (category, page, limit) -> (items_json_bytes, total).
type ListCacheKey = (String, i64, i64);

pub struct AppCache {
    /// Immutable product info — cached forever.
    pub products: DashMap<String, ProductInfo>,
    /// Product counts per category — updated on create_product and preload.
    pub category_counts: DashMap<String, i64>,
    /// Sold-out flags — once set, never unset (stock never increases).
    pub sold_out: DashSet<String>,
    /// Stock cache with 1s TTL.
    pub stock: Cache<String, i64>,
    /// List page cache with 1s TTL, invalidated on POST /products for that category.
    pub list_pages: Cache<ListCacheKey, (Vec<u8>, i64)>,
    /// User orders cache with 1.5s TTL (spec allows up to 2s).
    pub user_orders: Cache<String, Vec<u8>>,
}

impl AppCache {
    pub fn new() -> Self {
        Self {
            products: DashMap::with_capacity(16384),
            category_counts: DashMap::new(),
            sold_out: DashSet::new(),
            stock: Cache::builder()
                .time_to_live(Duration::from_secs(1))
                .max_capacity(100_000)
                .build(),
            list_pages: Cache::builder()
                .time_to_live(Duration::from_secs(1))
                .max_capacity(50_000)
                .build(),
            user_orders: Cache::builder()
                .time_to_live(Duration::from_millis(1500))
                .max_capacity(100_000)
                .build(),
        }
    }

    /// Invalidate all list cache entries for a given category.
    pub fn invalidate_category(&self, _category: &str) {
        // moka doesn't support prefix invalidation easily,
        // so we just invalidate the whole list cache.
        // With 1s TTL this is acceptable.
        self.list_pages.invalidate_all();
    }

    pub fn is_sold_out(&self, product_id: &str) -> bool {
        self.sold_out.contains(product_id)
    }

    pub fn mark_sold_out(&self, product_id: &str) {
        self.sold_out.insert(product_id.to_string());
    }
}
