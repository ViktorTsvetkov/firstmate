#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$ROOT/bin/fm-config-inherit-lib.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-config-inherit)

test_windows_same_store_worktree_path_forms() {
  fm_platform_is_windows || {
    pass "same-store worktree path-form regression is Windows-only"
    return 0
  }

  local repo sm src report stderr
  repo="$TMP_ROOT/path-forms-repo"
  sm="$TMP_ROOT/path-forms-sm"
  src="$TMP_ROOT/path-forms-src"
  report="$TMP_ROOT/path-forms-report.tsv"
  stderr="$TMP_ROOT/path-forms.err"

  fm_git_init_commit "$repo"
  printf 'config/\n' >> "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -qm ignore-config
  git -C "$repo" worktree add --quiet --detach "$sm" HEAD

  mkdir -p "$src"
  printf 'codex\n' > "$src/crew-harness"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$src" "$sm/config" >"$TMP_ROOT/path-forms.out" 2>"$stderr" \
    || fail "same-store worktree propagation returned non-zero"

  [ "$(cat "$sm/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "same-store worktree did not inherit crew-harness"
  assert_grep $'crew-harness\tpushed\t' "$report" \
    "same-store worktree did not report crew-harness as pushed"
  [ ! -s "$stderr" ] || fail "same-store worktree emitted unexpected stderr: $(cat "$stderr")"

  pass "same-store Windows worktree inherits gitignored crew-harness"
}

test_not_gitignored_destination_still_refused() {
  local repo src report stderr
  repo="$TMP_ROOT/not-ignored-repo"
  src="$TMP_ROOT/not-ignored-src"
  report="$TMP_ROOT/not-ignored-report.tsv"
  stderr="$TMP_ROOT/not-ignored.err"

  fm_git_init_commit "$repo"
  mkdir -p "$src"
  printf 'codex\n' > "$src/crew-harness"
  FM_CONFIG_INHERIT_REPORT="$report" FM_INHERITABLE_CONFIG=crew-harness \
    propagate_inheritable_config "$src" "$repo/config" >"$TMP_ROOT/not-ignored.out" 2>"$stderr" \
    || fail "refused destination should not make propagation fail"

  [ ! -e "$repo/config/crew-harness" ] || fail "not-gitignored destination was copied"
  assert_grep $'crew-harness\tskipped\tdestination does not allow inherited item' "$report" \
    "not-gitignored destination was not reported as skipped"
  assert_contains "$(cat "$stderr")" "fm-config-inherit: warning: skipped crew-harness" \
    "not-gitignored destination did not emit a warning"

  pass "not-gitignored destination remains refused"
}

test_windows_same_store_worktree_path_forms
test_not_gitignored_destination_still_refused
