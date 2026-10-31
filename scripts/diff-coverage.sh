#!/usr/bin/env bash
# Diff coverage: what fraction of the lines THIS BRANCH changed are covered?
#
#   bash diff-coverage.sh                              compare against origin/main
#   bash diff-coverage.sh --base main --threshold 80
#   bash diff-coverage.sh --from TestResults/.../coverage.cobertura.xml
#
# Why this matters more than total coverage:
#
#   Total coverage moves slowly and says nothing about the change in front of
#   you. A pull request can add 200 untested lines to a 10,000-line codebase and
#   barely move the number. Diff coverage asks the question a reviewer actually
#   cares about: "is the code you just wrote tested?"
#
# Exit code 0 only if the gate passes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$ROOT/.git" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

BASE="origin/main"
THRESHOLD=80
FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base)      BASE="${2:-origin/main}"; shift 2 ;;
    --threshold) THRESHOLD="${2:-80}"; shift 2 ;;
    --from)      FROM="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

if [ -z "$FROM" ]; then
  FROM="$(find TestResults -name 'coverage.cobertura.xml' 2>/dev/null | head -1)"
fi
[ -n "$FROM" ] && [ -f "$FROM" ] || {
  echo "No coverage report found. Run coverage-gate.sh first."; exit 1; }

git rev-parse --verify --quiet "$BASE" >/dev/null || {
  echo "Base ref '$BASE' not found. Try --base main."; exit 1; }

MERGE_BASE="$(git merge-base "$BASE" HEAD)"

# Added/modified line numbers per file, from the unified diff.
DIFF_LINES="$(git diff --unified=0 "$MERGE_BASE"...HEAD -- '*.cs' \
  | awk '
      /^\+\+\+ b\// { file = substr($0, 7); next }
      /^@@/ {
        # @@ -a,b +c,d @@   -> lines c .. c+d-1 on the new side
        match($0, /\+[0-9]+(,[0-9]+)?/)
        spec = substr($0, RSTART + 1, RLENGTH - 1)
        split(spec, p, ",")
        start = p[1] + 0
        count = (p[2] == "" ? 1 : p[2] + 0)
        for (i = 0; i < count; i++) print file ":" (start + i)
      }')"

if [ -z "$DIFF_LINES" ]; then
  printf '\n  No C# lines changed against %s. Diff coverage gate skipped.\n\n' "$BASE"
  exit 0
fi

# The analysis runs from a temp file, not `python3 -`: that form reads the
# program itself from stdin, which would leave no stdin for the data.
LINES_FILE="$(mktemp)"
ANALYSER="$(mktemp /tmp/diffcov-XXXXXX.py)"
trap 'rm -f "$LINES_FILE" "$ANALYSER"' EXIT
printf '%s\n' "$DIFF_LINES" > "$LINES_FILE"

cat > "$ANALYSER" <<'PY'
import sys, os, xml.etree.ElementTree as ET
from collections import defaultdict

report, threshold, base, lines_file = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]

changed = defaultdict(set)
with open(lines_file, encoding='utf-8') as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw or ':' not in raw:
            continue
        path, num = raw.rsplit(':', 1)
        try:
            changed[os.path.normpath(path)].add(int(num))
        except ValueError:
            continue

# Coverable lines and their hit counts, keyed by normalised file path.
hits = defaultdict(dict)
root = ET.parse(report).getroot()

for cls in root.iter('class'):
    filename = cls.get('filename') or ''
    for line in cls.iter('line'):
        try:
            n = int(line.get('number'))
            h = int(line.get('hits', 0))
        except (TypeError, ValueError):
            continue
        hits[os.path.normpath(filename)][n] = h

def lookup(path):
    """Match a diff path against a report path, tolerating different roots."""
    if path in hits:
        return hits[path]
    for reported in hits:
        if reported.endswith(path) or path.endswith(reported):
            return hits[reported]
    return None

total = covered = 0
uncovered = defaultdict(list)
skipped = []

for path in sorted(changed):
    table = lookup(path)
    if table is None:
        skipped.append(path)
        continue
    for n in sorted(changed[path]):
        if n not in table:          # not a coverable line (blank, brace, comment)
            continue
        total += 1
        if table[n] > 0:
            covered += 1
        else:
            uncovered[path].append(n)

print()
print(f"  Diff coverage against {base}")
print()

if total == 0:
    print("  No coverable lines changed. Gate skipped.")
    if skipped:
        print(f"  ({len(skipped)} changed file(s) not present in the coverage report)")
    print()
    sys.exit(0)

pct = round(covered / total * 100, 2)
print(f"  Changed coverable lines : {total}")
print(f"  Covered                 : {covered}")
print(f"  Diff coverage           : {pct}%   (threshold {threshold}%)")
print()

if uncovered:
    print("  Changed lines with no test exercising them:")
    for path in sorted(uncovered):
        nums = uncovered[path]
        shown = ', '.join(str(n) for n in nums[:12])
        more = f" (+{len(nums) - 12} more)" if len(nums) > 12 else ""
        print(f"    {path}: {shown}{more}")
    print()

if skipped:
    print(f"  Note: {len(skipped)} changed file(s) are outside the coverage scope:")
    for p in skipped[:5]:
        print(f"    {p}")
    print()

if pct >= threshold:
    print("  \033[1;32mDIFF COVERAGE GATE PASSED\033[0m")
    print()
    sys.exit(0)

print(f"  \033[1;31mDIFF COVERAGE GATE FAILED\033[0m - {pct}% is below {threshold}%")
print()
print("  Total coverage can stay flat while a pull request adds untested code.")
print("  This gate asks the question a reviewer actually cares about:")
print("  is the code you just wrote tested?")
print()
sys.exit(1)
PY

python3 "$ANALYSER" "$FROM" "$THRESHOLD" "$BASE" "$LINES_FILE"
