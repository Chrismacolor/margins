#!/usr/bin/env bash
#
# Tests for Resources/margins-cli. Runs the shim in MARGINS_DRY_RUN=1 mode so
# nothing is ever opened; asserts on the printed dispatch lines.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$(cd -- "$SCRIPT_DIR/.." && pwd)/Resources/margins-cli"

export MARGINS_DRY_RUN=1
failures=0

check() { # $1 = description, $2 = expected, $3 = actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok  $1"
  else
    echo "  FAIL  $1"
    echo "        expected: $2"
    echo "        actual:   $3"
    failures=$((failures + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/sub dir" "$TMP/node_modules" "$TMP/.hidden" "$TMP/empty"
printf 'old\n' > "$TMP/old.md";                 touch -t 202601010000 "$TMP/old.md"
printf 'new\n' > "$TMP/sub dir/new.md";         touch -t 202606010000 "$TMP/sub dir/new.md"
printf 'skip\n' > "$TMP/node_modules/skip.md";  touch -t 202612310000 "$TMP/node_modules/skip.md"
printf 'skip\n' > "$TMP/.hidden/skip.md";       touch -t 202612310000 "$TMP/.hidden/skip.md"
printf 'txt\n' > "$TMP/newest.txt";             touch -t 202612310000 "$TMP/newest.txt"

echo "CLI shim"

check "plain file passes through" \
  "DRY $TMP/old.md" \
  "$("$CLI" "$TMP/old.md")"

check "-g threads through to open" \
  "DRY -g $TMP/old.md" \
  "$("$CLI" -g "$TMP/old.md")"

check "directory resolves to newest markdown (spaces, skips hidden/node_modules/non-md)" \
  "DRY $TMP/sub dir/new.md" \
  "$("$CLI" "$TMP")"

set +e
err="$("$CLI" "$TMP/empty" 2>&1)"
code=$?
set -e
check "empty directory fails with exit 66" "66" "$code"
check "empty directory error message" "margins: no Markdown files under $TMP/empty" "$err"

check "--watch passes the directory through (no newest-md resolution)" \
  "DRY $TMP" \
  "$("$CLI" --watch "$TMP")"

check "-w with no argument watches the current directory" \
  "DRY ." \
  "$("$CLI" -w)"

check "-g and -w combine" \
  "DRY -g $TMP" \
  "$("$CLI" -g -w "$TMP")"

check "--watch accepts a folder with no Markdown yet" \
  "DRY $TMP/empty" \
  "$("$CLI" --watch "$TMP/empty")"

set +e
err="$("$CLI" -w "$TMP/old.md" 2>&1)"
code=$?
set -e
check "--watch rejects file arguments with exit 64" "64" "$code"
check "--watch file-argument error message" \
  "margins: --watch expects a directory, got $TMP/old.md" "$err"

out="$(printf '# hi\n' | "$CLI" -)"
check "stdin spools to a temp stdin.md" "stdin.md" "$(basename "${out#DRY }")"
check "stdin content reaches the spool file" "# hi" "$(cat "${out#DRY }")"

"$CLI" --help > /dev/null
check "--help exits 0" "0" "$?"

if [[ $failures -gt 0 ]]; then
  echo ""
  echo "$failures CLI test(s) FAILED"
  exit 1
fi
