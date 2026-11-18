#!/usr/bin/env bash
# contract_tests.sh — Full contract test suite for all 6 endpoints
# Usage: bash tests/contract_tests.sh [base_url]
set -euo pipefail

BASE="${1:-http://localhost:8080}"
PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_status() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    local body="$4"
    TOTAL=$((TOTAL+1))
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
        echo -e "${GREEN}✓${NC} $test_name (HTTP $actual)"
    else
        FAIL=$((FAIL+1))
        echo -e "${RED}✗${NC} $test_name — expected $expected, got $actual"
        echo "  Body: $body"
    fi
}

assert_json_field() {
    local test_name="$1"
    local body="$2"
    local field="$3"
    local expected="$4"
    TOTAL=$((TOTAL+1))
    local actual
    actual=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field','__MISSING__'))" 2>/dev/null || echo "__ERROR__")
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
        echo -e "${GREEN}✓${NC} $test_name ($field=$actual)"
    else
        FAIL=$((FAIL+1))
        echo -e "${RED}✗${NC} $test_name — $field: expected '$expected', got '$actual'"
    fi
}

assert_json_error() {
    local test_name="$1"
    local body="$2"
    local expected_code="$3"
    assert_json_field "$test_name" "$body" "error" "$expected_code"
}

# Clean up: create a unique product id prefix
PFX="ct$(date +%s)"

echo "============================================"
echo "  CONTRACT TESTS — Base URL: $BASE"
echo "============================================"
echo ""

# ---- HEALTH ----
echo "--- GET /health ---"
RESP=$(curl -s -w "\n%{http_code}" "$BASE/health")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Health returns 200" "200" "$CODE" "$BODY"
assert_json_field "Health status=ok" "$BODY" "status" "ok"

# ---- POST /products ----
echo ""
echo "--- POST /products ---"

# Success case
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${PFX}-p1\",\"name\":\"Widget\",\"category\":\"gadgets\",\"price\":100,\"stock\":50}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Create product success" "201" "$CODE" "$BODY"
assert_json_field "Product id" "$BODY" "id" "${PFX}-p1"
assert_json_field "Product name" "$BODY" "name" "Widget"
assert_json_field "Product price" "$BODY" "price" "100"
assert_json_field "Product stock" "$BODY" "stock" "50"

# Duplicate product → 409
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${PFX}-p1\",\"name\":\"Changed\",\"category\":\"other\",\"price\":999,\"stock\":999}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Duplicate product → 409" "409" "$CODE" "$BODY"
assert_json_error "Duplicate error code" "$BODY" "PRODUCT_EXISTS"

# Verify original unchanged
RESP=$(curl -s -w "\n%{http_code}" "$BASE/products/${PFX}-p1")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Original product unchanged" "200" "$CODE" "$BODY"
assert_json_field "Original name preserved" "$BODY" "name" "Widget"
assert_json_field "Original price preserved" "$BODY" "price" "100"

# Missing fields → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{"id":"x","name":"y"}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Missing fields → 400" "400" "$CODE" "$BODY"
assert_json_error "Missing fields error" "$BODY" "VALIDATION_ERROR"

# String price → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{"id":"x","name":"y","category":"z","price":"10","stock":5}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "String price → 400" "400" "$CODE" "$BODY"
assert_json_error "String price error" "$BODY" "VALIDATION_ERROR"

# Float stock → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{"id":"x","name":"y","category":"z","price":10,"stock":5.5}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Float stock → 400" "400" "$CODE" "$BODY"
assert_json_error "Float stock error" "$BODY" "VALIDATION_ERROR"

# Negative price → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{"id":"x","name":"y","category":"z","price":-1,"stock":5}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Negative price → 400" "400" "$CODE" "$BODY"
assert_json_error "Negative price error" "$BODY" "VALIDATION_ERROR"

# Null field → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{"id":"x","name":"y","category":"z","price":null,"stock":5}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Null price → 400" "400" "$CODE" "$BODY"

# Bool field → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{"id":"x","name":"y","category":"z","price":true,"stock":5}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Bool price → 400" "400" "$CODE" "$BODY"

# Empty body → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Empty body → 400" "400" "$CODE" "$BODY"

# Malformed JSON → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{bad json}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Malformed JSON → 400" "400" "$CODE" "$BODY"

# Empty id → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d '{"id":"","name":"y","category":"z","price":10,"stock":5}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Empty id → 400" "400" "$CODE" "$BODY"

# Zero price and stock (valid)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${PFX}-p0\",\"name\":\"Free\",\"category\":\"free\",\"price\":0,\"stock\":0}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Zero price/stock → 201" "201" "$CODE" "$BODY"

# ---- GET /products/:id ----
echo ""
echo "--- GET /products/:id ---"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/products/${PFX}-p1")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Get existing product" "200" "$CODE" "$BODY"
assert_json_field "Get product id" "$BODY" "id" "${PFX}-p1"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/products/nonexistent-xyz")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Unknown product → 404" "404" "$CODE" "$BODY"
assert_json_error "Unknown product error" "$BODY" "PRODUCT_NOT_FOUND"

# ---- GET /products?category= ----
echo ""
echo "--- GET /products?category= ---"

