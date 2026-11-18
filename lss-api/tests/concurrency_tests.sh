#!/usr/bin/env bash
# concurrency_tests.sh — Concurrency correctness tests
# Requires: curl, python3, bash
# Usage: bash tests/concurrency_tests.sh [base_url]
set -euo pipefail

BASE="${1:-http://localhost:8080}"
PASS=0
FAIL=0
TOTAL=0
PFX="cc$(date +%s)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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
echo "  CONCURRENCY TESTS — Base: $BASE"
echo "============================================"

# ---- Test 1: Last Unit (stock=1, 50 users) ----
echo ""
echo "--- Test 1: Last Unit (stock=1, 50 concurrent buyers) ---"

PROD_ID="${PFX}-last1"
curl -s -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${PROD_ID}\",\"name\":\"Last Unit Item\",\"category\":\"flash\",\"price\":99,\"stock\":1}" > /dev/null

# Fire 50 concurrent requests
TMPDIR=$(mktemp -d)
for i in $(seq 1 50); do
    curl -s -o "${TMPDIR}/resp_${i}.txt" -w "%{http_code}" -X POST "$BASE/orders" \
        -H "Content-Type: application/json" \
        -d "{\"userId\":\"lu-user-${i}\",\"productId\":\"${PROD_ID}\"}" > "${TMPDIR}/code_${i}.txt" &
done
wait

COUNT_201=0
COUNT_409=0
for i in $(seq 1 50); do
    CODE=$(cat "${TMPDIR}/code_${i}.txt" 2>/dev/null || echo "000")
    if [ "$CODE" = "201" ]; then COUNT_201=$((COUNT_201+1)); fi
    if [ "$CODE" = "409" ]; then COUNT_409=$((COUNT_409+1)); fi
done
rm -rf "$TMPDIR"

check "Last unit: exactly 1 × 201" "$([ "$COUNT_201" = "1" ] && echo true || echo false)"
check "Last unit: 49 × 409" "$([ "$COUNT_409" = "49" ] && echo true || echo false)"

# Check final stock
sleep 2
STOCK=$(curl -s "$BASE/products/${PROD_ID}" | python3 -c "import sys,json; print(json.load(sys.stdin)['stock'])")
check "Last unit: final stock = 0" "$([ "$STOCK" = "0" ] && echo true || echo false)"

# ---- Test 2: Flash Drop (stock=150, 4000 buyers) ----
echo ""
echo "--- Test 2: Flash Drop (stock=150, 4000 concurrent buyers) ---"

PROD_ID2="${PFX}-flash150"
curl -s -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${PROD_ID2}\",\"name\":\"Flash Drop\",\"category\":\"flash\",\"price\":50,\"stock\":150}" > /dev/null

TMPDIR=$(mktemp -d)
# Fire 4000 concurrent requests (in batches to not overwhelm bash)
for i in $(seq 1 4000); do
    curl -s -o "${TMPDIR}/resp_${i}.txt" -w "%{http_code}" -X POST "$BASE/orders" \
        -H "Content-Type: application/json" \
        -d "{\"userId\":\"fd-user-${i}\",\"productId\":\"${PROD_ID2}\"}" > "${TMPDIR}/code_${i}.txt" &
    # Throttle: max ~200 concurrent curl processes
    if [ $((i % 200)) -eq 0 ]; then wait; fi
done
wait

COUNT_201=0
COUNT_409=0
COUNT_OTHER=0
for i in $(seq 1 4000); do
    CODE=$(cat "${TMPDIR}/code_${i}.txt" 2>/dev/null || echo "000")
    if [ "$CODE" = "201" ]; then COUNT_201=$((COUNT_201+1));
    elif [ "$CODE" = "409" ]; then COUNT_409=$((COUNT_409+1));
    else COUNT_OTHER=$((COUNT_OTHER+1)); fi
done
rm -rf "$TMPDIR"

echo "  Results: 201=$COUNT_201, 409=$COUNT_409, other=$COUNT_OTHER"
check "Flash drop: exactly 150 × 201" "$([ "$COUNT_201" = "150" ] && echo true || echo false)"
check "Flash drop: 3850 × 409" "$([ "$COUNT_409" = "3850" ] && echo true || echo false)"

sleep 2
STOCK=$(curl -s "$BASE/products/${PROD_ID2}" | python3 -c "import sys,json; print(json.load(sys.stdin)['stock'])")
check "Flash drop: final stock = 0" "$([ "$STOCK" = "0" ] && echo true || echo false)"

# ---- Test 3: Double Click (same user, 20 simultaneous) ----
echo ""
echo "--- Test 3: Double Click (same user, same product, 20 times) ---"

PROD_ID3="${PFX}-dc1"
curl -s -X POST "$BASE/products" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${PROD_ID3}\",\"name\":\"DC Item\",\"category\":\"dc\",\"price\":25,\"stock\":100}" > /dev/null

TMPDIR=$(mktemp -d)
for i in $(seq 1 20); do
    curl -s -o "${TMPDIR}/resp_${i}.txt" -w "%{http_code}" -X POST "$BASE/orders" \
        -H "Content-Type: application/json" \
        -d "{\"userId\":\"dc-user\",\"productId\":\"${PROD_ID3}\"}" > "${TMPDIR}/code_${i}.txt" &
done
wait

COUNT_201=0
COUNT_409=0
for i in $(seq 1 20); do
    CODE=$(cat "${TMPDIR}/code_${i}.txt" 2>/dev/null || echo "000")
    if [ "$CODE" = "201" ]; then COUNT_201=$((COUNT_201+1)); fi
    if [ "$CODE" = "409" ]; then COUNT_409=$((COUNT_409+1)); fi
done
rm -rf "$TMPDIR"

check "Double click: exactly 1 × 201" "$([ "$COUNT_201" = "1" ] && echo true || echo false)"
check "Double click: 19 × 409" "$([ "$COUNT_409" = "19" ] && echo true || echo false)"

# Check stock decreased by exactly 1
sleep 2
STOCK=$(curl -s "$BASE/products/${PROD_ID3}" | python3 -c "import sys,json; print(json.load(sys.stdin)['stock'])")
check "Double click: stock = 99" "$([ "$STOCK" = "99" ] && echo true || echo false)"

# Check user has exactly 1 order
ORDERS_COUNT=$(curl -s "$BASE/users/dc-user/orders" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['orders']))")
check "Double click: user has 1 order" "$([ "$ORDERS_COUNT" = "1" ] && echo true || echo false)"

# ---- Test 4: Retry after success ----
echo ""
echo "--- Test 4: Retry won order ---"

RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"dc-user\",\"productId\":\"${PROD_ID3}\"}")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -n -1)
ERROR=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null)
check "Retry → ALREADY_PURCHASED" "$([ "$CODE" = "409" ] && [ "$ERROR" = "ALREADY_PURCHASED" ] && echo true || echo false)"

echo ""
echo "============================================"
echo "  RESULTS: $PASS passed, $FAIL failed (of $TOTAL)"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
