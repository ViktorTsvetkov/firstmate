#!/usr/bin/env bash
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock)
LOCK="$ROOT/bin/fm-lock.sh"

make_fake_ps_herdr_pgid() {
  local fakebin=$1 pgid=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *" -o "*) exit 1 ;;
  *"-p $pgid"*)
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\\n'
    printf '     $pgid       1    $pgid      11111  cons0     197608 12:00:00 /usr/bin/bash\\n'
    ;;
  *"-p "*)
    pid=\${*: -1}
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\\n'
    printf '%9s       1    $pgid      22222  cons0     197608 12:00:01 /usr/bin/bash\\n' "\$pid"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

make_fake_ps_posix_ancestry() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/claude'; exit 0 ;;
  *"args="*) printf '%s\n' 'claude'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

make_fake_ps_generic_harness() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/claude'; exit 0 ;;
  *"args="*) printf '%s\n' 'claude'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

make_fake_herdr_agent() {
  local fakebin=$1 log=$2 agent=${3:-claude}
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$log"
case "\$*" in
  "agent get w1:p2 --session fm-lock-test")
    printf '{"id":"cli:agent:get","result":{"agent":{"name":"$agent","pane_id":"w1:p2"},"type":"agent_info"}}\\n'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

test_windows_herdr_fallback_uses_session_pgid_harness() {
  local dir fakebin home out pgid log status
  dir="$TMP_ROOT/windows-herdr"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home"
  sleep 60 &
  pgid=$!
  trap 'kill "$pgid" 2>/dev/null || true' EXIT
  make_fake_ps_herdr_pgid "$fakebin" "$pgid"
  make_fake_herdr_agent "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes HERDR_ENV=1 HERDR_SESSION=fm-lock-test HERDR_PANE_ID=w1:p2 "$LOCK")

  [ "$out" = "lock acquired: harness pid $pgid" ] || fail "Windows herdr fallback did not lock on pgid harness: $out"
  [ "$(cat "$home/state/.lock")" = "$pgid" ] || fail "lock file did not record the session-stable harness pgid"
  grep -F "pid=$pgid" "$home/state/.lock.herdr" >/dev/null || fail "herdr lock sidecar did not record the pid"
  grep -F "pane=w1:p2" "$home/state/.lock.herdr" >/dev/null || fail "herdr lock sidecar did not record the pane"
  status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$status" = "lock: held by live harness pid $pgid" ] || fail "status did not verify the live herdr sidecar lock: $status"
  grep -F "agent get w1:p2 --session fm-lock-test" "$log" >/dev/null || fail "fallback did not verify the current herdr agent"
  kill "$pgid" 2>/dev/null || true
  trap - EXIT
  pass "fm-lock Windows herdr fallback records the live harness process-group leader"
}

test_windows_herdr_sidecar_overrides_generic_harness_liveness() {
  local dir fakebin home live_pid log stale_status live_status
  dir="$TMP_ROOT/windows-herdr-sidecar"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home/state"
  sleep 60 &
  live_pid=$!
  trap 'kill "$live_pid" 2>/dev/null || true' EXIT
  make_fake_ps_generic_harness "$fakebin"
  printf '%s\n' "$live_pid" > "$home/state/.lock"
  {
    printf 'pid=%s\n' "$live_pid"
    printf 'session=fm-lock-test\n'
    printf 'pane=w1:p2\n'
    printf 'agent=claude\n'
  } > "$home/state/.lock.herdr"

  make_fake_herdr_agent "$fakebin" "$log" codex
  stale_status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$stale_status" = "lock: stale (pid $live_pid dead or not a harness)" ] || fail "stale herdr sidecar lock should not fall back to generic harness liveness: $stale_status"

  make_fake_herdr_agent "$fakebin" "$log" claude
  live_status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$live_status" = "lock: held by live harness pid $live_pid" ] || fail "matching herdr sidecar lock should remain live: $live_status"
  kill "$live_pid" 2>/dev/null || true
  trap - EXIT
  pass "fm-lock Windows herdr sidecar verdict overrides generic harness liveness"
}

test_posix_uses_ancestry_without_herdr_fallback() {
  local dir fakebin home out log
  dir="$TMP_ROOT/posix-ancestry"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home"
  make_fake_ps_posix_ancestry "$fakebin"
  make_fake_herdr_agent "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=no HERDR_ENV=1 HERDR_SESSION=fm-lock-test HERDR_PANE_ID=w1:p2 "$LOCK")

  case "$out" in
    "lock acquired: harness pid "*) ;;
    *) fail "POSIX ancestry path did not acquire through the original walk: $out" ;;
  esac
  [ ! -e "$log" ] || fail "POSIX path should not call herdr fallback"
  pass "fm-lock POSIX path still uses ancestry and does not consult herdr"
}

test_windows_herdr_fallback_uses_session_pgid_harness
test_windows_herdr_sidecar_overrides_generic_harness_liveness
test_posix_uses_ancestry_without_herdr_fallback
