#!/usr/bin/env bash
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-runner-windows)
RUNNER="$ROOT/bin/fm-test-runner-windows.sh"
NO_MISTAKES="$ROOT/.no-mistakes.yaml"
# shellcheck disable=SC2016 # Literal upstream command; $t/$rc must not expand here.
POSIX_COMMAND=':; command -v tmux >/dev/null || { echo "tmux is required for e2e tests" >&2; exit 1; }; tmux -V; rc=0; for t in tests/*.test.sh; do echo "== $t =="; bash "$t" || rc=1; done; exit "$rc"'
# shellcheck disable=SC2016 # Literal batch command; $t/$rc must not expand here.
BATCH_COMMAND='. ./bin/fm-platform-lib.sh; if fm_platform_is_windows; then ./bin/fm-test-runner-windows.sh; else rc=0; for t in tests/*.test.sh; do echo "== $t =="; bash "$t" || rc=1; done; exit "$rc"; fi'

test_no_mistakes_posix_command_is_literal_upstream_loop() {
  assert_grep "$POSIX_COMMAND" "$NO_MISTAKES" \
    "POSIX no-mistakes command drifted from the upstream sequential loop"
  pass "no-mistakes POSIX command preserves the upstream sequential loop literally"
}

extract_batch_command() {
  local line cmd
  line=$(grep -F '"%NMBASH%" -c ' "$NO_MISTAKES" || true)
  [ -n "$line" ] || fail "native-Windows batch command is missing the Git Bash -c call"
  cmd=$(printf '%s\n' "$line" | sed -n 's/^[[:space:]]*"%NMBASH%" -c "\(.*\)"$/\1/p')
  [ -n "$cmd" ] || fail "could not extract native-Windows batch shell command"
  cmd=${cmd//\\\"/\"}
  printf '%s\n' "$cmd"
}

test_no_mistakes_batch_command_selects_windows_or_posix_branch() {
  local dir cmd out status
  dir="$TMP_ROOT/branch"
  mkdir -p "$dir/bin" "$dir/tests"
  cp "$ROOT/bin/fm-platform-lib.sh" "$dir/bin/fm-platform-lib.sh"
  cat > "$dir/bin/fm-test-runner-windows.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' selected-windows-runner
SH
  chmod +x "$dir/bin/fm-test-runner-windows.sh"
  cat > "$dir/tests/a.test.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' selected-sequential-loop
SH
  chmod +x "$dir/tests/a.test.sh"

  cmd=$(extract_batch_command)
  [ "$cmd" = "$BATCH_COMMAND" ] || fail "native-Windows batch command drifted"$'\n'"expected: $BATCH_COMMAND"$'\n'"actual:   $cmd"

  out=$(cd "$dir" && FM_PLATFORM_IS_WINDOWS=no bash -lc "$cmd" 2>&1)
  status=$?
  expect_code 0 "$status" "forced-POSIX batch command"
  assert_contains "$out" "== tests/a.test.sh ==" "forced-POSIX branch did not run the sequential loop header"
  assert_contains "$out" "selected-sequential-loop" "forced-POSIX branch did not run the test script"
  assert_not_contains "$out" "selected-windows-runner" "forced-POSIX branch selected the Windows runner"

  out=$(cd "$dir" && FM_PLATFORM_IS_WINDOWS=yes bash -lc "$cmd" 2>&1)
  status=$?
  expect_code 0 "$status" "forced-Windows batch command"
  [ "$out" = selected-windows-runner ] || fail "forced-Windows branch did not select the Windows runner: $out"

  pass "native-Windows batch command selects sequential POSIX branch or Windows runner by platform seam"
}

test_runner_refuses_non_windows_platform() {
  local dir out status
  dir="$TMP_ROOT/non-windows"
  mkdir -p "$dir/tests"
  out=$(cd "$dir" && FM_PLATFORM_IS_WINDOWS=no "$RUNNER" 2>&1)
  status=$?
  expect_code 2 "$status" "runner should refuse non-Windows platforms"
  assert_contains "$out" "Windows only" "non-Windows refusal did not explain the guard"
  pass "fm-test-runner-windows refuses non-Windows platforms"
}

test_runner_fails_when_test_glob_is_empty() {
  local dir out status
  dir="$TMP_ROOT/empty-glob"
  mkdir -p "$dir/tests"
  out=$(cd "$dir" && FM_PLATFORM_IS_WINDOWS=yes "$RUNNER" 2>&1)
  status=$?
  expect_code 1 "$status" "runner should fail when tests/*.test.sh matches nothing"
  assert_contains "$out" "no test scripts matched tests/*.test.sh" "empty-glob failure did not explain the problem"
  pass "fm-test-runner-windows fails clearly when tests/*.test.sh is empty"
}

write_parallel_stub() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
: "${RUNNER_MARKER:?}"
name=${0##*/}
touch "$RUNNER_MARKER/ran-$name"
touch "$RUNNER_MARKER/parallel-start-$name"
i=0
while [ "$i" -lt 100 ]; do
  count=$(find "$RUNNER_MARKER" -name 'parallel-start-*' | wc -l | tr -d ' ')
  [ "$count" -ge 3 ] && break
  sleep 0.05
  i=$((i + 1))
done
count=$(find "$RUNNER_MARKER" -name 'parallel-start-*' | wc -l | tr -d ' ')
[ "$count" -ge 3 ] || { echo "$name did not observe parallel overlap"; exit 9; }
touch "$RUNNER_MARKER/parallel-overlap-$name"
printf 'stdout %s\n' "$name"
printf 'stderr %s\n' "$name" >&2
case "$name" in
  fm-gotmp.test.sh) exit 7 ;;
esac
exit 0
SH
  chmod +x "$path"
}

