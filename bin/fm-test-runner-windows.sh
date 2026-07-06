#!/usr/bin/env bash
# Windows-only behavior-suite runner for native Git Bash.
#
# Linux/macOS must keep using the historical sequential loop from
# .no-mistakes.yaml. This runner is selected only from the native-Windows batch
# leg after fm_platform_is_windows confirms the substrate.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-platform-lib.sh"

fm_platform_is_windows || {
  echo "fm-test-runner-windows: Windows only" >&2
  exit 2
}

jobs=${FM_TEST_JOBS:-}
if [ -z "$jobs" ]; then
  if command -v nproc >/dev/null 2>&1; then
    jobs=$(nproc)
  else
    jobs=4
  fi
fi
case "$jobs" in
  ''|*[!0-9]*|0) jobs=4 ;;
esac

is_serial_test() {
  case "$1" in
    tests/fm-watcher-lock.test.sh|\
    tests/fm-backend-cmux-smoke.test.sh|\
    tests/fm-afk-inject-e2e.test.sh|\
    tests/fm-wake-daemon-lifecycle-e2e.test.sh|\
    tests/fm-backend-tmux-smoke.test.sh|\
    tests/fm-backend-zellij-smoke.test.sh|\
    tests/fm-afk-inject-herdr-e2e.test.sh|\
    tests/fm-backend-autodetect-smoke.test.sh|\
    tests/fm-backend-herdr-prune-safety-e2e.test.sh|\
    tests/fm-backend-herdr-respawn-idem-e2e.test.sh|\
    tests/fm-backend-herdr-smoke.test.sh|\
    tests/fm-backend-herdr-workspace-per-home-e2e.test.sh)
      return 0
      ;;
  esac
  return 1
}

test_key() {
  local key
  key=${1##*/}
  key=${key//[^A-Za-z0-9_.-]/_}
  printf '%s\n' "$key"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

parallel_list="$tmp/parallel.txt"
: > "$parallel_list"

for test_script in tests/*.test.sh; do
  [ -e "$test_script" ] || continue
  if ! is_serial_test "$test_script"; then
    printf '%s\n' "$test_script" >> "$parallel_list"
  fi
done

if [ -s "$parallel_list" ]; then
  # shellcheck disable=SC2016 # $1/$2 expand inside the child bash process.
  xargs -r -n1 -P "$jobs" bash -c '
    tmp=$1
    test_script=$2
    key=${test_script##*/}
    key=${key//[^A-Za-z0-9_.-]/_}
    bash "$test_script" >"$tmp/$key.out" 2>"$tmp/$key.err"
    printf "%s\n" "$?" >"$tmp/$key.rc"
  ' _ "$tmp" < "$parallel_list"
fi

rc=0
for test_script in tests/*.test.sh; do
  [ -e "$test_script" ] || continue
  echo "== $test_script =="
  key=$(test_key "$test_script")
  if is_serial_test "$test_script"; then
    bash "$test_script" || rc=1
    continue
  fi

  if [ -f "$tmp/$key.out" ]; then
    cat "$tmp/$key.out"
  else
    rc=1
  fi
  if [ -f "$tmp/$key.err" ]; then
    cat "$tmp/$key.err" >&2
  else
    rc=1
  fi
  if [ -f "$tmp/$key.rc" ]; then
    test_rc=$(cat "$tmp/$key.rc")
    [ "$test_rc" = 0 ] || rc=1
  else
    rc=1
  fi
done

exit "$rc"
