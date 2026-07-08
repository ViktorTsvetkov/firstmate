#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry.
# On native Windows under herdr, where Git Bash tool commands may lose that
# ancestry, falls back to the herdr pane's live process-group leader and records
# state/.lock.herdr metadata, including herdr's detected agent type, for later
# stale-lock verification.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_HERDR="$LOCK.herdr"
mkdir -p "$STATE"
# shellcheck source=bin/fm-platform-lib.sh
. "$SCRIPT_DIR/fm-platform-lib.sh"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(fm_platform_ps_field "$pid" comm) || return 1
    args=$(fm_platform_ps_field "$pid" args || true)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(fm_platform_ps_field "$pid" ppid || true)
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

herdr_agent_identity_from_json() {
  local out value
  out=$(cat)
  value=$(printf '%s\n' "$out" | sed -n 's/.*"agent"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  if [ -z "$value" ]; then
    value=$(printf '%s\n' "$out" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  fi
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

herdr_agent_name() {
  local session=${HERDR_SESSION:-default} out
  [ -n "${HERDR_PANE_ID:-}" ] || return 1
  command -v herdr >/dev/null 2>&1 || return 1
  out=$(herdr agent get "$HERDR_PANE_ID" --session "$session" 2>/dev/null) || return 1
  printf '%s\n' "$out" | herdr_agent_identity_from_json
}

harness_pid_windows_herdr() {
  local pgid agent
  fm_platform_is_windows || return 1
  [ "${HERDR_ENV:-}" = 1 ] || return 1
  agent=$(herdr_agent_name) || return 1
  printf '%s' "$agent" | grep -qE "$HARNESS_RE" || return 1
  pgid=$(fm_platform_ps_fixed_field "$$" pgid || true)
  [ -n "$pgid" ] && [ "$pgid" -gt 1 ] || return 1
  kill -0 "$pgid" 2>/dev/null || return 1
  echo "$pgid"
}

herdr_lock_value() {  # <key>
  local key=$1
  [ -f "$LOCK_HERDR" ] || return 1
  sed -n "s/^$key=//p" "$LOCK_HERDR" | head -n 1
}

holder_alive_windows_herdr() {  # <pid>
  local pid=$1 rec_pid session pane agent live_agent
  fm_platform_is_windows || return 1
  rec_pid=$(herdr_lock_value pid || true)
  [ "$rec_pid" = "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  session=$(herdr_lock_value session || true)
  pane=$(herdr_lock_value pane || true)
  agent=$(herdr_lock_value agent || true)
  [ -n "$session" ] && [ -n "$pane" ] && [ -n "$agent" ] || return 1
  printf '%s' "$agent" | grep -qE "$HARNESS_RE" || return 1
  live_agent=$(HERDR_PANE_ID="$pane" HERDR_SESSION="$session" herdr_agent_name) || return 1
  [ "$live_agent" = "$agent" ]
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm rec_pid
  if fm_platform_is_windows; then
    rec_pid=$(herdr_lock_value pid || true)
    [ "$rec_pid" = "$pid" ] && { holder_alive_windows_herdr "$pid"; return; }
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_platform_ps_field "$pid" comm) || { holder_alive_windows_herdr "$pid"; return; }
  printf '%s' "$(basename "$comm") $(fm_platform_ps_field "$pid" args 2>/dev/null)" | grep -qE "$HARNESS_RE" && return 0
  holder_alive_windows_herdr "$pid"
}

record_herdr_lock() {  # <pid>
  local pid=$1 pgid agent session
  rm -f "$LOCK_HERDR"
  fm_platform_is_windows || return 0
  [ "${HERDR_ENV:-}" = 1 ] || return 0
  [ -n "${HERDR_PANE_ID:-}" ] || return 0
  pgid=$(fm_platform_ps_fixed_field "$$" pgid || true)
  [ "$pgid" = "$pid" ] || return 0
  agent=$(herdr_agent_name) || return 0
  printf '%s' "$agent" | grep -qE "$HARNESS_RE" || return 0
  session=${HERDR_SESSION:-default}
  {
    printf 'pid=%s\n' "$pid"
    printf 'session=%s\n' "$session"
    printf 'pane=%s\n' "$HERDR_PANE_ID"
    printf 'agent=%s\n' "$agent"
  } > "$LOCK_HERDR"
}

if [ "${FM_LOCK_LIB_ONLY:-}" = 1 ]; then
  # shellcheck disable=SC2317 # This file can be sourced or executed.
  return 0 2>/dev/null || exit 0
fi

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || me=$(harness_pid_windows_herdr) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
record_herdr_lock "$me"
echo "lock acquired: harness pid $me"
