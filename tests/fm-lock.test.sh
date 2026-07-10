#!/usr/bin/env bash
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock)
LOCK="$ROOT/bin/fm-lock.sh"

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

make_fake_ps_live_non_harness_pid() {
  local fakebin=$1 live_pid=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  "-o comm= -p $live_pid") printf '%s\n' '/usr/bin/bash'; exit 0 ;;
  "-o args= -p $live_pid") printf '%s\n' 'bash'; exit 0 ;;
  *) exec /usr/bin/ps "\$@" ;;
esac
SH
  chmod +x "$fakebin/ps"
}

make_fake_herdr_agent() {
  local fakebin=$1 log=$2 name=${3:-claude} terminal=${4:-term-1} pane=${5:-w1:p2} status=${6:-unknown}
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  "pane get $pane --session fm-lock-test")
    printf '%s\n' '{"id":"cli:pane:get","result":{"pane":{"agent_status":"$status","cwd":"C:\\\\work","focused":false,"label":"$name","pane_id":"$pane","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":23},"tab_id":"w1:t1","terminal_id":"$terminal","workspace_id":"w1"},"type":"pane_info"}}'
    ;;
  "agent get $pane --session fm-lock-test")
    printf '%s\n' '{"id":"cli:agent:get","result":{"agent":{"agent_status":"$status","cwd":"C:\\\\work","focused":false,"name":"$name","pane_id":"$pane","revision":0,"tab_id":"w1:t1","terminal_id":"$terminal","workspace_id":"w1"},"type":"agent_info"}}'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

make_fake_herdr_multi_agent() {
  local fakebin=$1 log=$2
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  "pane get w1:p2 --session fm-lock-test")
    printf '%s\n' '{"result":{"pane":{"agent_status":"unknown","cwd":"C:\\\\work","focused":false,"label":"claude","pane_id":"w1:p2","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":23},"tab_id":"w1:t1","terminal_id":"term-1","workspace_id":"w1"}}}'
    ;;
  "agent get w1:p2 --session fm-lock-test")
    printf '%s\n' '{"result":{"agent":{"agent_status":"unknown","cwd":"C:\\\\work","focused":false,"name":"claude","pane_id":"w1:p2","revision":0,"tab_id":"w1:t1","terminal_id":"term-1","workspace_id":"w1"}}}'
    ;;
  "pane get w1:p3 --session fm-lock-test")
    printf '%s\n' '{"result":{"pane":{"agent_status":"unknown","cwd":"C:\\\\work","focused":false,"label":"codex","pane_id":"w1:p3","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":23},"tab_id":"w1:t1","terminal_id":"term-3","workspace_id":"w1"}}}'
    ;;
  "agent get w1:p3 --session fm-lock-test")
    printf '%s\n' '{"result":{"agent":{"agent_status":"unknown","cwd":"C:\\\\work","focused":false,"name":"codex","pane_id":"w1:p3","revision":0,"tab_id":"w1:t1","terminal_id":"term-3","workspace_id":"w1"}}}'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
}
test_herdr_agent_identity_parser_prefers_detected_agent() {
  local lock_script out
  lock_script=$LOCK
  # shellcheck disable=SC1090
  FM_LOCK_LIB_ONLY=1 . "$LOCK"
  LOCK=$lock_script

  out=$(printf '%s\n' '{"name":"fm-abc","agent":"claude"}' | herdr_agent_identity_from_json)
  [ "$out" = claude ] || fail "parser should prefer detected agent over custom name, got '$out'"

  out=$(printf '%s\n' '{"name":"claude","agent":"claude"}' | herdr_agent_identity_from_json)
  [ "$out" = claude ] || fail "parser should keep matching detected claude, got '$out'"

  out=$(printf '%s\n' '{"agent":"codex"}' | herdr_agent_identity_from_json)
  [ "$out" = codex ] || fail "parser should accept agent without name, got '$out'"

  out=$(printf '%s\n' '{"name":"claude"}' | herdr_agent_identity_from_json)
  [ "$out" = claude ] || fail "parser should fall back to legacy name, got '$out'"

  out=$(printf '%s\n' '{"name":"fm-x","agent":"bash"}' | herdr_agent_identity_from_json)
  [ "$out" = bash ] || fail "parser should expose non-harness detected agents for rejection, got '$out'"
  if printf '%s' "$out" | grep -qE "$HARNESS_RE"; then
    fail "non-harness detected agent should not match HARNESS_RE"
  fi

  pass "fm-lock herdr agent parser prefers detected agent and falls back to name"
}

