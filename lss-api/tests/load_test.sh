#!/usr/bin/env bash
# load_test.sh — Seed data and run load test
# Usage: bash tests/load_test.sh [base_url]
set -euo pipefail

BASE="${1:-http://localhost:8080}"

echo "=== Seeding 10,000 products in 50 categories ==="
for cat in $(seq 1 50); do
    for prod in $(seq 1 200); do
        ID="load-p${cat}-${prod}"
        PRICE=$((RANDOM % 10000))
        STOCK=$((RANDOM % 1000 + 100))
        curl -s -X POST "$BASE/products" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"${ID}\",\"name\":\"Product ${cat}-${prod}\",\"category\":\"cat-${cat}\",\"price\":${PRICE},\"stock\":${STOCK}}" > /dev/null &
        if [ $(( (cat-1)*200 + prod )) -eq 500 ]; then
            echo "  ...500 seeded"
        fi
        # Throttle
        if [ $((prod % 50)) -eq 0 ]; then wait; fi
    done
done
wait
echo "  Done seeding"

echo ""
echo "=== Load Test with oha ==="
echo "Note: Running on same box as server, results are approximate."
echo ""

# Check if oha is available
if ! command -v oha &>/dev/null; then
    echo "oha not installed. Install with: cargo install oha"
    echo "Or use wrk/k6 instead."
    exit 1
fi

# Level 1: 500 req/s for 30s — GET /products/:id
echo "--- Level 1: 500 req/s, GET /products/:id ---"
oha -n 15000 -c 50 --latency-correction --no-tui "$BASE/products/load-p1-1" 2>&1 | grep -E "Success|Latency|Status"

echo ""
echo "--- Level 2: 1000 req/s, mixed ---"
# Simple: hammer GET /products/:id
oha -n 30000 -c 100 --latency-correction --no-tui "$BASE/products/load-p25-100" 2>&1 | grep -E "Success|Latency|Status"

echo ""
echo "--- Level 3: POST /orders stress ---"
# Create a flash product
curl -s -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{"id":"flash-load","name":"Flash Load","category":"flash","price":10,"stock":5000}' > /dev/null

oha -n 10000 -c 200 --latency-correction --no-tui \
    -m POST \
    -H "Content-Type: application/json" \
    -d '{"userId":"UNIQUE_PLACEHOLDER","productId":"flash-load"}' \
    "$BASE/orders" 2>&1 | head -20

echo ""
echo "=== Load test complete ==="
