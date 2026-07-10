#!/usr/bin/env bash
# Regression guard for native-Windows MSYS path conversion in herdr sends.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-msys-pathconv)

make_fake_herdr() {  # <dir>
  local dir=$1 fb
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\x1fMSYS_NO_PATHCONV=%s\x1fMSYS2_ARG_CONV_EXCL=%s' "${MSYS_NO_PATHCONV:-}" "${MSYS2_ARG_CONV_EXCL:-}"
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

run_herdr_call() {  # <platform-yes-no> <call-script> <log>
  local platform=$1 call=$2 log=$3 dir fb
  dir="$TMP_ROOT/case-$RANDOM"
  mkdir -p "$dir"
  fb=$(make_fake_herdr "$dir")
  : > "$log"
  PATH="$fb:$PATH" FM_PLATFORM_IS_WINDOWS="$platform" FM_HERDR_LOG="$log" \
    bash -c '. "$0/bin/backends/herdr.sh"; '"$call" "$ROOT"
}

test_windows_send_literal_disables_msys_path_conversion() {
  local log send_line
  log="$TMP_ROOT/windows-send-text.log"
  run_herdr_call yes 'fm_backend_herdr_send_literal default:w1:p2 "/no-mistakes"' "$log"
  expect_code 0 $? "Windows send_literal should succeed"
  send_line=$(grep $'\x1f''pane'$'\x1f''send-text'$'\x1f''w1:p2' "$log")
  assert_contains "$send_line" $'\x1f''/no-mistakes' "send-text should receive the literal leading-slash payload"
  assert_contains "$send_line" $'\x1f''MSYS_NO_PATHCONV=1'$'\x1f''MSYS2_ARG_CONV_EXCL=*' \
    "Windows send-text must disable MSYS argument conversion"
  pass "herdr Windows send-text disables MSYS path conversion for leading-slash payloads"
}

test_posix_send_literal_leaves_msys_path_conversion_env_unset() {
  local log send_line
  log="$TMP_ROOT/posix-send-text.log"
  run_herdr_call no 'fm_backend_herdr_send_literal default:w1:p2 "/no-mistakes"' "$log"
  expect_code 0 $? "POSIX send_literal should succeed"
  send_line=$(grep $'\x1f''pane'$'\x1f''send-text'$'\x1f''w1:p2' "$log")
  assert_contains "$send_line" $'\x1f''/no-mistakes' "POSIX send-text should receive the same literal payload"
  assert_contains "$send_line" $'\x1f''MSYS_NO_PATHCONV='$'\x1f''MSYS2_ARG_CONV_EXCL=' \
    "POSIX send-text must leave MSYS argument-conversion env unset"
  pass "herdr POSIX send-text leaves the MSYS path-conversion env unset"
}

test_windows_send_key_disables_msys_path_conversion() {
  local log key_line
  log="$TMP_ROOT/windows-send-key.log"
  run_herdr_call yes 'fm_backend_herdr_send_key default:w1:p2 Enter' "$log"
  expect_code 0 $? "Windows send_key should succeed"
  key_line=$(grep $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2' "$log")
  assert_contains "$key_line" $'\x1f''MSYS_NO_PATHCONV=1'$'\x1f''MSYS2_ARG_CONV_EXCL=*' \
    "Windows send-keys must disable MSYS argument conversion"
  pass "herdr Windows send-keys disables MSYS path conversion"
}

test_windows_send_literal_disables_msys_path_conversion
test_posix_send_literal_leaves_msys_path_conversion_env_unset
test_windows_send_key_disables_msys_path_conversion
