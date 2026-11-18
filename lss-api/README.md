# Last Server Standing — Flash Sale API

A high-performance flash-sale HTTP API built with Rust + PostgreSQL, designed to survive rising load tests (500 → 50,000 req/s) on a single EC2 m7i.large (2 vCPU / 8 GB RAM).

## Architecture

- **Language**: Rust (stable) with tokio async runtime
- **HTTP**: axum (hyper), HTTP/1.1, listen 0.0.0.0:8080
- **Database**: PostgreSQL (local only, Unix socket preferred)
- **Cache**: In-process memory (moka + dashmap) — no Redis
- **Allocator**: mimalloc

## Quick Start (EC2 Ubuntu 24.04)

```bash
# 1. Clone/copy the project to the server
scp -r lss-api/ ubuntu@your-ec2:~/lss-api/

# 2. SSH in and run setup (as root)
ssh ubuntu@your-ec2
cd ~/lss-api
sudo bash deploy/setup.sh

# 3. Verify
curl http://localhost:8080/health
# → {"status":"ok"}
```

## Manual Build & Run

```bash
# Build release binary
cargo build --release

# Set up database
export DATABASE_URL="postgres://lss:lss@localhost/lss"
psql $DATABASE_URL -f db/schema.sql

# Run
./target/release/lss-api
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /health | Health check |
| POST | /products | Create product |
| GET | /products/:id | Get product |
| GET | /products?category=&page=&limit= | List products |
| POST | /orders | Create order (buy 1 unit) |
| GET | /users/:userId/orders | Get user's orders |

## Testing

```bash
# Contract tests (all endpoints, success + error cases)
bash tests/contract_tests.sh http://localhost:8080

# Concurrency tests (last-unit, flash drop, double-click)
bash tests/concurrency_tests.sh http://localhost:8080

# Data integrity audit
bash tests/audit.sh http://localhost:8080

# Load test (requires oha: cargo install oha)
bash tests/load_test.sh http://localhost:8080
```

## Deployment Files

- `deploy/setup.sh` — Idempotent setup script for Ubuntu 24.04
- `deploy/lss-api.service` — systemd unit (Restart=always)
- `deploy/tuning.conf` — PostgreSQL performance tuning
- `deploy/99-lss.conf` — sysctl network tuning

## Key Design Decisions

### Correctness First
- Stock check + decrement is a single atomic `UPDATE ... WHERE stock > 0`
- Duplicate purchase prevention via `UNIQUE (user_id, product_id)` constraint
- Orders use a transaction: insert order → decrement stock → commit (or rollback everything)
- Order transaction runs in `tokio::spawn` to prevent client disconnection from leaving half-committed state
- No SELECT-then-UPDATE; no prior SELECT for duplicate check

### Caching Strategy
- Product immutable fields (name, category, price): cached forever in DashMap
- Stock: moka cache with 1s TTL (within the 2-second rule)
- Sold-out flags: set once after DB confirms stock=0, never unset (stock never increases)
- List pages: cached by (category, page, limit) with 1s TTL, invalidated on POST /products
- Never cache 404s for product lookups

### Performance
- mimalloc global allocator
- Atomic counter for order IDs (no UUID generation overhead)
- In-memory sold-out fast path skips DB entirely
- TCP_NODELAY enabled
- Connection pool: 24 connections, prepared statements
- Release build: opt-level=3, LTO=fat, codegen-units=1, panic=abort

## Survival Guarantees

- `kill -9` → systemd restarts within 1s, all data persisted in Postgres
- No internet needed after build (binary is pre-compiled, no downloads)
- No external services (everything runs locally)
- No per-request logging (warn/error only)
- No rate limiting (429 counts as error)
