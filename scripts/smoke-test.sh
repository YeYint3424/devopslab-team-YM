#!/usr/bin/env bash
# Smoke test for a deployed DevOpsLab API.
#
#   bash smoke-test.sh http://localhost:5080
#   bash smoke-test.sh https://staging.example.com --timeout 120
#
# Exit code 0 only if EVERY check passes. Any other code means the deployment
# must not be promoted. From Session 9 the CD pipeline runs this and stops on a
# non-zero exit - which is the whole reason the exit code matters more than the
# pretty output.
set -uo pipefail

BASE="${1:-}"
[ -n "$BASE" ] || { echo "usage: smoke-test.sh <base-url> [--timeout SECONDS]"; exit 2; }
BASE="${BASE%/}"
shift

TIMEOUT=60
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="${2:-60}"; shift 2 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# status <url> -> prints HTTP status code, or 000 if unreachable
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000; }
body()   { curl -s --max-time 10 "$1" 2>/dev/null || true; }

printf '\nSmoke test: %s\n\n' "$BASE"

# ---------------------------------------------------------------------------
# 1. Readiness gate. Nothing else is meaningful until the service is ready.
#    Note this waits for /healthz/ready, NOT /healthz/live - a process that has
#    started is not a process that can serve a request (Session 1).
# ---------------------------------------------------------------------------
printf '  ....  waiting for readiness (up to %ss)' "$TIMEOUT"
deadline=$(( $(date +%s) + TIMEOUT ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ "$(status "$BASE/healthz/ready")" = "200" ]; then ready=1; break; fi
  printf '.'
  sleep 2
done
# End the progress line. No carriage-return tricks: a CI log is not a terminal,
# and every result must be greppable on its own line.
printf '\n'

if [ "$ready" -eq 1 ]; then
  ok "readiness  /healthz/ready returned 200"
else
  bad "readiness  /healthz/ready did not return 200 within ${TIMEOUT}s" \
      "Nothing downstream can be trusted. Stopping here."
  printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Liveness must also answer.
# ---------------------------------------------------------------------------
code=$(status "$BASE/healthz/live")
[ "$code" = "200" ] && ok "liveness   /healthz/live returned 200" \
                    || bad "liveness   /healthz/live returned $code, expected 200"

# ---------------------------------------------------------------------------
# 3. The catalogue responds and actually contains data.
#    "Returns 200" is not enough - an empty catalogue means the seed failed.
# ---------------------------------------------------------------------------
code=$(status "$BASE/api/products")
if [ "$code" = "200" ]; then
  payload=$(body "$BASE/api/products")
  count=$(printf '%s' "$payload" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    print(len(d.get("items", [])) if isinstance(d, dict) else -1)
except Exception:
    print(-1)
' 2>/dev/null || echo -1)
  if [ "$count" -gt 0 ] 2>/dev/null; then
    ok "catalogue  /api/products returned 200 with $count item(s)"
  elif [ "$count" = "0" ]; then
    bad "catalogue  /api/products returned 200 but the catalogue is EMPTY" \
        "The service is up but the seed or migration did not run."
  else
    bad "catalogue  /api/products returned 200 but the body is not the expected JSON"
  fi
else
  bad "catalogue  /api/products returned $code, expected 200"
fi

# ---------------------------------------------------------------------------
# 4. A missing resource is a 404, not a 500. Error paths are part of the
#    contract - a deployment that 500s on a typo is a broken deployment.
# ---------------------------------------------------------------------------
code=$(status "$BASE/api/products/00000000-0000-0000-0000-000000000000")
[ "$code" = "404" ] && ok "not found  unknown product returned 404" \
                    || bad "not found  unknown product returned $code, expected 404"

# ---------------------------------------------------------------------------
# 5. A broken business rule is a 400 carrying a machine-readable rule field.
# ---------------------------------------------------------------------------
resp=$(curl -s -w '\n%{http_code}' --max-time 10 \
       -X POST "$BASE/api/products" \
       -H 'Content-Type: application/json' \
       -d '{"categoryId":"00000000-0000-0000-0000-000000000000","sku":"SMOKE-001","name":"Smoke test","price":-1,"stockQuantity":1}' \
       2>/dev/null || true)
code=$(printf '%s' "$resp" | tail -n1)
json=$(printf '%s' "$resp" | sed '$d')

if [ "$code" = "400" ] || [ "$code" = "404" ]; then
  has_rule=$(printf '%s' "$json" | python3 -c '
import json,sys
try:
    print("yes" if "rule" in json.load(sys.stdin) else "no")
except Exception:
    print("no")
' 2>/dev/null || echo no)
  if [ "$code" = "400" ] && [ "$has_rule" = "yes" ]; then
    ok "error path invalid product returned 400 with a rule field"
  elif [ "$code" = "400" ]; then
    bad "error path invalid product returned 400 but no rule field in the body"
  else
    ok "error path invalid product was rejected with 404 (unknown category checked first)"
  fi
else
  bad "error path invalid product returned $code, expected 400 or 404"
fi

# ---------------------------------------------------------------------------
printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf '  \033[1;31mSMOKE TEST FAILED\033[0m - this build must not be promoted.\n\n'
  exit 1
fi
printf '  \033[1;32mSMOKE TEST PASSED\033[0m\n\n'
exit 0
