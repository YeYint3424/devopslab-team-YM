#!/usr/bin/env bash
# Smoke test: exit 0 = deployment healthy, exit 1 = broken.
set -uo pipefail

BASE_URL="${1:-http://localhost:5080}"
FAILED=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

echo "Smoke testing $BASE_URL"

# 1. Wait for READY, up to 30s
ready=0; code=000
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/healthz/ready")
  [ "$code" = "200" ] && ready=1 && break
  sleep 2
done
[ $ready -eq 1 ] && pass "/healthz/ready returns 200" || fail "/healthz/ready returned $code"

# 2. Liveness
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/healthz/live")
[ "$code" = "200" ] && pass "/healthz/live returns 200" || fail "/healthz/live returned $code"

# 3. Product list returns 200 WITH items
body=$(curl -s -w '\n%{http_code}' "$BASE_URL/api/products")
code=$(echo "$body" | tail -n1); json=$(echo "$body" | sed '$d')
count=$(echo "$json" | grep -o '"totalCount":[0-9]*' | head -1 | cut -d: -f2)
if [ "$code" = "200" ] && [ "${count:-0}" -gt 0 ]; then
  pass "/api/products returns 200 with $count items"
else
  fail "/api/products returned $code with ${count:-0} items"
fi

# 4. Unknown id returns 404
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/products/00000000-0000-0000-0000-000000000001")
[ "$code" = "404" ] && pass "unknown id returns 404" || fail "unknown id returned $code (expected 404)"

# 5. Invalid product returns 400 with a 'rule' field
category=$(echo "$json" | grep -o '"categoryId":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(curl -s -w '\n%{http_code}' -X POST "$BASE_URL/api/products" \
  -H 'Content-Type: application/json' \
  -d "{\"categoryId\":\"${category}\",\"sku\":\"SMOKE-NEG\",\"name\":\"Smoke invalid\",\"price\":-5,\"stockQuantity\":1}")
code=$(echo "$resp" | tail -n1); rbody=$(echo "$resp" | sed '$d')
if [ "$code" = "400" ] && echo "$rbody" | grep -q '"rule"'; then
  pass "invalid product returns 400 with 'rule'"
else
  fail "invalid product returned $code (expected 400 with 'rule')"
fi

if [ $FAILED -eq 0 ]; then echo "SMOKE TEST PASSED"; exit 0; else echo "SMOKE TEST FAILED"; exit 1; fi
