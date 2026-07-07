#!/usr/bin/env bash
# tests/fm-backend-herdr-handoff.test.sh - fake-herdr regression for the
# native-Windows spawn handoff path.
#
# This stays separate from tests/fm-backend-herdr.test.sh because that broader
# adapter suite is still deferred on native Windows for unrelated substrate
# failures. This file exercises only the reopened husk bug: create_task seeds a
# task tab shell, pane run submits `treehouse get`, and current_path must move
# to the worktree. The fake models the observed herdr behavior that a
# space-bearing Windows SHELL value leaves the pane as an empty husk, so pane
# run cannot execute the handoff command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-handoff-tests)

make_handoff_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "tab list")
    printf '{"result":{"tabs":[]}}\n'
    ;;
  "tab create")
    shell_env=""
    while [ "$#" -gt 0 ]; do
      if [ "${1:-}" = "--env" ]; then
        shell_env=${2:-}
        break
      fi
      shift
    done
    case "$shell_env" in
      *"Program Files"*) husk=true ;;
      *) husk=false ;;
    esac
    jq -n --arg cwd "C:\\Users\\captain\\project" --argjson husk "$husk" \
      '{pane:{foreground_cwd:$cwd,husk:$husk,shell_started:false}}' > "$STATE"
    printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  "pane run")
    text=${4:-}
    case "$text" in
      *'PROGRA~1\Git\usr\bin\bash.exe -l')
        if [ "$(jq -r '.pane.husk' "$STATE")" = false ]; then
          jq '.pane.shell_started = true' "$STATE" > "$STATE.tmp" &&
            mv "$STATE.tmp" "$STATE"
        fi
        ;;
    esac
    if [ "$text" = "treehouse get" ] && [ "$(jq -r '.pane.shell_started' "$STATE")" = true ]; then
      jq '.pane.foreground_cwd = "C:\\Users\\captain\\worktree"' "$STATE" > "$STATE.tmp" &&
        mv "$STATE.tmp" "$STATE"
    fi
    case "$text" in
      *"__FM_HERDR_CWD_BEGIN__"*)
        if [ "$(jq -r '.pane.shell_started' "$STATE")" = true ]; then
          jq '.pane.probed = true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
        fi
        ;;
    esac
    ;;
  "pane get")
    jq '{result:{pane:{foreground_cwd:.pane.foreground_cwd}}}' "$STATE"
    ;;
  "pane read")
    if [ "$(jq -r '.pane.probed // false' "$STATE")" = true ]; then
      cwd=$(jq -r '.pane.foreground_cwd' "$STATE")
      printf '__FM_HERDR_CWD_BEGIN__\n%s\n__FM_HERDR_CWD_END__\n' "$cwd"
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/cygpath" <<'SH'
#!/usr/bin/env bash
set -u
printf 'cygpath' >> "${FM_CYGPATH_LOG:?}"
for a in "$@"; do printf '\x1f%s' "$a" >> "$FM_CYGPATH_LOG"; done
printf '\n' >> "$FM_CYGPATH_LOG"
case "${1:-}" in
  -w)
    if [ "${2:-}" = -s ]; then
      shift
      case "${2:-}" in
        /usr/bin/bash) printf 'C:\\PROGRA~1\\Git\\usr\\bin\\bash.exe\n' ;;
        *) printf '%s\n' "${2:-}" ;;
      esac
      exit 0
    fi
    case "${2:-}" in
      /c/Users/captain/project) printf 'C:\\Users\\captain\\project\n' ;;
      /usr/bin/bash) printf 'C:\\Program Files\\Git\\usr\\bin\\bash.exe\n' ;;
      *) printf '%s\n' "${2:-}" ;;
    esac
    ;;
  -u)
    case "${2:-}" in
      'C:\Users\captain\project') printf '/c/Users/captain/project\n' ;;
      'C:\Users\captain\worktree') printf '/c/Users/captain/worktree\n' ;;
      *) printf '%s\n' "${2:-}" ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/cygpath"
  printf '%s\n' "$fb"
}

test_windows_handoff_completes_with_space_safe_native_shell() {
  local dir log state cyglog fb ids tab pane target p
  dir="$TMP_ROOT/windows-handoff"; mkdir -p "$dir"
  log="$dir/herdr.log"; state="$dir/state.json"; cyglog="$dir/cygpath.log"
  : > "$log"; : > "$cyglog"
  fb=$(make_handoff_fakebin "$dir")

  ids=$( PATH="$fb:$PATH" SHELL=/usr/bin/bash FM_PLATFORM_IS_WINDOWS=yes \
    FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" FM_CYGPATH_LOG="$cyglog" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-handoff /c/Users/captain/project' "$ROOT" ) \
    || fail "create_task should create the herdr task tab"
  read -r tab pane <<EOF
$ids
EOF
  [ "$tab" = "w1:t2" ] && [ "$pane" = "w1:p2" ] || fail "create_task returned unexpected ids: $ids"
  target="fmtest:$pane"

  PATH="$fb:$PATH" FM_PLATFORM_IS_WINDOWS=yes FM_HERDR_LOG="$log" \
    FM_FAKE_HERDR_STATE="$state" FM_CYGPATH_LOG="$cyglog" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_line "$1" "treehouse get"' "$ROOT" "$target" \
    || fail "send_text_line should submit treehouse get"
  p=$( PATH="$fb:$PATH" FM_PLATFORM_IS_WINDOWS=yes FM_HERDR_LOG="$log" \
    FM_FAKE_HERDR_STATE="$state" FM_CYGPATH_LOG="$cyglog" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_current_path "$1"' "$ROOT" "$target" ) \
    || fail "current_path should read foreground_cwd"

  [ "$p" = "/c/Users/captain/worktree" ] \
    || fail "treehouse get handoff did not enter the worktree; got '$p'"
  assert_contains "$(cat "$cyglog")" $'cygpath\x1f-w\x1f-s\x1f/usr/bin/bash' \
    "Windows shell resolution must request a short, space-free native Git Bash path"
  assert_contains "$(cat "$log")" "SHELL=C:\\PROGRA~1\\Git\\usr\\bin\\bash.exe" \
    "create_task did not pass the space-safe shell path to herdr"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''run'$'\x1f''w1:p2'$'\x1f''C:\PROGRA~1\Git\usr\bin\bash.exe -l' \
    "create_task did not start the resolved login shell before handoff"
  pass "fm_backend_herdr handoff: Windows create_task -> pane run treehouse get -> current_path enters the worktree"
}

test_windows_handoff_completes_with_space_safe_native_shell
