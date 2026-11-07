#!/usr/bin/env bash
# =============================================================================
# readiness-experiment.sh — the Session 6 pivot, measured.
#
#   ./readiness-experiment.sh [base-url] [db-service]
#   default: http://localhost:8080   sqlserver
#
# Steps
#   1. Record /healthz/live and /healthz/ready while everything is up.
#   2. Stop the database.
#   3. Record both endpoints again.
#   4. Start the database and measure how long readiness takes to return.
#
# Expected with CORRECT tagging:  live stays 200, ready goes 503, and readiness
# recovers on its own without restarting anything.
#
# Exit 0 when that is what happened; exit 1 when it is not — this script is a
# gate, not a report. Run it again after mis-tagging the database check and read
# the failure: that is the lesson.
# =============================================================================
set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
DB_SERVICE="${2:-sqlserver}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-120}"
PROBE_SETTLE="${PROBE_SETTLE:-5}"   # seconds to let one probe cycle run after a change

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }
row()  { printf '  %-22s %-16s %s\n' "$1" "$2" "$3"; }

live_url="$BASE_URL/healthz/live"
ready_url="$BASE_URL/healthz/ready"
failures=0

printf '\n== 1. Baseline — everything up ==\n'
b_live="$(code "$live_url")"; b_ready="$(code "$ready_url")"
row "/healthz/live"  "$b_live"  "expected 200"
row "/healthz/ready" "$b_ready" "expected 200"
[ "$b_live"  = "200" ] || { printf 'FAIL baseline liveness is %s\n'  "$b_live";  failures=$((failures+1)); }
[ "$b_ready" = "200" ] || { printf 'FAIL baseline readiness is %s\n' "$b_ready"; failures=$((failures+1)); }

if [ "$failures" -ne 0 ]; then
    printf '\nThe system is not healthy to begin with. Fix that before running the experiment.\n'
    exit 1
fi

printf '\n== 2. Stopping the database (%s) ==\n' "$DB_SERVICE"
docker compose stop "$DB_SERVICE" >/dev/null
# The readiness check caches nothing, but the probe still needs one cycle to run.
sleep "$PROBE_SETTLE"

printf '\n== 3. Database down ==\n'
d_live="$(code "$live_url")"; d_ready="$(code "$ready_url")"
row "/healthz/live"  "$d_live"  "expected 200 — the process is fine"
row "/healthz/ready" "$d_ready" "expected 503 — the dependency is not"

if [ "$d_live" != "200" ]; then
    printf '\nFAIL  liveness returned %s while only the DATABASE was stopped.\n' "$d_live"
    printf '      The database check is tagged "live". A dependency outage is now\n'
    printf '      reported as a broken process. Under Kubernetes this restarts the\n'
    printf '      pod; a restart cannot bring a database back.\n'
    failures=$((failures+1))
fi
if [ "$d_ready" != "503" ]; then
    printf '\nFAIL  readiness returned %s with the database stopped.\n' "$d_ready"
    printf '      If it returned 200, check whether any check is still tagged "ready".\n'
    printf '      A readiness endpoint with no checks behind it always answers Healthy —\n'
    printf '      an empty gate is a green gate.\n'
    failures=$((failures+1))
fi

printf '\n== 4. Starting the database again ==\n'
docker compose start "$DB_SERVICE" >/dev/null
start_ts=$(date +%s); recovered=0
while [ $(( $(date +%s) - start_ts )) -lt "$RECOVERY_TIMEOUT" ]; do
    if [ "$(code "$ready_url")" = "200" ]; then recovered=1; break; fi
    sleep 3
done
elapsed=$(( $(date +%s) - start_ts ))

if [ "$recovered" -eq 1 ]; then
    row "recovery" "${elapsed}s" "readiness returned to 200 with no restart"
else
    printf 'FAIL  readiness did not recover within %ss\n' "$RECOVERY_TIMEOUT"
    failures=$((failures+1))
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS  Liveness and readiness are tagged correctly.\n'
    printf '      Record the recovery time (%ss) in your Lab 3 evidence.\n' "$elapsed"
    exit 0
fi
printf 'FAIL  %s check(s) failed. Read the messages above before changing anything.\n' "$failures"
exit 1
