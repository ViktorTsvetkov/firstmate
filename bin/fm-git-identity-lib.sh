#!/usr/bin/env bash
# Shared git backing-store identity checks for leased worktrees.

fm_git_common_dir_realpath() {  # <repo>
  local repo=$1 common
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  ( cd "$common" 2>/dev/null && pwd -P )
}

fm_git_common_dir_matches() {  # <expected-repo> <candidate-repo>
  local expected=$1 candidate=$2 expected_common candidate_common
  expected_common=$(fm_git_common_dir_realpath "$expected") || return 1
  candidate_common=$(fm_git_common_dir_realpath "$candidate") || return 1
  [ "$candidate_common" = "$expected_common" ]
}
