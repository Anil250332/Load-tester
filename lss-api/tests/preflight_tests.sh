#!/usr/bin/env bash
# preflight_tests.sh — 3 explicit pre-flight tests from rules document
set -euo pipefail

BASE="${1:-http://localhost:8080}"

echo "=========================================================="
echo "  PRE-FLIGHT TEST 1: LAST-UNIT (stock 1, 50 concurrent buyers)"
echo "=========================================================="
curl -s -X POST "$BASE/products" \
  -H "Content-Type: application/json" \
  -d '{"id":"pf-last-1","name":"Last Unit Preflight","category":"preflight","price":10,"stock":1}'
echo ""

TMPDIR=$(mktemp -d)
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"pf-u-${i}\",\"productId\":\"pf-last-1\"}" > "$TMPDIR/code_${i}.txt" &
done
wait

C201=$(grep -h "201" "$TMPDIR"/code_*.txt 2>/dev/null | wc -l || echo 0)
C409=$(grep -h "409" "$TMPDIR"/code_*.txt 2>/dev/null | wc -l || echo 0)
rm -rf "$TMPDIR"

FINAL_STOCK=$(curl -s "$BASE/products/pf-last-1" | python3 -c "import sys,json; print(json.load(sys.stdin)['stock'])")
echo "  201 count   : $C201 (expected: 1)"
echo "  409 count   : $C409 (expected: 49)"
echo "  Final stock : $FINAL_STOCK (expected: 0)"

if [ "$C201" = "1" ] && [ "$C409" = "49" ] && [ "$FINAL_STOCK" = "0" ]; then
  echo "✓ PRE-FLIGHT 1 PASSED"
else
  echo "✗ PRE-FLIGHT 1 FAILED"
  exit 1
fi

echo ""
echo "=========================================================="
echo "  PRE-FLIGHT TEST 2: DOUBLE-CLICK (same user 20 times, stock 1000)"
echo "=========================================================="
curl -s -X POST "$BASE/products" \
  -H "Content-Type: application/json" \
  -d '{"id":"pf-dc-1","name":"Double Click Preflight","category":"preflight","price":50,"stock":1000}'
echo ""

TMPDIR=$(mktemp -d)
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$BASE/orders" \
    -H "Content-Type: application/json" \
    -d '{"userId":"pf-dc-user","productId":"pf-dc-1"}' > "$TMPDIR/code_${i}.txt" &
done
wait

DC201=$(grep -h "201" "$TMPDIR"/code_*.txt 2>/dev/null | wc -l || echo 0)
DC409=$(grep -h "409" "$TMPDIR"/code_*.txt 2>/dev/null | wc -l || echo 0)
rm -rf "$TMPDIR"

DC_STOCK=$(curl -s "$BASE/products/pf-dc-1" | python3 -c "import sys,json; print(json.load(sys.stdin)['stock'])")
DC_ORDERS=$(curl -s "$BASE/users/pf-dc-user/orders" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['orders']))")
echo "  201 count   : $DC201 (expected: 1)"
echo "  409 count   : $DC409 (expected: 19)"
echo "  Stock left  : $DC_STOCK (expected: 999)"
echo "  User orders : $DC_ORDERS (expected: 1)"

if [ "$DC201" = "1" ] && [ "$DC409" = "19" ] && [ "$DC_STOCK" = "999" ] && [ "$DC_ORDERS" = "1" ]; then
  echo "✓ PRE-FLIGHT 2 PASSED"
else
  echo "✗ PRE-FLIGHT 2 FAILED"
  exit 1
fi

echo ""
echo "=========================================================="
echo "  PRE-FLIGHT TEST 3: CRASH & RECOVERY (kill -9 app PID)"
echo "=========================================================="
OLD_PID=$(pgrep -x lss-api)
echo "Current lss-api PID: $OLD_PID"

echo "Executing sudo kill -9 $OLD_PID..."
sudo kill -9 "$OLD_PID"

echo "Waiting 2 seconds for systemd to restart the service..."
sleep 2

NEW_PID=$(pgrep -x lss-api || echo "NONE")
echo "New lss-api PID: $NEW_PID"

if [ "$NEW_PID" != "$OLD_PID" ] && [ "$NEW_PID" != "NONE" ]; then
  echo "✓ lss-api restarted automatically with new PID $NEW_PID"
else
  echo "✗ lss-api failed to restart"
  exit 1
fi

echo "Probing /health endpoint..."
curl -s -i "$BASE/health"
echo ""

HEALTH_STATUS=$(curl -s "$BASE/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
if [ "$HEALTH_STATUS" = "ok" ]; then
  echo "✓ Health is ok"
else
  echo "✗ Health failed: $HEALTH_STATUS"
  exit 1
fi

echo "Verifying persisted data (pf-dc-1 stock and orders)..."
P_STOCK=$(curl -s "$BASE/products/pf-dc-1" | python3 -c "import sys,json; print(json.load(sys.stdin)['stock'])")
U_ORDERS=$(curl -s "$BASE/users/pf-dc-user/orders" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['orders']))")

echo "  Product pf-dc-1 stock: $P_STOCK (expected: 999)"
echo "  User pf-dc-user orders: $U_ORDERS (expected: 1)"

if [ "$P_STOCK" = "999" ] && [ "$U_ORDERS" = "1" ]; then
  echo "✓ Data intact after crash recovery"
  echo "✓ PRE-FLIGHT 3 PASSED"
else
  echo "✗ Data check failed after crash"
  exit 1
fi

echo ""
echo "=========================================================="
echo "  ALL PRE-FLIGHT TESTS COMPLETED SUCCESSFULLY!"
echo "=========================================================="
