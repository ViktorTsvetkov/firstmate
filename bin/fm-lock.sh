#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness process PID found by walking the shell's ancestry.
# On native Windows under herdr, where Git Bash tool commands run detached from
# the durable pane agent, records the herdr session, pane, terminal identity.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
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

fm_platform_is_windows_herdr() {
  fm_platform_is_windows || return 1
  [ "${HERDR_ENV:-}" = 1 ] || [ -n "${HERDR_PANE_ID:-}" ]
}

herdr_json_value() {  # <jq-expr> <fallback-key>
  local expr=$1 key=$2 out
  out=$(cat)
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$out" | jq -r "$expr // empty" 2>/dev/null | tr -d '\r' | head -n 1
    return 0
  fi
  printf '%s\n' "$out" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | tr -d '\r' | head -n 1
}

herdr_agent_identity_from_json() {
  local out value
  out=$(cat)
  value=$(printf '%s\n' "$out" | herdr_json_value '.result.agent.agent // .agent' agent)
  if [ -z "$value" ]; then
    value=$(printf '%s\n' "$out" | herdr_json_value '.result.agent.name // .name' name)
  fi
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

herdr_pane_terminal_from_json() {
  local out value
  out=$(cat)
  value=$(printf '%s\n' "$out" | herdr_json_value '.result.pane.terminal_id // .terminal_id' terminal_id)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

herdr_pane_agent_status_from_json() {
  local out value
  out=$(cat)
  value=$(printf '%s\n' "$out" | herdr_json_value '.result.pane.agent_status // .agent_status' agent_status)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

herdr_pane_get() {  # <session> <pane>
  local session=$1 pane=$2
  command -v herdr >/dev/null 2>&1 || return 1
  HERDR_SESSION="$session" herdr pane get "$pane" --session "$session" 2>/dev/null
}

herdr_agent_get() {  # <session> <pane>
  local session=$1 pane=$2
  command -v herdr >/dev/null 2>&1 || return 1
  HERDR_SESSION="$session" herdr agent get "$pane" --session "$session" 2>/dev/null
}

harness_identity_windows_herdr() {
  local session pane pane_out agent_out agent terminal agent_status
  fm_platform_is_windows_herdr || return 1
  pane=${HERDR_PANE_ID:-}
  [ -n "$pane" ] || return 1
  session=${HERDR_SESSION:-default}
  pane_out=$(herdr_pane_get "$session" "$pane") || return 1
  terminal=$(printf '%s\n' "$pane_out" | herdr_pane_terminal_from_json) || return 1
  agent_status=$(printf '%s\n' "$pane_out" | herdr_pane_agent_status_from_json) || return 1
  [ "$agent_status" != gone ] || return 1
  agent_out=$(herdr_agent_get "$session" "$pane") || return 1
  agent=$(printf '%s\n' "$agent_out" | herdr_agent_identity_from_json) || return 1
  printf '%s' "$agent" | grep -qE "$HARNESS_RE" || return 1
  printf 'herdr:%s:%s:%s\n' "$session" "$pane" "$terminal"
}

holder_alive_windows_herdr() {  # <owner>
  local owner=$1 rest session pane terminal pane_out agent_out live_agent live_terminal live_status
  fm_platform_is_windows || return 1
  case "$owner" in
    herdr:*:*:*) ;;
    *) return 1 ;;
  esac
  rest=${owner#herdr:}
  session=${rest%%:*}
  rest=${rest#*:}
  terminal=${rest##*:}
  pane=${rest%:*}
  [ -n "$session" ] && [ -n "$pane" ] && [ -n "$terminal" ] || return 1
  pane_out=$(herdr_pane_get "$session" "$pane") || return 1
  live_terminal=$(printf '%s\n' "$pane_out" | herdr_pane_terminal_from_json) || return 1
  [ "$live_terminal" = "$terminal" ] || return 1
  live_status=$(printf '%s\n' "$pane_out" | herdr_pane_agent_status_from_json) || return 1
  [ "$live_status" != gone ] || return 1
  agent_out=$(herdr_agent_get "$session" "$pane") || return 1
  live_agent=$(printf '%s\n' "$agent_out" | herdr_agent_identity_from_json) || return 1
  printf '%s' "$live_agent" | grep -qE "$HARNESS_RE"
}

legacy_herdr_lock_value() {  # <key>
  local key=$1 sidecar="$LOCK.herdr"
  fm_platform_is_windows || return 1
  [ -f "$sidecar" ] || return 1
  sed -n "s/^$key=//p" "$sidecar" | head -n 1
}

holder_alive_windows_herdr_legacy_pid() {  # <pid>
  local pid=$1 rec_pid session pane agent pane_out agent_out live_agent live_status
  fm_platform_is_windows || return 1
  rec_pid=$(legacy_herdr_lock_value pid || true)
  [ "$rec_pid" = "$pid" ] || return 1
  session=$(legacy_herdr_lock_value session || true)
  pane=$(legacy_herdr_lock_value pane || true)
  agent=$(legacy_herdr_lock_value agent || true)
  [ -n "$session" ] && [ -n "$pane" ] && [ -n "$agent" ] || return 1
  printf '%s' "$agent" | grep -qE "$HARNESS_RE" || return 1
  pane_out=$(herdr_pane_get "$session" "$pane") || return 1
  live_status=$(printf '%s\n' "$pane_out" | herdr_pane_agent_status_from_json) || return 1
  [ "$live_status" != gone ] || return 1
  agent_out=$(herdr_agent_get "$session" "$pane") || return 1
  live_agent=$(printf '%s\n' "$agent_out" | herdr_agent_identity_from_json) || return 1
  [ "$live_agent" = "$agent" ]
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  case "$pid" in
    herdr:*) holder_alive_windows_herdr "$pid"; return ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_platform_ps_field "$pid" comm || true)
  [ -n "$comm" ] && printf '%s' "$(basename "$comm") $(fm_platform_ps_field "$pid" args 2>/dev/null)" | grep -qE "$HARNESS_RE" && return 0
  fm_platform_is_windows && holder_alive_windows_herdr_legacy_pid "$pid"
}

if [ "${FM_LOCK_LIB_ONLY:-}" = 1 ]; then
  # shellcheck disable=SC2317 # This file can be sourced or executed.
  return 0 2>/dev/null || exit 0
fi

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  case "$old" in
    herdr:*)
      if holder_alive "$old"; then echo "lock: held by live herdr agent $old"; else echo "lock: stale (herdr agent $old gone or changed)"; fi
      ;;
    *)
      if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
      ;;
  esac
  exit 0
fi

if fm_platform_is_windows_herdr; then
  me=$(harness_identity_windows_herdr) || me=$(harness_pid) \
    || { echo "error: cannot locate herdr pane-agent identity or harness ancestry" >&2; exit 1; }
else
  me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
fi
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    case "$old" in
      herdr:*) echo "error: another live firstmate session holds the lock ($old); operate read-only until resolved" >&2 ;;
      *) echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2 ;;
    esac
    exit 1
  fi
fi
echo "$me" > "$LOCK"
fm_platform_is_windows && rm -f "$LOCK.herdr"
case "$me" in
  herdr:*) echo "lock acquired: herdr agent $me" ;;
  *) echo "lock acquired: harness pid $me" ;;
esac
