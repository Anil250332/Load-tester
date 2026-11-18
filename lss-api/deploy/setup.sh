#!/usr/bin/env bash
# setup.sh — Idempotent setup for Last Server Standing on Ubuntu 24.04
# DISK-CONSTRAINED: ~7.5 GB total. Every step checks free space.
# Run as root: sudo bash deploy/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

check_disk() {
    local free_kb
    free_kb=$(df / --output=avail | tail -1 | tr -d ' ')
    local free_mb=$((free_kb / 1024))
    echo "  [disk] ${free_mb} MB free"
    if [ "$free_mb" -lt 1024 ]; then
        echo "ERROR: Less than 1 GB free! Stopping."
        df -h /
        exit 1
    fi
}

echo "=== Last Server Standing Setup (disk-constrained) ==="
echo "Project dir: $PROJECT_DIR"
lsblk
df -h /
check_disk

# ---- 1. System packages ----
echo ">>> Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    postgresql postgresql-client \
    build-essential pkg-config libssl-dev \
    curl ca-certificates
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
echo ">>> After apt:"
check_disk

# ---- 2. Rust toolchain (if not installed) ----
if ! command -v cargo &>/dev/null; then
    echo ">>> Installing Rust (minimal profile)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
    source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$PATH"
echo ">>> After Rust:"
check_disk

# ---- 3. journald limits ----
echo ">>> Limiting journald to 100M..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/lss.conf << 'EOF'
[Journal]
SystemMaxUse=100M
EOF
systemctl restart systemd-journald
journalctl --vacuum-size=100M 2>/dev/null || true

# ---- 4. PostgreSQL config ----
echo ">>> Configuring PostgreSQL..."
PG_VERSION=$(pg_lsclusters -h | head -1 | awk '{print $1}')
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
mkdir -p "$PG_CONF_DIR"
cp "$SCRIPT_DIR/tuning.conf" "$PG_CONF_DIR/tuning.conf"

PG_MAIN_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
if ! grep -q "include_dir = 'conf.d'" "$PG_MAIN_CONF"; then
    echo "include_dir = 'conf.d'" >> "$PG_MAIN_CONF"
fi

# Ensure password auth for lss user
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if ! grep -q "lss" "$PG_HBA"; then
    sed -i '1i host lss lss 127.0.0.1/32 md5' "$PG_HBA"
    sed -i '1i host lss lss ::1/128 md5' "$PG_HBA"
fi

systemctl restart postgresql
systemctl enable postgresql

# ---- 5. Database and user ----
echo ">>> Setting up database..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='lss'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER lss WITH PASSWORD 'lss';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='lss'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE lss OWNER lss;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE lss TO lss;"

echo ">>> Applying schema..."
PGPASSWORD=lss psql -U lss -h localhost -d lss -f "$PROJECT_DIR/db/schema.sql"

# ---- 6. Sysctl tuning ----
echo ">>> Applying sysctl tuning..."
cp "$SCRIPT_DIR/99-lss.conf" /etc/sysctl.d/99-lss.conf
sysctl --system > /dev/null 2>&1

# ---- 7. File limits ----
echo ">>> Setting file limits..."
cat > /etc/security/limits.d/99-lss.conf << 'EOF'
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
EOF

# ---- 8. Swap (512 MB — disk constrained) ----
echo ">>> Setting up swap (512 MB)..."
if [ ! -f /swapfile ]; then
    fallocate -l 512M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    echo "Swap already exists"
fi
echo ">>> After swap:"
check_disk

# ---- 9. Build the application ----
echo ">>> Building release binary..."
cd "$PROJECT_DIR"
cargo build --release
echo ">>> After build:"
check_disk

# ---- 10. Install binary ----
echo ">>> Installing binary..."
mkdir -p /opt/lss
cp "$PROJECT_DIR/target/release/lss-api" /opt/lss/lss-api
chmod +x /opt/lss/lss-api

# Create lss user if needed
id -u lss &>/dev/null || useradd --system --no-create-home --shell /bin/false lss

# ---- 11. Clean up build artifacts to save disk ----
echo ">>> Cleaning build artifacts..."
rm -rf "$PROJECT_DIR/target"
rm -rf "$HOME/.cargo/registry"
rm -rf "$HOME/.cargo/git"
echo ">>> After cleanup:"
check_disk

# ---- 12. Systemd service ----
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
echo "=== Final disk usage ==="
df -h /
echo ""
echo "--- Key directories ---"
du -sh /var/lib/postgresql /opt/lss "$HOME/.cargo" "$HOME/.rustup" /var/log 2>/dev/null || true
echo ""
echo "=== Setup complete ==="
echo "Service: systemctl status lss-api"
echo "Logs:    journalctl -u lss-api -f"
echo "Health:  curl http://localhost:8080/health"
