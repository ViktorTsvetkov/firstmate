#!/usr/bin/env bash
# Focused tests for the pure shared status classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-lib)

test_windows_last_status_line_strips_leading_utf8_bom() {
  local d line
  d="$TMP_ROOT/bom-done"
  mkdir -p "$d"
  printf '\357\273\277done: something\n' > "$d/task.status"
  line=$(FM_PLATFORM_IS_WINDOWS=yes; last_status_line "$d/task.status")
  [ "$line" = "done: something" ] || fail "leading UTF-8 BOM was not stripped from the last status line"
  status_is_captain_relevant "$line" || fail "BOM-prefixed done: did not classify as captain-relevant after normalization"
  pass "forced-Windows last_status_line strips a genuine leading UTF-8 BOM"
}

test_windows_last_status_line_ignores_bom_on_non_last_line() {
  local d line
  d="$TMP_ROOT/bom-working-then-done"
  mkdir -p "$d"
  printf '\357\273\277working: setup\n\ndone: finished\n' > "$d/task.status"
  line=$(FM_PLATFORM_IS_WINDOWS=yes; last_status_line "$d/task.status")
  [ "$line" = "done: finished" ] || fail "last_status_line did not preserve the later terminal status"
  status_is_captain_relevant "$line" || fail "later done: line did not classify as captain-relevant"
  pass "forced-Windows last_status_line returns the later status when only the first line has a BOM"
}

test_windows_last_status_line_decodes_utf16le_done() {
  local d line
  d="$TMP_ROOT/utf16le-done"
  mkdir -p "$d"
  printf '\377\376d\000o\000n\000e\000:\000 \000u\000t\000f\0001\0006\000l\000e\000\n\000' > "$d/task.status"
  line=$(FM_PLATFORM_IS_WINDOWS=yes; last_status_line "$d/task.status")
  [ "$line" = "done: utf16le" ] || fail "forced-Windows UTF-16LE status was not decoded, got: $line"
  status_is_captain_relevant "$line" || fail "forced-Windows UTF-16LE done: did not classify as captain-relevant"
  pass "forced-Windows last_status_line decodes UTF-16LE status lines"
}

test_windows_last_status_line_decodes_utf16be_done() {
  local d line
  d="$TMP_ROOT/utf16be-done"
  mkdir -p "$d"
  printf '\376\377\000d\000o\000n\000e\000:\000 \000u\000t\000f\0001\0006\000b\000e\000\n' > "$d/task.status"
  line=$(FM_PLATFORM_IS_WINDOWS=yes; last_status_line "$d/task.status")
  [ "$line" = "done: utf16be" ] || fail "forced-Windows UTF-16BE status was not decoded, got: $line"
  status_is_captain_relevant "$line" || fail "forced-Windows UTF-16BE done: did not classify as captain-relevant"
  pass "forced-Windows last_status_line decodes UTF-16BE status lines"
}

test_windows_utf16_status_scan_is_actionable() {
  local d out
  d="$TMP_ROOT/utf16-scan"
  mkdir -p "$d"
  printf '\377\376d\000o\000n\000e\000:\000 \000u\000t\000f\0001\0006\000 \000o\000k\000\n\000' > "$d/task.status"
  (FM_PLATFORM_IS_WINDOWS=yes; signal_reason_is_actionable "$d/task.status") \
    || fail "forced-Windows signal classifier missed UTF-16LE done status"
  out=$(FM_PLATFORM_IS_WINDOWS=yes; scan_captain_relevant_statuses "$d")
  printf '%s' "$out" | grep -F "task.status" >/dev/null \
    || fail "forced-Windows scan missed UTF-16LE done status"
  pass "forced-Windows classifier scan sees UTF-16 captain-relevant status logs"
}

test_forced_windows_utf8_status_is_unchanged() {
  local d line
  d="$TMP_ROOT/windows-utf8"
  mkdir -p "$d"
  printf 'done: utf8 ok\n' > "$d/task.status"
  line=$(FM_PLATFORM_IS_WINDOWS=yes; last_status_line "$d/task.status")
  [ "$line" = "done: utf8 ok" ] || fail "forced-Windows UTF-8 status changed, got '$line'"
  status_is_captain_relevant "$line" || fail "forced-Windows UTF-8 done: did not classify as captain-relevant"
  pass "forced-Windows UTF-8 status logs classify unchanged"
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

test_forced_posix_utf16_status_stays_plain() {
  local d line
  d="$TMP_ROOT/posix-utf16"
  mkdir -p "$d"
  printf '\377\376d\000o\000n\000e\000:\000 \000u\000t\000f\0001\0006\000l\000e\000\n\000' > "$d/task.status"
  line=$(FM_PLATFORM_IS_WINDOWS=no; last_status_line "$d/task.status")
  [ "$line" != "done: utf16le" ] || fail "forced-POSIX path decoded UTF-16 status"
  status_is_captain_relevant "$line" && fail "forced-POSIX path classified a UTF-16 status as captain-relevant"
  pass "forced-POSIX UTF-16 status remains plain unread bytes"
}

test_windows_last_status_line_strips_leading_utf8_bom
test_windows_last_status_line_ignores_bom_on_non_last_line
test_windows_last_status_line_decodes_utf16le_done
test_windows_last_status_line_decodes_utf16be_done
test_windows_utf16_status_scan_is_actionable
test_forced_windows_utf8_status_is_unchanged
test_forced_posix_no_bom_line_is_byte_identical
test_forced_posix_utf16_status_stays_plain

echo "all fm-classify-lib tests passed"
