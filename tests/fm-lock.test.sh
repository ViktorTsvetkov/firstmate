#!/usr/bin/env bash
set -u

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

make_fake_herdr_agent() {
  local fakebin=$1 log=$2 name=${3:-claude} terminal=${4:-term-1} pane=${5:-w1:p2} status=${6:-unknown}
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  "pane get $pane --session fm-lock-test")
    printf '%s\n' '{"result":{"pane":{"agent_status":"$status","pane_id":"$pane","terminal_id":"$terminal"}}}'
    ;;
  "agent get $pane --session fm-lock-test")
    printf '%s\n' '{"result":{"agent":{"agent_status":"$status","name":"$name","pane_id":"$pane","terminal_id":"$terminal"}}}'
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

  out=$(printf '%s\n' '{"result":{"agent":{"name":"codex","agent":"codex"}}}' | herdr_agent_identity_from_json)
  [ "$out" = codex ] || fail "parser should read nested herdr agent identity, got '$out'"

  out=$(printf '%s\n' '{"name":"claude"}' | herdr_agent_identity_from_json)
  [ "$out" = claude ] || fail "parser should fall back to legacy name, got '$out'"

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
test_windows_herdr_identity_overrides_generic_harness_liveness
test_posix_uses_ancestry_without_herdr_fallback
