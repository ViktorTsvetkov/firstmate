#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: healthy pid=<N> (beacon <age>s)             - a genuinely live+fresh watcher already held the lock
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started/healthy it exits zero; on FAILED it exits
# non-zero so the failure is loud and a caller can react. A healthy line means a
# live cycle already exists; do not churn extra no-op arms until that cycle fires.
# On native Windows, Git Bash can expose a shell job pid that differs from the
# watcher's recorded BASHPID, so the arm reconciles through the pid written by
# the watcher itself and never kills a live lock holder with a fresh beacon just
# because the wrapper pid differs. If the child fires before confirmation, this
# script forwards only the child's stdout; draining state/.wake-queue remains the
# job of fm-wake-drain.sh and session start.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and start a fresh one. It resolves and signals exactly that
# pid, so it can never touch another home's watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
# Native Windows defaults higher because Git Bash can surface the first beacon slowly.
DEFAULT_CONFIRM_TIMEOUT=10
if fm_platform_is_windows; then
  DEFAULT_CONFIRM_TIMEOUT=30
fi
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-$DEFAULT_CONFIRM_TIMEOUT}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

watch_output_has_already_running() {
  local out=$1
  grep -Eq '^watcher: already running( pid [0-9]+)?$' "$out" 2>/dev/null
}

wait_windows_recorded_watcher() {
  local recorded_pid=$1 rc=0 child_watcher_pid= i
  while healthy_watcher && [ "$HEALTHY_PID" = "$recorded_pid" ]; do
    child_watcher_pid=$(cat "$child_pid_file" 2>/dev/null || true)
    if [ -n "$child_watcher_pid" ] && [ "$child_watcher_pid" = "$recorded_pid" ]; then
      echo "watcher: started pid=$recorded_pid (beacon fresh)"
      wait "$child"
      rc=$?
      child_done=1
      print_watch_output "$child_out"
      rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
      exit "$rc"
    fi
    if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
      wait "$child"
      rc=$?
      child_done=1
      if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
        print_watch_output "$child_out"
        rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
        exit 0
      fi
      if [ "$rc" -eq 0 ]; then
        report_healthy
        rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
        exit 0
      fi
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  if healthy_watcher && [ "$HEALTHY_PID" = "$recorded_pid" ]; then
    if [ "$child_done" -eq 0 ]; then
      child_watcher_pid=$(cat "$child_pid_file" 2>/dev/null || true)
      if [ -n "$child_watcher_pid" ] && [ "$child_watcher_pid" = "$recorded_pid" ]; then
        echo "watcher: started pid=$recorded_pid (beacon fresh)"
        wait "$child"
        rc=$?
        child_done=1
        print_watch_output "$child_out"
        rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
        exit "$rc"
      fi
      if fm_pid_alive "$child"; then
        kill -TERM "$child" 2>/dev/null || true
        i=0
        while [ "$i" -lt 20 ] && fm_pid_alive "$child"; do
          sleep 0.1
          i=$((i + 1))
        done
        if fm_pid_alive "$child"; then
          kill -KILL "$child" 2>/dev/null || true
        fi
      fi
      wait "$child" 2>/dev/null || true
      child_done=1
    fi
    report_healthy
    rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ]; then
    wait "$child"
    rc=$?
  fi
  print_watch_output "$child_out"
  rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
  exit "$rc"
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - the singleton would no-op anyway. Report it honestly and return success.
# (--restart skips this: it just stopped this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  report_healthy
  exit 0
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_out=
child_pid_file=
child_watcher_pid() {
  [ -n "$child_pid_file" ] || return 1
  cat "$child_pid_file" 2>/dev/null || true
}

healthy_watcher_is_child() {
  local pid
  [ -n "${HEALTHY_PID:-}" ] || return 1
  [ -n "$child" ] && [ "$HEALTHY_PID" = "$child" ] && return 0
  fm_platform_is_windows || return 1
  pid=$(child_watcher_pid)
  [ -n "$pid" ] && [ "$HEALTHY_PID" = "$pid" ]
}

healthy_watcher_is_peer() {
  healthy_watcher || return 1
  healthy_watcher_is_child && return 1
  [ -n "$child_pid_file" ] || return 1
  [ -n "$(child_watcher_pid)" ] || return 1
}

terminate_child() {
  local pid
  kill -TERM "$child" 2>/dev/null || true
  if fm_platform_is_windows; then
    pid=$(child_watcher_pid)
    if [ -n "$pid" ] && [ "$pid" != "$child" ] && fm_pid_alive "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  fi
}

cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    if fm_platform_is_windows; then
      healthy_watcher_is_peer || terminate_child
    else
      terminate_child
    fi
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
  if [ -n "$child_pid_file" ]; then
    rm -f "$child_pid_file" 2>/dev/null || true
  fi
}
trap 'cleanup_child; exit 129' HUP
trap 'cleanup_child; exit 143' TERM INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
if fm_platform_is_windows; then
  child_pid_file=$(mktemp "$STATE/.watch-arm-child-pid.XXXXXX") || {
    rm -f "$child_out" 2>/dev/null || true
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    exit 1
  }
  FM_WATCH_ARM_CHILD_PID_FILE="$child_pid_file" "$WATCH" >"$child_out" &
else
  "$WATCH" >"$child_out" &
fi
child=$!
child_done=0

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "watcher: started pid=$child (beacon fresh)"
      wait "$child"
      rc=$?
      print_watch_output "$child_out"
      rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
      exit "$rc"
    fi
    if fm_platform_is_windows \
      && [ "$child_done" -eq 0 ] \
      && fm_pid_alive "$child" \
      && ! watch_output_has_already_running "$child_out"; then
      wait_windows_recorded_watcher "$HEALTHY_PID"
    fi
    # Another watcher won the singleton; our child stood down. Report the live one.
    report_healthy
    wait "$child" 2>/dev/null || true
    rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
      print_watch_output "$child_out"
      rm -f "$child_out" "$child_pid_file" 2>/dev/null || true
      exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
cleanup_child
wait "$child" 2>/dev/null || true
exit 1
