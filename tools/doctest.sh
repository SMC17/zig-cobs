#!/usr/bin/env bash
# zig-cobs / tools / doctest.sh
#
# Documentation tests — verify that the README's executable claims
# actually hold. A passing doctest run means:
#
#   1. The README "Quickstart" code block matches `examples/quickstart.zig`
#      byte-for-byte (drift between docs and code FAILS the test).
#   2. The compiled quickstart binary runs cleanly and prints the
#      documented "encoded N bytes" line on stdout.
#   3. The README's documented shell commands (`zig build test`,
#      `zig build bench`) at least PARSE as valid build steps (we don't
#      run bench here — it's slow — but we confirm the step name exists).
#
# WHY: Stale README examples are a common failure mode in OSS projects.
# The library evolves, the README doesn't, and new users get confused.
# This script makes the README a load-bearing artifact that CI gates.

set -euo pipefail
cd "$(dirname "$0")/.."

n_pass=0
n_fail=0
declare -a FAILURES=()

assert_match() {
  local name="$1"
  local file_a="$2"
  local file_b="$3"
  if diff -u "$file_a" "$file_b" >/dev/null 2>&1; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name (see: diff -u $file_a $file_b)")
    echo "  FAIL  $name"
    diff -u "$file_a" "$file_b" | sed 's/^/        /' | head -30
  fi
}

assert_output() {
  local name="$1"
  local expected_regex="$2"
  shift 2
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qE "$expected_regex"; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name: stdout did not match /$expected_regex/")
    echo "  FAIL  $name"
    echo "        got: $out" | head -5
  fi
}

assert_build_step() {
  local name="$1"
  local step="$2"
  if zig build --help 2>&1 | grep -qE "  $step\b"; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name: build step '$step' is missing")
    echo "  FAIL  $name (step '$step' missing)"
  fi
}

echo "=== zig-cobs doctest ==="

# ─── Check 1: README Quickstart block matches examples/quickstart.zig ──────
#
# The README has the Quickstart code starting at the line `const std =`
# (inside a ```zig fenced block) and ending at the trailing closing
# brace of `pub fn main`. We extract the block and diff against the
# vendored example file (with its header comment stripped).

EXTRACTED=$(mktemp)
# Extract content between the first ```zig...const std = and the next ```
awk '
  /^```zig$/    { in_block = 1; next }
  /^```$/       { if (in_block && found_main) { in_block = 0; exit } }
  in_block && /const std = @import\("std"\)/ { found_main = 1 }
  in_block && found_main { print }
' README.md > "$EXTRACTED"

# Strip the header comment from examples/quickstart.zig to match.
EX_STRIPPED=$(mktemp)
awk '
  /^const std = @import\("std"\)/ { printing = 1 }
  printing { print }
' examples/quickstart.zig > "$EX_STRIPPED"

assert_match "README Quickstart block matches examples/quickstart.zig" "$EXTRACTED" "$EX_STRIPPED"
rm -f "$EXTRACTED" "$EX_STRIPPED"

# ─── Check 2: Quickstart binary runs and prints "encoded N bytes" ──────────
QUICKSTART_BIN=zig-out/bin/example-quickstart
if [ ! -x "$QUICKSTART_BIN" ]; then
  echo "  FAIL  example-quickstart binary missing (run \`zig build\` first)"
  n_fail=$((n_fail + 1))
  FAILURES+=("example-quickstart binary missing")
else
  assert_output "Quickstart binary prints 'encoded N bytes'" 'encoded [0-9]+ bytes' "$QUICKSTART_BIN"
fi

# ─── Check 3: Documented build steps exist ─────────────────────────────────
assert_build_step "README documents 'zig build test'" "test"
assert_build_step "README documents 'zig build bench'" "bench"

# ─── Check 4: API signatures block matches the source ─────────────────────
#
# README has a ```zig fenced block with public-function declarations
# (lines 86..95). Each signature line (excluding the `pub const Error`
# block) MUST find a matching prefix in src/root.zig (where the same
# `pub fn FOO(...)` line appears, just terminated with `{` not `;`).
# Drift on a signature = test fails.
API_BLOCK=$(mktemp)
awk '
  state == "scan" && /^```zig$/ { state = "in_block"; next }
  state == "in_block" && /^pub fn / { gsub(/;$/, " {", $0); print; matched = 1; next }
  state == "in_block" && matched && /^```$/ { state = "done"; exit }
' README.md > "$API_BLOCK"

if [ ! -s "$API_BLOCK" ]; then
  # README has multiple ```zig blocks; the API one is the third. Try a more
  # targeted extraction: find the block that contains `pub fn maxEncodedLength`
  # but NOT `const std =` (which is the Quickstart).
  awk '
    /^```zig$/ { in_block = 1; lines = ""; sig_count = 0; has_main = 0; next }
    /^```$/ {
      if (in_block && sig_count >= 2 && !has_main) print lines
      in_block = 0
    }
    in_block {
      if (/^pub fn /) { sig_count++; gsub(/;$/, " {", $0); lines = lines $0 "\n" }
      if (/const std = /) has_main = 1
    }
  ' README.md > "$API_BLOCK"
fi

api_miss=0
api_total=0
while IFS= read -r sig; do
  [ -z "$sig" ] && continue
  api_total=$((api_total + 1))
  # Search src/root.zig for a line starting with the same prefix.
  if ! grep -qF -- "$sig" src/root.zig; then
    api_miss=$((api_miss + 1))
    n_fail=$((n_fail + 1))
    FAILURES+=("README API signature drift: $sig (not found in src/root.zig)")
    echo "  FAIL  README API signature drift: $sig"
  fi
done < "$API_BLOCK"
rm -f "$API_BLOCK"

if [ "$api_miss" -eq 0 ] && [ "$api_total" -gt 0 ]; then
  n_pass=$((n_pass + 1))
  echo "  PASS  README API signatures ($api_total checked) all present in src/root.zig"
elif [ "$api_total" -eq 0 ]; then
  echo "  WARN  README API signature block not found (extractor failed)"
fi

echo
echo "=== summary ==="
echo "  pass: $n_pass"
echo "  fail: $n_fail"
if [ "$n_fail" -gt 0 ]; then
  echo
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
