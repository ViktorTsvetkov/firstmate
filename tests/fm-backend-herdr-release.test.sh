#!/usr/bin/env bash
# tests/fm-backend-herdr-release.test.sh - targeted coverage for native-Windows
# herdr session release after the last firstmate-owned pane closes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-release-tests)

make_fakebin() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
if [ "${1:-}" = workspace ] && [ "${2:-}" = list ]; then
  count=${FM_HERDR_WORKSPACE_COUNT:-0}
  jq -n --argjson n "$count" '{result:{workspaces:[range(0; $n) | {workspace_id:("w" + tostring)}]}}'
fi
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/powershell.exe" <<'SH'
#!/usr/bin/env bash
set -u
printf 'powershell session=%s\n' "${FM_HERDR_RELEASE_SESSION:-}" >> "${FM_POWERSHELL_LOG:?}"
exit 0
SH
  chmod +x "$fb/powershell.exe"
  printf '%s\n' "$fb"
}

test_windows_release_empty_session_stops_deletes_and_reaps() {
  local dir log pslog fb
  dir="$TMP_ROOT/windows-empty"; mkdir -p "$dir"; log="$dir/herdr.log"; pslog="$dir/powershell.log"; : > "$log"; : > "$pslog"
  fb=$(make_fakebin "$dir")
  PATH="$fb:$PATH" FM_PLATFORM_IS_WINDOWS=yes HERDR_SESSION=fmself FM_HERDR_LOG="$log" FM_HERDR_WORKSPACE_COUNT=0 FM_POWERSHELL_LOG="$pslog" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_release_session_if_empty fmtest' "$ROOT"
  expect_code 0 $? "Windows empty-session release should succeed"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''list'$'\x1f''--session'$'\x1f''fmtest' \
    "release did not inspect the scoped workspace list"
  assert_contains "$(cat "$log")" $'\x1f''session'$'\x1f''stop'$'\x1f''fmtest'$'\x1f''--session'$'\x1f''fmtest' \
    "release did not stop the exact named session"
  assert_contains "$(cat "$log")" $'\x1f''session'$'\x1f''delete'$'\x1f''fmtest'$'\x1f''--session'$'\x1f''fmtest' \
    "release did not delete the exact named session"
  assert_contains "$(cat "$pslog")" 'powershell session=fmtest' \
    "release did not pass the exact session to the Windows stubborn-process cleanup"
  pass "herdr release: Windows empty session is stopped, deleted, and exact-session server cleanup is invoked"
}

test_windows_release_self_session_returns_before_empty_check() {
  local dir log pslog fb
  dir="$TMP_ROOT/windows-self"; mkdir -p "$dir"; log="$dir/herdr.log"; pslog="$dir/powershell.log"; : > "$log"; : > "$pslog"
  fb=$(make_fakebin "$dir")
  PATH="$fb:$PATH" FM_PLATFORM_IS_WINDOWS=yes HERDR_SESSION=fmself FM_HERDR_LOG="$log" FM_HERDR_WORKSPACE_COUNT=0 FM_POWERSHELL_LOG="$pslog" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_release_session_if_empty fmself' "$ROOT"
  expect_code 0 $? "Windows self-session release should succeed as a no-op"
  [ ! -s "$log" ] || fail "self-session release must not inspect, stop, or delete the ambient firstmate session: $(cat "$log")"
  [ ! -s "$pslog" ] || fail "self-session release must not run stubborn-process cleanup: $(cat "$pslog")"
  pass "herdr release: Windows self-session target returns before empty-session cleanup"
}

test_windows_kill_self_session_is_guarded() {
  local dir log pslog fb
  dir="$TMP_ROOT/windows-self-kill"; mkdir -p "$dir"; log="$dir/herdr.log"; pslog="$dir/powershell.log"; : > "$log"; : > "$pslog"
  fb=$(make_fakebin "$dir")
  PATH="$fb:$PATH" FM_PLATFORM_IS_WINDOWS=yes HERDR_SESSION=fmself FM_HERDR_LOG="$log" FM_POWERSHELL_LOG="$pslog" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_windows_kill_server_processes fmself' "$ROOT"
  expect_code 0 $? "Windows self-session server-process cleanup should succeed as a no-op"
  [ ! -s "$pslog" ] || fail "self-session process cleanup must not call powershell: $(cat "$pslog")"
  pass "herdr release: Windows self-session process cleanup is guarded"
}

test_windows_release_nonempty_session_leaves_server_running() {
  local dir log pslog fb
  dir="$TMP_ROOT/windows-nonempty"; mkdir -p "$dir"; log="$dir/herdr.log"; pslog="$dir/powershell.log"; : > "$log"; : > "$pslog"
  fb=$(make_fakebin "$dir")
  PATH="$fb:$PATH" FM_PLATFORM_IS_WINDOWS=yes HERDR_SESSION=fmself FM_HERDR_LOG="$log" FM_HERDR_WORKSPACE_COUNT=2 FM_POWERSHELL_LOG="$pslog" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_release_session_if_empty fmtest' "$ROOT"
  expect_code 0 $? "Windows non-empty release should succeed as a no-op"
  assert_not_contains "$(cat "$log")" $'\x1f''session'$'\x1f''stop' \
    "release must not stop a session that still has workspaces"
  [ ! -s "$pslog" ] || fail "release must not run stubborn-process cleanup while workspaces remain: $(cat "$pslog")"
  pass "herdr release: Windows non-empty session is left running"
}

test_posix_release_is_byte_preserving_noop() {
  local dir log pslog fb
  dir="$TMP_ROOT/posix"; mkdir -p "$dir"; log="$dir/herdr.log"; pslog="$dir/powershell.log"; : > "$log"; : > "$pslog"
  fb=$(make_fakebin "$dir")
  PATH="$fb:$PATH" FM_PLATFORM_IS_WINDOWS=no FM_HERDR_LOG="$log" FM_HERDR_WORKSPACE_COUNT=0 FM_POWERSHELL_LOG="$pslog" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_release_session_if_empty fmtest' "$ROOT"
  expect_code 0 $? "POSIX release should succeed as a no-op"
  [ ! -s "$log" ] || fail "POSIX release must not call herdr at all: $(cat "$log")"
  [ ! -s "$pslog" ] || fail "POSIX release must not call powershell: $(cat "$pslog")"
  pass "herdr release: POSIX path is a no-op"
}

test_windows_release_empty_session_stops_deletes_and_reaps
test_windows_release_self_session_returns_before_empty_check
test_windows_kill_self_session_is_guarded
test_windows_release_nonempty_session_leaves_server_running
test_posix_release_is_byte_preserving_noop