# Create some products for listing
for i in $(seq 1 5); do
    curl -s -X POST "$BASE/products" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"${PFX}-list${i}\",\"name\":\"Item ${i}\",\"category\":\"${PFX}-cat\",\"price\":$((i*10)),\"stock\":100}" > /dev/null
done

RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "List products" "200" "$CODE" "$BODY"
assert_json_field "List total" "$BODY" "total" "5"
assert_json_field "List page" "$BODY" "page" "1"
assert_json_field "List limit" "$BODY" "limit" "20"

# Missing category → 400
RESP=$(curl -s -w "\n%{http_code}" "$BASE/products")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Missing category → 400" "400" "$CODE" "$BODY"

# Empty category → 400
RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Empty category → 400" "400" "$CODE" "$BODY"

# Unknown category → 200, empty
RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=nonexistent-category-xyz")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Unknown category → 200" "200" "$CODE" "$BODY"
assert_json_field "Unknown cat total=0" "$BODY" "total" "0"

# Bad page → 400
RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat&page=0")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Page 0 → 400" "400" "$CODE" "$BODY"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat&page=abc")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Page abc → 400" "400" "$CODE" "$BODY"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat&page=1.5")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Page 1.5 → 400" "400" "$CODE" "$BODY"

# Bad limit → 400
RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat&limit=0")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Limit 0 → 400" "400" "$CODE" "$BODY"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat&limit=51")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Limit 51 → 400" "400" "$CODE" "$BODY"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat&limit=abc")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Limit abc → 400" "400" "$CODE" "$BODY"

# Page past the end → 200, empty items, real total
RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat&page=100")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Page past end → 200" "200" "$CODE" "$BODY"
assert_json_field "Past end total=5" "$BODY" "total" "5"

# Pagination: limit=2, page=1
RESP=$(curl -s -w "\n%{http_code}" "$BASE/products?category=${PFX}-cat&limit=2&page=1")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Paginated limit=2 page=1" "200" "$CODE" "$BODY"

# ---- POST /orders ----
echo ""
echo "--- POST /orders ---"

# Create a product for ordering
curl -s -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${PFX}-ord1\",\"name\":\"Orderable\",\"category\":\"orders\",\"price\":50,\"stock\":2}" > /dev/null

# Success
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"user1\",\"productId\":\"${PFX}-ord1\"}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Create order success" "201" "$CODE" "$BODY"
assert_json_field "Order userId" "$BODY" "userId" "user1"
assert_json_field "Order productId" "$BODY" "productId" "${PFX}-ord1"

# Check orderId exists and non-empty
ORDER_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('orderId',''))" 2>/dev/null)
TOTAL=$((TOTAL+1))
if [ -n "$ORDER_ID" ]; then
    PASS=$((PASS+1))
    echo -e "${GREEN}✓${NC} Order has non-empty orderId ($ORDER_ID)"
else
    FAIL=$((FAIL+1))
    echo -e "${RED}✗${NC} Order missing orderId"
fi

# Duplicate purchase → 409
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"user1\",\"productId\":\"${PFX}-ord1\"}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Duplicate purchase → 409" "409" "$CODE" "$BODY"
assert_json_error "Duplicate purchase code" "$BODY" "ALREADY_PURCHASED"

# Second user buys same product (stock=2, so this should work)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"user2\",\"productId\":\"${PFX}-ord1\"}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Second user buys" "201" "$CODE" "$BODY"

# Third user → sold out (stock was 2)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"user3\",\"productId\":\"${PFX}-ord1\"}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Sold out → 409" "409" "$CODE" "$BODY"
assert_json_error "Sold out code" "$BODY" "SOLD_OUT"

# Unknown product → 404
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d '{"userId":"user1","productId":"nonexistent-product"}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Unknown product order → 404" "404" "$CODE" "$BODY"
assert_json_error "Unknown product error" "$BODY" "PRODUCT_NOT_FOUND"

# Missing userId → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"productId\":\"${PFX}-ord1\"}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Missing userId → 400" "400" "$CODE" "$BODY"
assert_json_error "Missing userId error" "$BODY" "VALIDATION_ERROR"

# Missing productId → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d '{"userId":"user1"}')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Missing productId → 400" "400" "$CODE" "$BODY"

# Empty userId → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"\",\"productId\":\"${PFX}-ord1\"}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Empty userId → 400" "400" "$CODE" "$BODY"

# Non-string userId → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":123,\"productId\":\"${PFX}-ord1\"}")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Non-string userId → 400" "400" "$CODE" "$BODY"

# Empty body → 400
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d '')
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Empty order body → 400" "400" "$CODE" "$BODY"

# ---- GET /users/:userId/orders ----
echo ""
echo "--- GET /users/:userId/orders ---"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/users/user1/orders")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "Get user orders" "200" "$CODE" "$BODY"
assert_json_field "User orders userId" "$BODY" "userId" "user1"

# User with no orders → 200, empty list (not 404)
RESP=$(curl -s -w "\n%{http_code}" "$BASE/users/unknown-user-xyz/orders")
BODY=$(echo "$RESP" | head -n -1)
CODE=$(echo "$RESP" | tail -1)
assert_status "No orders user → 200" "200" "$CODE" "$BODY"
assert_json_field "No orders userId" "$BODY" "userId" "unknown-user-xyz"

echo ""
echo "============================================"
echo "  RESULTS: $PASS passed, $FAIL failed (of $TOTAL)"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
