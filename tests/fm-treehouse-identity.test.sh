#!/usr/bin/env bash
# Focused treehouse backing-repo identity guards.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-identity)

make_seed_home() {
  local home=$1 project=$2 remote=$3
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/$project"
  fm_git_add_origin "$home/projects/$project" "$remote"
  printf -- '- %s [direct-PR] - test project (added 2026-07-08)\n' "$project" > "$home/data/projects.md"
}

make_root_treehouse_worktree() {
  git -C "$ROOT" worktree add --quiet --detach "$1" HEAD
}

test_home_seed_accepts_treehouse_home_from_same_git_store() {
  local home acquired acquired_abs fakebin log lease out
  home="$TMP_ROOT/same-store-home"
  acquired="$TMP_ROOT/same-store-acquired"
  make_seed_home "$home" alpha "$TMP_ROOT/remotes/same-store-alpha.git"
  make_root_treehouse_worktree "$acquired"
  fakebin=$(make_fake_tmux "$TMP_ROOT/same-store-fake")
  log="$TMP_ROOT/same-store-fake/tmux.log"
  lease="$TMP_ROOT/same-store-fake/lease"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='same store scope' FM_SECONDMATE_SCOPE='same store scope' \
    "$ROOT/bin/fm-home-seed.sh" same - alpha) \
    || fail "seed rejected a treehouse-acquired home from the same git store"
  acquired_abs=$(cd "$acquired" && pwd -P)
  assert_contains "$out" "home=$acquired_abs" "seed did not report the accepted acquired home"
  assert_grep "home: $acquired_abs" "$home/data/secondmates.md" "registry did not record accepted acquired home"
  pass "fm-home-seed: treehouse-acquired homes from the same git store still pass"
}

test_home_seed_refuses_treehouse_home_from_wrong_git_store() {
  local home acquired other_root acquired_abs fakebin log lease err
  home="$TMP_ROOT/wrong-store-home"
  other_root="$TMP_ROOT/wrong-store-other-root"
  acquired="$TMP_ROOT/wrong-store-acquired"
  err="$TMP_ROOT/wrong-store.err"
  make_seed_home "$home" alpha "$TMP_ROOT/remotes/wrong-store-alpha.git"
  make_firstmate_git_root "$other_root"
  git -C "$other_root" worktree add --quiet --detach "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  fakebin=$(make_fake_tmux "$TMP_ROOT/wrong-store-fake")
  log="$TMP_ROOT/wrong-store-fake/tmux.log"
  lease="$TMP_ROOT/wrong-store-fake/lease"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='wrong store scope' FM_SECONDMATE_SCOPE='wrong store scope' \
    "$ROOT/bin/fm-home-seed.sh" wrong - alpha >/dev/null 2>"$err"; then
    fail "seed accepted a treehouse-acquired home from another git store"
  fi
  assert_grep 'backed by a different git store' "$err" "wrong-store seed did not explain the refusal"
  assert_grep "treehouse return --force $acquired_abs" "$log" "wrong-store seed did not return the acquired lease"
  [ ! -f "$lease" ] || fail "wrong-store seed did not clear the fake lease"
  pass "fm-home-seed: treehouse-acquired homes from another git store are refused and returned"
}

test_home_seed_accepts_treehouse_home_from_same_git_store
test_home_seed_refuses_treehouse_home_from_wrong_git_store
