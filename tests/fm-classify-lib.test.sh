#!/usr/bin/env bash
# Focused tests for the pure shared status classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-lib)

test_last_status_line_strips_leading_utf8_bom() {
  local d line
  d="$TMP_ROOT/bom-done"
  mkdir -p "$d"
  printf '\357\273\277done: something\n' > "$d/task.status"
  line=$(last_status_line "$d/task.status")
  [ "$line" = "done: something" ] || fail "leading UTF-8 BOM was not stripped from the last status line"
  status_is_captain_relevant "$line" || fail "BOM-prefixed done: did not classify as captain-relevant after normalization"
  pass "last_status_line strips a genuine leading UTF-8 BOM"
}

test_last_status_line_ignores_bom_on_non_last_line() {
  local d line
  d="$TMP_ROOT/bom-working-then-done"
  mkdir -p "$d"
  printf '\357\273\277working: setup\n\ndone: finished\n' > "$d/task.status"
  line=$(last_status_line "$d/task.status")
  [ "$line" = "done: finished" ] || fail "last_status_line did not preserve the later terminal status"
  status_is_captain_relevant "$line" || fail "later done: line did not classify as captain-relevant"
  pass "last_status_line returns the later status when only the first line has a BOM"
}

test_forced_posix_no_bom_line_is_byte_identical() {
  local d line bytes
  d="$TMP_ROOT/posix-no-bom"
  mkdir -p "$d"
  printf 'done: normal posix status\n' > "$d/task.status"
  FM_PLATFORM_IS_WINDOWS=no
  [ "$FM_PLATFORM_IS_WINDOWS" = no ] || fail "forced-POSIX platform marker was not set"
  line=$(last_status_line "$d/task.status")
  [ "$line" = "done: normal posix status" ] || fail "forced-POSIX no-BOM status text changed"
  bytes=$(printf '%s' "$line" | od -An -tx1 | tr -d ' \n')
  [ "$bytes" = "646f6e653a206e6f726d616c20706f73697820737461747573" ] || fail "forced-POSIX no-BOM status bytes changed: $bytes"
  status_is_captain_relevant "$line" || fail "forced-POSIX no-BOM done: did not classify as captain-relevant"
  pass "forced-POSIX no-BOM line is byte-identical"
}

test_last_status_line_strips_leading_utf8_bom
test_last_status_line_ignores_bom_on_non_last_line
test_forced_posix_no_bom_line_is_byte_identical

echo "all fm-classify-lib tests passed"
