use sqlx::postgres::{PgPoolOptions, PgConnectOptions};
use sqlx::{PgPool, ConnectOptions};
use std::str::FromStr;
use std::time::Duration;
use tracing::{info, warn};

/// Create the connection pool with retry/backoff.
pub async fn create_pool(database_url: &str, pool_size: u32) -> PgPool {
    let connect_opts = PgConnectOptions::from_str(database_url)
        .expect("Invalid DATABASE_URL")
        .log_statements(tracing::log::LevelFilter::Off)
        .log_slow_statements(tracing::log::LevelFilter::Warn, Duration::from_secs(1));

    let mut retries = 0u32;
    loop {
        match PgPoolOptions::new()
            .max_connections(pool_size)
            .min_connections(pool_size / 2)
            .acquire_timeout(Duration::from_secs(1))
            .idle_timeout(Duration::from_secs(600))
            .max_lifetime(Duration::from_secs(1800))
            .connect_with(connect_opts.clone())
            .await
        {
            Ok(pool) => {
                info!("Database pool created with {} connections", pool_size);
                return pool;
            }
            Err(e) => {
                retries += 1;
                if retries > 30 {
                    panic!("Failed to connect to database after 30 retries: {}", e);
                }
                let delay = Duration::from_millis(500 * retries as u64);
                warn!("DB connection attempt {} failed: {}. Retrying in {:?}...", retries, e, delay);
                tokio::time::sleep(delay).await;
            }
        }
    }
}

/// Run the idempotent schema creation.
pub async fn run_migrations(pool: &PgPool) {
    let schema = include_str!("../db/schema.sql");
    sqlx::raw_sql(schema)
        .execute(pool)
        .await
        .expect("Failed to run schema migration");
    info!("Schema migration complete");
}