write_serial_stub() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
: "${RUNNER_MARKER:?}"
name=${0##*/}
touch "$RUNNER_MARKER/ran-$name"
if ! mkdir "$RUNNER_MARKER/serial.lock" 2>/dev/null; then
  touch "$RUNNER_MARKER/serial-overlap"
  echo "serial overlap: $name"
  exit 8
fi
sleep 0.2
rmdir "$RUNNER_MARKER/serial.lock"
printf 'stdout %s\n' "$name"
exit 0
SH
  chmod +x "$path"
}

test_runner_buffers_parallel_output_replays_in_order_and_preserves_rc() {
  local dir marker out err status headers expected name
  dir="$TMP_ROOT/runner"
  marker="$dir/marker"
  mkdir -p "$dir/tests" "$marker"

  write_serial_stub "$dir/tests/fm-afk-inject-e2e.test.sh"
  write_parallel_stub "$dir/tests/fm-brief.test.sh"
  write_parallel_stub "$dir/tests/fm-gotmp.test.sh"
  write_parallel_stub "$dir/tests/fm-platform-lib.test.sh"
  write_serial_stub "$dir/tests/fm-watcher-lock.test.sh"

  out=$(cd "$dir" && RUNNER_MARKER="$marker" FM_PLATFORM_IS_WINDOWS=yes FM_TEST_JOBS=3 "$RUNNER" 2>"$dir/stderr.log")
  status=$?
  err=$(cat "$dir/stderr.log")
  expect_code 1 "$status" "runner should continue but return failure when a test fails"

  expected=$'tests/fm-afk-inject-e2e.test.sh\ntests/fm-brief.test.sh\ntests/fm-gotmp.test.sh\ntests/fm-platform-lib.test.sh\ntests/fm-watcher-lock.test.sh'
  headers=$(printf '%s\n' "$out" | awk '/^== tests\/.*\.test\.sh ==$/ { print $2 }')
  [ "$headers" = "$expected" ] || fail "runner headers were not replayed in glob order"$'\n'"expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$headers"

  for name in \
    fm-afk-inject-e2e.test.sh \
    fm-brief.test.sh \
    fm-gotmp.test.sh \
    fm-platform-lib.test.sh \
    fm-watcher-lock.test.sh
  do
    assert_present "$marker/ran-$name" "runner did not execute $name"
  done

  for name in fm-brief.test.sh fm-gotmp.test.sh fm-platform-lib.test.sh; do
    assert_present "$marker/parallel-overlap-$name" "parallel candidate $name did not overlap with its peers"
  done

  assert_absent "$marker/serial-overlap" "serial bucket tests overlapped"
  assert_contains "$out" "stdout fm-gotmp.test.sh" "failing parallel stdout was not replayed"
  assert_contains "$err" "stderr fm-gotmp.test.sh" "failing parallel stderr was not replayed"
  pass "fm-test-runner-windows buffers parallel output, replays in order, serializes serial tests, and preserves failure rc"
}

test_no_mistakes_posix_command_is_literal_upstream_loop
test_no_mistakes_batch_command_selects_windows_or_posix_branch
test_runner_refuses_non_windows_platform
test_runner_fails_when_test_glob_is_empty
test_runner_buffers_parallel_output_replays_in_order_and_preserves_rc
