/// Application configuration loaded from environment variables.
#[derive(Clone)]
pub struct Config {
    pub database_url: String,
    pub listen_addr: String,
    pub db_pool_size: u32,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            database_url: std::env::var("DATABASE_URL")
                .unwrap_or_else(|_| "postgres://lss:lss@localhost/lss?sslmode=disable".to_string()),
            listen_addr: std::env::var("LISTEN_ADDR")
                .unwrap_or_else(|_| "0.0.0.0:8080".to_string()),
            db_pool_size: std::env::var("DB_POOL_SIZE")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(24),
        }
    }
}
