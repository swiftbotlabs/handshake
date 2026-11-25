#!/usr/bin/env bash
# Line/statement/branch/function coverage of the contracts in src/, written to evidence/coverage.txt
# (script/triples.py copies the src/ rows into evidence/EVIDENCE.md), plus the functions no test reaches.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hs-cov.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
forge coverage --report summary --report lcov --report-file "$tmp/lcov.info" --no-match-coverage 'test/|script/' > "$tmp/out.txt"
grep -q " 0 failed" "$tmp/out.txt"
{ echo "forge coverage --report summary ($(forge --version | head -1)), $(date -u +%FT%TZ)"
  grep -E "tests passed|^\| (File|src/|Total)" "$tmp/out.txt"
  # name every branch and line no test reaches (source line quoted)
  python3 -I - "$tmp/lcov.info" <<'PY'
import sys
cur, src = None, []
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("SF:"):
        cur = line[3:]; src = open(cur).read().splitlines()
    elif line.startswith("BRDA:") and line.rsplit(",", 1)[1] in ("0", "-"):
        ln = int(line[5:].split(",")[0]); print(f"MISS branch {cur}:{ln}  {src[ln - 1].strip()}")
    elif line.startswith("DA:") and line.endswith(",0"):
        ln = int(line[3:].split(",")[0]); print(f"MISS line {cur}:{ln}  {src[ln - 1].strip()}")
PY
} > evidence/coverage.txt
cat evidence/coverage.txt