test_windows_herdr_fallback_uses_pane_agent_identity() {
  local dir fakebin home out log status owner
  dir="$TMP_ROOT/windows-herdr"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home"
  make_fake_herdr_agent "$fakebin" "$log" claude
  owner="herdr:fm-lock-test:w1:p2:term-1"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes HERDR_ENV=1 HERDR_SESSION=fm-lock-test HERDR_PANE_ID=w1:p2 "$LOCK")

  [ "$out" = "lock acquired: herdr agent $owner" ] || fail "Windows herdr fallback did not lock on pane-agent identity: $out"
  [ "$(cat "$home/state/.lock")" = "$owner" ] || fail "lock file did not record the herdr pane-agent owner"
  [ ! -e "$home/state/.lock.herdr" ] || fail "herdr lock sidecar should not be written"
  status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$status" = "lock: held by live herdr agent $owner" ] || fail "status did not verify the live herdr identity lock: $status"
  grep -F "pane get w1:p2 --session fm-lock-test" "$log" >/dev/null || fail "fallback did not verify the current herdr pane"
  grep -F "agent get w1:p2 --session fm-lock-test" "$log" >/dev/null || fail "fallback did not verify the current herdr agent"
  pass "fm-lock Windows herdr fallback records only the live pane-agent owner"
}

test_windows_herdr_env_without_pane_falls_back_to_ancestry() {
  local dir fakebin home out
  dir="$TMP_ROOT/windows-herdr-env-no-pane"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home"
  make_fake_ps_posix_ancestry "$fakebin"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes HERDR_ENV=1 HERDR_SESSION=fm-lock-test "$LOCK")

  case "$out" in
    "lock acquired: harness pid "*) ;;
    *) fail "HERDR_ENV without HERDR_PANE_ID should fall back to ancestry: $out" ;;
  esac
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "ancestry fallback did not record a numeric harness pid" ;;
  esac
  pass "fm-lock Windows HERDR_ENV without a pane falls back to ancestry"
}

test_windows_herdr_acquire_removes_legacy_sidecar() {
  local dir fakebin home out log owner
  dir="$TMP_ROOT/windows-herdr-sidecar-cleanup"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home/state"
  make_fake_herdr_agent "$fakebin" "$log" claude
  owner="herdr:fm-lock-test:w1:p2:term-1"
  {
    printf 'pid=12345\n'
    printf 'session=fm-lock-test\n'
    printf 'pane=w1:p1\n'
    printf 'agent=claude\n'
  } > "$home/state/.lock.herdr"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes HERDR_ENV=1 HERDR_SESSION=fm-lock-test HERDR_PANE_ID=w1:p2 "$LOCK")

  [ "$out" = "lock acquired: herdr agent $owner" ] || fail "Windows herdr acquire failed: $out"
  [ "$(cat "$home/state/.lock")" = "$owner" ] || fail "lock file did not record the new herdr owner"
  [ ! -e "$home/state/.lock.herdr" ] || fail "new herdr acquire should remove the legacy sidecar"
  pass "fm-lock Windows herdr acquire removes obsolete legacy sidecars"
}

test_windows_herdr_identity_overrides_generic_harness_liveness() {
  local dir fakebin home log stale_status gone_status live_status owner
  dir="$TMP_ROOT/windows-herdr-single-file"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home/state"
  owner="herdr:fm-lock-test:w1:p2:term-1"
  printf '%s\n' "$owner" > "$home/state/.lock"

  make_fake_herdr_agent "$fakebin" "$log" claude term-2
  stale_status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$stale_status" = "lock: stale (herdr agent $owner gone or changed)" ] || fail "changed herdr terminal id should be stale: $stale_status"

  make_fake_herdr_agent "$fakebin" "$log" claude term-1 w1:p2 gone
  gone_status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$gone_status" = "lock: stale (herdr agent $owner gone or changed)" ] || fail "gone herdr pane should be stale: $gone_status"

  make_fake_herdr_agent "$fakebin" "$log" claude
  live_status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$live_status" = "lock: held by live herdr agent $owner" ] || fail "matching herdr identity lock should remain live: $live_status"
  pass "fm-lock Windows herdr identity liveness is re-derived from the single lock file"
}

test_windows_herdr_refuses_different_live_pane_agent_holder() {
  local dir fakebin home log old_owner out rc
  dir="$TMP_ROOT/windows-herdr-different-holder"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home/state"
  old_owner="herdr:fm-lock-test:w1:p2:term-1"
  printf '%s\n' "$old_owner" > "$home/state/.lock"
  make_fake_herdr_multi_agent "$fakebin" "$log"

  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes HERDR_ENV=1 HERDR_SESSION=fm-lock-test HERDR_PANE_ID=w1:p3 "$LOCK" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "different live herdr holder should refuse acquire"
  case "$out" in
    *"another live firstmate session holds the lock ($old_owner)"*) ;;
    *) fail "different live herdr holder refusal did not name the old owner: $out" ;;
  esac
  [ "$(cat "$home/state/.lock")" = "$old_owner" ] || fail "different live holder acquire clobbered the existing lock"
  pass "fm-lock Windows herdr refuses a genuinely different live pane-agent holder"
}

