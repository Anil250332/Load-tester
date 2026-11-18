#!/usr/bin/env bash
# audit.sh — Verify data integrity after tests
# Usage: bash tests/audit.sh [base_url] [db_connection_string]
set -euo pipefail

BASE="${1:-http://localhost:8080}"
DB="${2:-postgres://lss:lss@localhost/lss}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
PASS=0
FAIL=0
TOTAL=0

check() {
    local name="$1" ok="$2"
    TOTAL=$((TOTAL+1))
    if [ "$ok" = "true" ]; then
        PASS=$((PASS+1))
        echo -e "${GREEN}✓${NC} $name"
    else
        FAIL=$((FAIL+1))
        echo -e "${RED}✗${NC} $name"
    fi
}

echo "============================================"
echo "  AUDIT — Checking data integrity"
echo "============================================"

# Check 1: No negative stock
NEG=$(psql "$DB" -t -A -c "SELECT COUNT(*) FROM products WHERE stock < 0;")
check "No negative stock" "$([ "$NEG" = "0" ] && echo true || echo false)"

# Check 2: No ghost orders (orders referencing non-existent products)
GHOST=$(psql "$DB" -t -A -c "SELECT COUNT(*) FROM orders o LEFT JOIN products p ON o.product_id = p.id WHERE p.id IS NULL;")
check "No ghost orders" "$([ "$GHOST" = "0" ] && echo true || echo false)"

# Check 3: No duplicate (user_id, product_id)
DUPES=$(psql "$DB" -t -A -c "SELECT COUNT(*) FROM (SELECT user_id, product_id, COUNT(*) c FROM orders GROUP BY user_id, product_id HAVING COUNT(*) > 1) sub;")
check "No duplicate purchases" "$([ "$DUPES" = "0" ] && echo true || echo false)"

# Check 4: For products with orders, verify stock consistency
# starting_stock - final_stock == count(orders)
# We don't know starting stock, but we can check: stock >= 0 AND count(orders) >= 0
# For sold-out products (stock=0), all stock went to orders
echo ""
echo "--- Per-product audit ---"
psql "$DB" -t -A -c "
    SELECT p.id, p.stock as current_stock, COALESCE(o.cnt, 0) as order_count
    FROM products p
    LEFT JOIN (SELECT product_id, COUNT(*) cnt FROM orders GROUP BY product_id) o
    ON p.id = o.product_id
    WHERE COALESCE(o.cnt, 0) > 0
    ORDER BY p.id
    LIMIT 20;
" | while IFS='|' read -r pid stock orders; do
    echo "  Product $pid: stock=$stock, orders=$orders"
done

echo ""
echo "============================================"
echo "  AUDIT RESULTS: $PASS passed, $FAIL failed (of $TOTAL)"
echo "============================================"
