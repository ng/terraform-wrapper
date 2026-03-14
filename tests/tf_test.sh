#!/usr/bin/env bash
# Basic tests for the tf wrapper script
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_SCRIPT="${SCRIPT_DIR}/../tf"
PASS=0
FAIL=0

assert_exit() {
  local desc="$1" expected="$2"
  shift 2
  local actual
  if "$@" >/dev/null 2>&1; then actual=0; else actual=$?; fi
  if [[ "$actual" -eq "$expected" ]]; then
    echo "  PASS: ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

assert_output_contains() {
  local desc="$1" pattern="$2"
  shift 2
  local output
  output="$("$@" 2>&1 || true)"
  if echo "$output" | grep -q "$pattern"; then
    echo "  PASS: ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${desc} (output did not contain '${pattern}')"
    echo "        got: ${output}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== tf wrapper tests ==="
echo ""

echo "--- Argument validation ---"
assert_exit "exits non-zero with no args" 1 bash "$TF_SCRIPT"
assert_output_contains "shows usage with no args" "Usage" bash "$TF_SCRIPT"

echo ""
echo "--- Syntax ---"
assert_exit "passes bash -n syntax check" 0 bash -n "$TF_SCRIPT"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