test_windows_herdr_respects_live_legacy_pid_lock() {
  local dir fakebin home log legacy_pid out rc
  dir="$TMP_ROOT/windows-herdr-legacy-pid"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home/state"

  sleep 30 &
  legacy_pid=$!
  trap 'kill "$legacy_pid" 2>/dev/null || true' RETURN
  printf '%s\n' "$legacy_pid" > "$home/state/.lock"
  {
    printf 'pid=%s\n' "$legacy_pid"
    printf 'session=fm-lock-test\n'
    printf 'pane=w1:p2\n'
    printf 'agent=claude\n'
  } > "$home/state/.lock.herdr"
  make_fake_ps_live_non_harness_pid "$fakebin" "$legacy_pid"
  make_fake_herdr_multi_agent "$fakebin" "$log"

  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes HERDR_ENV=1 HERDR_SESSION=fm-lock-test HERDR_PANE_ID=w1:p3 "$LOCK" 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "live legacy herdr pid lock should refuse acquire"
  case "$out" in
    *"another live firstmate session holds the lock (pid $legacy_pid)"*) ;;
    *) fail "legacy pid holder refusal did not name the old pid: $out" ;;
  esac
  [ "$(cat "$home/state/.lock")" = "$legacy_pid" ] || fail "legacy pid acquire clobbered the existing lock"
  kill "$legacy_pid" 2>/dev/null || true
  trap - RETURN
  pass "fm-lock Windows herdr respects live legacy pid sidecar locks"
}

test_windows_herdr_stales_dead_legacy_pid_sidecar() {
  local dir fakebin home log legacy_pid stale_status changed_status
  dir="$TMP_ROOT/windows-herdr-legacy-pid-stale"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  log="$dir/herdr.log"
  mkdir -p "$home/state"

  sleep 30 &
  legacy_pid=$!
  trap 'kill "$legacy_pid" 2>/dev/null || true' RETURN
  printf '%s\n' "$legacy_pid" > "$home/state/.lock"
  {
    printf 'pid=%s\n' "$legacy_pid"
    printf 'session=fm-lock-test\n'
    printf 'pane=w1:p2\n'
    printf 'agent=claude\n'
  } > "$home/state/.lock.herdr"
  make_fake_ps_live_non_harness_pid "$fakebin" "$legacy_pid"

  make_fake_herdr_agent "$fakebin" "$log" claude term-1 w1:p2 gone
  stale_status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$stale_status" = "lock: stale (pid $legacy_pid dead or not a harness)" ] || fail "gone legacy herdr pane should be stale: $stale_status"

  make_fake_herdr_agent "$fakebin" "$log" codex term-1 w1:p2 unknown
  changed_status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$changed_status" = "lock: stale (pid $legacy_pid dead or not a harness)" ] || fail "changed legacy herdr agent should be stale: $changed_status"
  kill "$legacy_pid" 2>/dev/null || true
  trap - RETURN
  pass "fm-lock Windows herdr stales dead or changed legacy pid sidecar locks"
}

test_windows_non_harness_numeric_without_sidecar_is_stale() {
  local dir fakebin home legacy_pid stale_status
  dir="$TMP_ROOT/windows-non-harness-no-sidecar"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"

  sleep 30 &
  legacy_pid=$!
  trap 'kill "$legacy_pid" 2>/dev/null || true' RETURN
  printf '%s\n' "$legacy_pid" > "$home/state/.lock"
  make_fake_ps_live_non_harness_pid "$fakebin" "$legacy_pid"

  stale_status=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_PLATFORM_IS_WINDOWS=yes "$LOCK" status)
  [ "$stale_status" = "lock: stale (pid $legacy_pid dead or not a harness)" ] || fail "non-harness numeric lock without sidecar should be stale: $stale_status"
  kill "$legacy_pid" 2>/dev/null || true
  trap - RETURN
  pass "fm-lock Windows non-harness numeric locks without sidecars stay stale"
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

test_herdr_agent_identity_parser_prefers_detected_agent
test_windows_herdr_fallback_uses_pane_agent_identity
test_windows_herdr_env_without_pane_falls_back_to_ancestry
test_windows_herdr_acquire_removes_legacy_sidecar
test_windows_herdr_identity_overrides_generic_harness_liveness
test_windows_herdr_refuses_different_live_pane_agent_holder
test_windows_herdr_respects_live_legacy_pid_lock
test_windows_herdr_stales_dead_legacy_pid_sidecar
test_windows_non_harness_numeric_without_sidecar_is_stale
test_posix_uses_ancestry_without_herdr_fallback
