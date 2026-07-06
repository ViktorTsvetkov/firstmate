#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
mkdir -p "$STATE"
# shellcheck source=bin/fm-platform-lib.sh
. "$FM_WAKE_LIB_DIR/fm-platform-lib.sh"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

# Windows-port seam (STRICT ADDITIVE): true only on native Windows shells (Git
# Bash / Cygwin / MSYS). Every Windows-specific code path in this file is selected
# by this predicate; Linux/macOS fall through to the exact original behavior. The
# result is memoized by fm-platform-lib.sh and honors FM_IS_WINDOWS/
# FM_PLATFORM_IS_WINDOWS so tests can force either branch.
fm_is_windows() {
  fm_platform_is_windows
}

# Read the first line of a file into the named variable with no subprocess.
# WINDOWS-ONLY helper: the mkdir lock's hot path reads tiny single-line files
# (pid, owner) thousands of times under contention, and on Windows a `$(cat file)`
# per read - a fork plus an exec - dominates the runtime and makes the lock races
# flaky. A builtin `read` costs zero forks. The POSIX lock path keeps its original
# `cat` reads untouched; only fm_lock_*_win call this. Missing/empty file yields an
# empty value, matching the old `cat ... 2>/dev/null` behavior.
fm_read1() {  # fm_read1 <destvar> <file>
  local -n __fm_r1_dest=$1
  __fm_r1_dest=
  [ -e "$2" ] || return 1
  # Group the redirection so a failed OPEN is silenced too: under contention a
  # peer may be mid-write and the open can transiently fail (on Windows a sharing
  # violation surfaces as "Permission denied"). Swallow it, leave the value empty.
  { IFS= read -r __fm_r1_dest < "$2"; } 2>/dev/null || true
  return 0
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_pid_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # STRICT ADDITIVE: Linux/macOS keep the exact original `ps -o` fingerprint;
  # native Windows (whose Cygwin `ps` rejects -o) takes a /proc fallback instead.
  if fm_is_windows; then
    fm_platform_pid_identity "$pid"
    return
  fi
  out=$(ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

# WINDOWS-ONLY: fingerprint a pid when `ps -o` is unavailable (Cygwin/Git Bash).
# Field 22 of /proc/<pid>/stat is the process start time (clock ticks since boot)
# - a stable, pid-reuse-sensitive fingerprint, the same property lstart gives on
# POSIX. comm (field 2) may contain spaces/parens, so key off the text after the
# last ')'. Pair the start time with argv for the same identity `ps` yields.
fm_pid_identity_win() {
  local pid=$1 out rest starttime cmd
  out=$(ps -p "$pid" -o lstart= -o command= 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
    return 0
  fi
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r out < "/proc/$pid/stat" 2>/dev/null || return 1
  rest=${out##*) }
  # shellcheck disable=SC2086 # deliberate word-splitting to index stat fields.
  set -- $rest
  starttime=${20:-}
  [ -n "$starttime" ] || return 1
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  printf '%s %s\n' "$starttime" "$cmd"
}

fm_path_mtime() {
  if fm_platform_is_macos; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

FM_WATCHER_HEALTHY_PID=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid age
  FM_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

# ==========================================================================
# Lock primitives.
#
# STRICT ADDITIVE PORT: the lock has one behavior contract and two mechanisms.
#   - POSIX (Linux/macOS): an atomic symlink whose target names a private owner
#     dir. This is the original, untouched implementation below - fm_is_windows
#     is false, so Linux/macOS run exactly this code.
#   - Windows (Git Bash/Cygwin): symlinks are not reliably atomic for
#     unprivileged users, so an atomic `mkdir` gate with an owner-id file is used
#     instead (fm_lock_*_win). Selected by fm_is_windows at the two public entry
#     points (fm_lock_try_acquire / fm_lock_release).
# Observable acquire/steal/stale-reclaim behavior is identical on both.
# ==========================================================================

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  # Dispatching entry point, like fm_lock_try_acquire / fm_lock_release: direct
  # callers such as bin/fm-watch-arm.sh (clear_stale_recorded_watcher_lock) must
  # remove the Windows lock's `owner` file too, or rmdir fails and the stale lock
  # persists. POSIX (symlink lock, no owner file) runs the original body below.
  if fm_is_windows; then
    fm_lock_remove_path_win "$@"
    return
  fi
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

# ---- Windows (Git Bash / Cygwin) lock mechanism ---------------------------
# Same contract as the POSIX symlink lock above, over an atomic `mkdir` gate: the
# lock is a real directory (exactly one creator wins the mkdir on NTFS as on a
# POSIX fs), and ownership of a specific hold is recorded in an `owner` id file
# plus the holder `pid`. The owner id (pid + two $RANDOM draws) is unique across
# concurrent acquirers and fresh across recreations, replacing the symlink target
# the POSIX path uses. None of these run on Linux/macOS (fm_is_windows is false).

fm_lock_new_owner_id() {
  printf '%s.%s.%s\n' "${BASHPID:-$$}" "${RANDOM}" "${RANDOM}"
}

fm_lock_clean_known_files_win() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/owner" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_read_owner_win() {
  local lockdir=$1 owner
  fm_read1 owner "$lockdir/owner" || return 1
  [ -n "$owner" ] || return 1
  printf '%s\n' "$owner"
}

fm_lock_points_to_owner_win() {
  local lockdir=$1 ownerid=$2 actual
  fm_read1 actual "$lockdir/owner" || return 1
  [ "$actual" = "$ownerid" ]
}

# Populate a lock dir we already own (created via mkdir) with its owner id and our
# pid. Owner is written first so a concurrent reader that sees a pid also sees the
# owner; the tiny window where neither is present yet is covered by the empty-pid
# minimum grace in fm_lock_mid_acquire_is_fresh.
fm_lock_prepare_owner_win() {
  local lockdir=$1 ownerid=$2 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$ownerid" > "$lockdir/owner" 2>/dev/null || return 1
  printf '%s\n' "$mypid" > "$lockdir/pid" 2>/dev/null || return 1
  fm_read1 back "$lockdir/pid"
  [ "$back" = "$mypid" ]
}

fm_lock_remove_path_win() {
  local lockdir=$1
  fm_lock_clean_known_files_win "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_claim_blocked_by_steal_win() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner_win "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim_win() {
  local lockdir=$1 ownerid=$2 allowed_steal_owner=${3:-}
  # We only hold the lock while it still records our owner id. A losing/late
  # claimant whose owner no longer matches must not touch the live holder's dir.
  if ! fm_lock_points_to_owner_win "$lockdir" "$ownerid"; then
    return 1
  fi
  if fm_lock_claim_blocked_by_steal_win "$lockdir" "$allowed_steal_owner"; then
    # A steal mutex we do not own is active: back off and drop our own hold so the
    # active stealer can recreate the lock cleanly.
    if fm_lock_points_to_owner_win "$lockdir" "$ownerid"; then
      fm_lock_remove_path_win "$lockdir" || true
    fi
    return 1
  fi
  return 0
}

fm_lock_try_create_win() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerid
  FM_LOCK_OWNER_DIR=
  ownerid=$(fm_lock_new_owner_id) || return 1
  # mkdir is the atomic gate: exactly one creator wins on POSIX and NTFS alike.
  if ! mkdir "$lockdir" 2>/dev/null; then
    return 1
  fi
  if ! fm_lock_prepare_owner_win "$lockdir" "$ownerid"; then
    fm_lock_remove_path_win "$lockdir" || true
    return 1
  fi
  if fm_lock_claim_win "$lockdir" "$ownerid" "$allowed_steal_owner"; then
    FM_LOCK_OWNER_DIR=$ownerid
    return 0
  fi
  # claim failed (blocked by a foreign steal); it removes our hold when we still
  # owned it. Belt-and-suspenders: clean up if anything is left pointing to us.
  if fm_lock_points_to_owner_win "$lockdir" "$ownerid"; then
    fm_lock_remove_path_win "$lockdir" || true
  fi
  return 1
}

fm_lock_recheck_stale_owner_win() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner_win "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ]; then
    [ -d "$lockdir" ] || return 1
  fi
  fm_read1 actual_pid "$lockdir/pid"
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

fm_lock_try_acquire_win() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  if fm_lock_try_create_win "$lockdir"; then
    return 0
  fi

  fm_read1 pid "$lockdir/pid"
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire_win "$steal"; then
    fm_read1 FM_LOCK_HELD_PID "$lockdir/pid"
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  fm_read1 cur "$lockdir/pid"
  if fm_pid_alive "$cur"; then
    fm_lock_release_win "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release_win "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner_win "$steal" "$steal_owner"; then
    fm_lock_release_win "$steal"
    fm_read1 FM_LOCK_HELD_PID "$lockdir/pid"
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=$(fm_lock_read_owner_win "$lockdir" 2>/dev/null || true)
  fm_read1 cur "$lockdir/pid"
  if ! fm_lock_recheck_stale_owner_win "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release_win "$steal"
    fm_read1 FM_LOCK_HELD_PID "$lockdir/pid"
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path_win "$lockdir" || true
  rc=1
  if fm_lock_try_create_win "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    fm_read1 FM_LOCK_HELD_PID "$lockdir/pid"
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release_win "$steal"
  return "$rc"
}

fm_lock_release_win() {
  local lockdir=$1 pid current
  current=${BASHPID:-$$}
  fm_read1 pid "$lockdir/pid"
  [ "$pid" = "$current" ] || return 0
  fm_lock_remove_path_win "$lockdir" || true
}

# ---- Public lock entry points: dispatch to the platform mechanism ---------

fm_lock_try_acquire() {
  if fm_is_windows; then
    fm_lock_try_acquire_win "$@"
    return
  fi
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  if fm_is_windows; then
    fm_lock_release_win "$@"
    return
  fi
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
