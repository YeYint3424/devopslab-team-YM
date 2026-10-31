#!/usr/bin/env bash
# Coverage gate for DevOpsLab.
#
#   bash coverage-gate.sh                    run tests, report, enforce 75%
#   bash coverage-gate.sh --threshold 80     enforce a different threshold
#   bash coverage-gate.sh --report-only      measure without failing
#   bash coverage-gate.sh --from <file.xml>  skip the test run, use an existing report
#
# Exit code 0 only if the gate passes. From Session 5 this runs in CI and a
# non-zero exit blocks the merge.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/DevOpsLab.sln" ] || ROOT="$(pwd)"
cd "$ROOT"

THRESHOLD=75
REPORT_ONLY=0
FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)   THRESHOLD="${2:-75}"; shift 2 ;;
    --report-only) REPORT_ONLY=1; shift ;;
    --from)        FROM="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

if [ -z "$FROM" ]; then
  rm -rf TestResults
  dotnet test --settings coverlet.runsettings \
              --collect:"XPlat Code Coverage" \
              --results-directory TestResults --nologo || {
    echo; echo "  Tests failed. The coverage gate is not even reached."; exit 1; }
  FROM="$(find TestResults -name 'coverage.cobertura.xml' | head -1)"
fi

[ -n "$FROM" ] && [ -f "$FROM" ] || { echo "No coverage report found."; exit 1; }

read -r LINE_RATE BRANCH_RATE COVERED VALID <<EOF
$(python3 - "$FROM" <<'PY'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
def pct(a): 
    try: return round(float(r.get(a, 0)) * 100, 2)
    except (TypeError, ValueError): return 0.0
print(pct('line-rate'), pct('branch-rate'),
      r.get('lines-covered', '?'), r.get('lines-valid', '?'))
PY
)
EOF

printf '\n  Coverage report: %s\n\n' "$FROM"
printf '  Line coverage   : %s%%   (%s of %s lines)\n' "$LINE_RATE" "$COVERED" "$VALID"
printf '  Branch coverage : %s%%\n' "$BRANCH_RATE"
printf '  Threshold       : %s%% (line)\n\n' "$THRESHOLD"

if [ "$REPORT_ONLY" -eq 1 ]; then
  echo "  Report only - gate not enforced."
  exit 0
fi

if awk -v a="$LINE_RATE" -v b="$THRESHOLD" 'BEGIN { exit !(a+0 >= b+0) }'; then
  printf '  \033[1;32mCOVERAGE GATE PASSED\033[0m\n\n'
  printf '  Remember what this does NOT prove: coverage measures which lines ran,\n'
  printf '  not whether anything was asserted (Session 3).\n\n'
  exit 0
fi

printf '  \033[1;31mCOVERAGE GATE FAILED\033[0m - %s%% is below %s%%\n\n' "$LINE_RATE" "$THRESHOLD"
printf '  Raise it by testing behaviour. Deleting code and adding assertion-free\n'
printf '  tests both work, and both are cheating.\n\n'
exit 1
