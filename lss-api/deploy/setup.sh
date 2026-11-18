#!/usr/bin/env bash
# setup.sh — Idempotent setup for Last Server Standing on Ubuntu 24.04
# Run as root: sudo bash deploy/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Last Server Standing Setup ==="
echo "Project dir: $PROJECT_DIR"

# ---- 1. System packages ----
echo ">>> Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql postgresql-client build-essential pkg-config libssl-dev curl

# ---- 2. Rust toolchain (if not installed) ----
if ! command -v cargo &>/dev/null; then
    echo ">>> Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env"
fi
# Ensure cargo is in PATH
export PATH="$HOME/.cargo/bin:$PATH"

# ---- 3. PostgreSQL config ----
echo ">>> Configuring PostgreSQL..."
PG_VERSION=$(pg_lsclusters -h | head -1 | awk '{print $1}')
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
mkdir -p "$PG_CONF_DIR"
cp "$SCRIPT_DIR/tuning.conf" "$PG_CONF_DIR/tuning.conf"

# Ensure conf.d is included
PG_MAIN_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
if ! grep -q "include_dir = 'conf.d'" "$PG_MAIN_CONF"; then
    echo "include_dir = 'conf.d'" >> "$PG_MAIN_CONF"
fi

# Ensure password auth for lss user over TCP
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if ! grep -q "lss" "$PG_HBA"; then
    # Add before the first 'host' line
    sed -i '1i host lss lss 127.0.0.1/32 md5' "$PG_HBA"
    sed -i '1i host lss lss ::1/128 md5' "$PG_HBA"
fi

# Restart postgres to apply
systemctl restart postgresql
systemctl enable postgresql

# ---- 4. Database and user ----
echo ">>> Setting up database..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='lss'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER lss WITH PASSWORD 'lss';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='lss'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE lss OWNER lss;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE lss TO lss;"

# Apply schema
echo ">>> Applying schema..."
PGPASSWORD=lss psql -U lss -h localhost -d lss -f "$PROJECT_DIR/db/schema.sql"

# ---- 5. Sysctl tuning ----
echo ">>> Applying sysctl tuning..."
cp "$SCRIPT_DIR/99-lss.conf" /etc/sysctl.d/99-lss.conf
sysctl --system > /dev/null 2>&1

# ---- 6. File limits ----
echo ">>> Setting file limits..."
cat > /etc/security/limits.d/99-lss.conf << 'EOF'
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
EOF

# ---- 7. Swap (2 GB) ----
echo ">>> Setting up swap..."
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    echo "Swap already exists"
fi

# ---- 8. Build the application ----
echo ">>> Building release binary..."
cd "$PROJECT_DIR"
cargo build --release

# ---- 9. Install binary ----
echo ">>> Installing binary..."
mkdir -p /opt/lss
cp "$PROJECT_DIR/target/release/lss-api" /opt/lss/lss-api
chmod +x /opt/lss/lss-api

# Create lss user if needed
id -u lss &>/dev/null || useradd --system --no-create-home --shell /bin/false lss

# ---- 10. Systemd service ----
echo ">>> Installing systemd service..."
cp "$SCRIPT_DIR/lss-api.service" /etc/systemd/system/lss-api.service
systemctl daemon-reload
systemctl enable lss-api.service
systemctl restart lss-api.service

echo ">>> Waiting for health check..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8080/health | grep -q '"ok"'; then
        echo "✓ Server is healthy!"
        break
    fi
    sleep 1
done

echo ""
echo "=== Setup complete ==="
echo "Service: systemctl status lss-api"
echo "Logs:    journalctl -u lss-api -f"
echo "Health:  curl http://localhost:8080/health"
