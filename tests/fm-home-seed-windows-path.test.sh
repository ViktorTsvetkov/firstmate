#!/usr/bin/env bash
# Focused Windows-path coverage for fm-home-seed's treehouse-leased homes.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-seed-windows-path)
export FM_BACKEND=tmux

make_windows_path_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/cygpath" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  -u)
    shift
    if [ "${1:-}" = "${FM_FAKE_WINDOWS_HOME:-}" ]; then
      printf '%s\n' "${FM_FAKE_POSIX_HOME:?}"
    else
      printf '%s\n' "${1:-}"
    fi
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "${1:-}" in
  get)
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && printf '%s\n' "$holder" > "$FM_FAKE_TREEHOUSE_LEASE_FILE"
    printf '%s\n' "${FM_FAKE_WINDOWS_HOME:?}"
    ;;
  return)
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && rm -f "$FM_FAKE_TREEHOUSE_LEASE_FILE"
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/cygpath" "$fakebin/treehouse" "$fakebin/no-mistakes"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

prepare_active_home_with_project() {
  local home=$1 project=$2 remote
  mkdir -p "$home/projects" "$home/data" "$home/state"
  remote="$TMP_ROOT/remotes/$(basename "$home")-$project.git"
  fm_git_init_commit "$home/projects/$project"
  fm_git_add_origin "$home/projects/$project" "$remote"
  printf '%s\n' "- $project [direct-PR] - $project project (added 2026-06-22)" > "$home/data/projects.md"
}

test_windows_drive_home_from_treehouse_is_not_treated_as_active_descendant() {
  local home acquired acquired_abs fakebin log lease out windows_home
  home="$TMP_ROOT/windows-active"
  acquired="$TMP_ROOT/windows-acquired"
  windows_home='C:\Users\captain\.treehouse\firstmate\2\firstmate'
  prepare_active_home_with_project "$home" alpha
  git -C "$ROOT" worktree add --quiet --detach "$acquired" HEAD
  acquired_abs=$(cd "$acquired" && pwd -P)
  fakebin=$(make_windows_path_fakebin "$TMP_ROOT/windows-fake")
  log="$TMP_ROOT/windows-fake/tmux.log"
  lease="$TMP_ROOT/windows-fake/lease"

  out=$(PATH="$fakebin:$PATH" FM_PLATFORM_IS_WINDOWS=yes FM_HOME="$home" \
    FM_FAKE_WINDOWS_HOME="$windows_home" FM_FAKE_POSIX_HOME="$acquired_abs" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='windows acquired scope' FM_SECONDMATE_SCOPE='windows acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" windash - alpha) \
    || fail "seed rejected a Windows drive-letter treehouse home that is outside the active home"
  printf '%s\n' "$out" | grep -F "home=$acquired_abs" >/dev/null || fail "seed did not report the normalized acquired home"
  assert_grep "home: $acquired_abs" "$home/data/secondmates.md" "registry did not record the normalized acquired home"
  [ -f "$lease" ] || fail "successful seed should keep the durable lease held"
  pass "fm-home-seed: Windows drive-letter treehouse homes are normalized before active-home containment checks"
}

test_windows_drive_home_inside_active_home_is_still_refused() {
  local home acquired acquired_abs fakebin log err windows_home
  home="$TMP_ROOT/windows-inside-active"
  acquired="$home/data/inside-active"
  windows_home='C:\Users\captain\active\data\inside-active'
  prepare_active_home_with_project "$home" alpha
  git -C "$ROOT" worktree add --quiet --detach "$acquired" HEAD
  acquired_abs=$(cd "$acquired" && pwd -P)
  fakebin=$(make_windows_path_fakebin "$TMP_ROOT/windows-inside-fake")
  log="$TMP_ROOT/windows-inside-fake/tmux.log"
  err="$TMP_ROOT/windows-inside.err"

  if PATH="$fakebin:$PATH" FM_PLATFORM_IS_WINDOWS=yes FM_HOME="$home" \
    FM_FAKE_WINDOWS_HOME="$windows_home" FM_FAKE_POSIX_HOME="$acquired_abs" \
    FM_FAKE_TMUX_LOG="$log" \
    FM_SECONDMATE_CHARTER='windows acquired scope' FM_SECONDMATE_SCOPE='windows acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" windash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted a Windows drive-letter treehouse home inside the active home"
  fi
  assert_grep 'secondmate home cannot be inside the active firstmate home' "$err" \
    "seed did not preserve the active-home descendant guard"
  pass "fm-home-seed: Windows normalization still refuses homes inside the active home"
}

test_windows_acquired_home_is_returned_after_post_lease_validation_failure() {
  local home acquired acquired_abs fakebin log err lease windows_home
  home="$TMP_ROOT/windows-rollback-active"
  acquired="$TMP_ROOT/windows-rollback-acquired"
  windows_home='C:\Users\captain\.treehouse\firstmate\3\firstmate'
  prepare_active_home_with_project "$home" alpha
  git -C "$ROOT" worktree add --quiet --detach "$acquired" HEAD
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_windows_path_fakebin "$TMP_ROOT/windows-rollback-fake")
  log="$TMP_ROOT/windows-rollback-fake/tmux.log"
  err="$TMP_ROOT/windows-rollback.err"
  lease="$TMP_ROOT/windows-rollback-fake/lease"

  if PATH="$fakebin:$PATH" FM_PLATFORM_IS_WINDOWS=yes FM_HOME="$home" \
    FM_FAKE_WINDOWS_HOME="$windows_home" FM_FAKE_POSIX_HOME="$acquired_abs" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='windows acquired scope' FM_SECONDMATE_SCOPE='windows acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" windash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired Windows drive-letter home marked for another secondmate"
  fi
  assert_grep 'already marked for other' "$err" "seed did not report the post-lease validation failure"
  assert_grep "treehouse return --force $acquired_abs" "$log" \
    "post-lease validation failure did not return the acquired treehouse home"
  [ ! -f "$lease" ] || fail "post-lease validation failure left the fake lease held"
  pass "fm-home-seed: post-lease validation failures return Windows-normalized acquired homes"
}

test_windows_drive_home_from_treehouse_is_not_treated_as_active_descendant
test_windows_drive_home_inside_active_home_is_still_refused
test_windows_acquired_home_is_returned_after_post_lease_validation_failure
