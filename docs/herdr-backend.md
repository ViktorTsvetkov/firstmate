# Herdr runtime backend (experimental)

This document records the empirical verification behind `bin/backends/herdr.sh`, the herdr session-provider adapter added in P2 of the runtime-backend abstraction.
It is the herdr equivalent of the tmux facts recorded in the `harness-adapters` skill and `docs/architecture.md`'s "Runtime session backends" section.

Herdr is [an agent-native terminal multiplexer](https://herdr.dev) with a socket API, CLI wrappers, and native per-pane agent-state detection.
Verified against real installed binaries: herdr 0.7.1, protocol 14, on macOS aarch64 and native Windows Git Bash.
Current real-herdr verification uses isolated `HERDR_SESSION` names plus the guarded teardown helper in `tests/herdr-test-safety.sh`.
A 2026-07-02 cleanup bug proved that `HERDR_SESSION` alone is not a safe way to target destructive session cleanup; see "Session targeting: the `--session` flag, not `HERDR_SESSION` alone" below.
All real-herdr verification in this document uses isolated sessions and guarded cleanup; the captain's default herdr session and live tmux fleet were never intended targets.

## Setup

Pick herdr when you want native per-pane agent-state detection (busy/idle/blocked) instead of tmux's regex-based guessing, and you are comfortable running an experimental backend.

Herdr is dual-licensed AGPL-3.0-or-later / commercial - see its LICENSE file (github.com/ogulcancelik/herdr) or https://herdr.dev.
Firstmate only drives the `herdr` CLI as a separate process, which carries no AGPL obligations for firstmate users.

Prerequisites:

- `herdr` itself, protocol 14 or newer (installed 0.7.1 verified) - see [herdr.dev](https://herdr.dev) for install instructions.
- `jq`, required to parse herdr's JSON output: `brew install jq` (or your platform's package manager).
- The same universal requirements as tmux (a verified crew harness, git with GitHub auth, node, treehouse, no-mistakes, gh-axi, chrome-devtools-axi, and lavish-axi); treehouse still provides the worktree, herdr only provides the session.

Select herdr by putting `herdr` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=herdr` when you launch your harness for a one-off session; telling the first mate in chat to use herdr also works.
It can also be auto-detected: when firstmate itself is running natively inside herdr (`HERDR_ENV=1`) and no explicit backend is set, firstmate auto-selects herdr and prints a one-time opt-out notice; running inside tmux nested in herdr always resolves to tmux instead.
A herdr spawn refuses loudly before creating a session container or acquiring a ship/scout worktree if `herdr` or `jq` is missing or the installed herdr's protocol is older than verified.
For `--secondmate` launches, secondmate home sync and inherited-config propagation happen before this spawn-time backend gate.

No first-run provisioning is needed beyond having `herdr` and `jq` on `PATH`; firstmate creates the workspace and tab it needs on first spawn.

Watching and attaching: each firstmate home gets its own herdr workspace (the primary uses `firstmate`; each secondmate uses `2ndmate-<secondmate-id>`), with one tab per task inside it, named `fm-<id>`.
Attach to the selected `HERDR_SESSION` and switch to the workspace for the home you want to watch to see every one of that home's tasks as tabs in one tab bar.
You do not need to attach for routine supervision: `bin/fm-peek.sh fm-<id>` reads a task's pane without attaching, and `bin/fm-send.sh fm-<id> "<text>"` steers it.

Verify it works by spawning a trivial task with `--backend herdr` and confirming the task's meta records `backend=herdr` plus `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`; the workspace for your home should show the new `fm-<id>` tab.

Limitations: herdr is experimental, not yet used for `bin/fm-bootstrap.sh`'s required-tools list (the version/tool gate happens at spawn time instead), and carries the native-Windows herdr `0.7.1-preview` recovery limitations and known gaps documented below.
See "Known herdr 0.7.1-preview limitations (native Windows)" for the fresh-session recovery guidance after server death, and "Known gaps and follow-up notes" for follow-up work such as the `pane_cwd`-adjacent worktree-discovery symlink fragility.

## Status: experimental

Herdr is experimental, exactly like every non-tmux backend in this design.
Select it by putting `herdr` in a local `config/backend` file, by exporting `FM_BACKEND=herdr`, or by telling the first mate in chat to use herdr.
It can also be selected by runtime auto-detection when firstmate itself is running inside herdr and no explicit backend setting exists.
Absent those three explicit settings, firstmate falls through to runtime auto-detection.
When nothing is explicitly configured, `bin/fm-backend.sh`'s `fm_backend_detect` checks the runtime firstmate itself is executing inside: `$TMUX` (set inside every tmux pane, including a tmux pane nested inside a herdr pane) selects tmux and wins when present, `HERDR_ENV=1` (injected into every process herdr manages a pane for) selects herdr when `$TMUX` is absent, and cmux runtime signals select cmux only after those multiplexer markers are absent.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-auto-detection) for cmux's primary `CMUX_WORKSPACE_ID` marker and macOS-only fallback signals.
An auto-detected herdr spawn prints one loud stderr notice (set `config/backend` or pass `--backend tmux` to opt out).
Auto-detecting tmux stays silent, since that reproduces today's unconfigured default byte-for-byte.
Only when none of that resolves anything does firstmate fall back to the platform default: tmux on POSIX, or herdr on Windows, since tmux is POSIX-only.
Absent `backend=` in a task's meta always means `tmux`; a herdr task carries an explicit `backend=herdr` line, while other experimental adapters carry their own backend values.
A herdr spawn refuses loudly if `herdr` or `jq` is missing, or if the installed herdr's protocol is older than the verified minimum (`fm_backend_herdr_version_check`).

## Worktree provider stays treehouse

Herdr is a session provider only.
Treehouse remains the worktree provider, exactly as it is for tmux.
Herdr's own `worktree.*` operations (branch-based, pooling/lease-free) are never used by this adapter.

## Task container shape: tab-per-task in one workspace PER FIRSTMATE HOME

Firstmate creates one herdr workspace PER FIRSTMATE HOME - the primary gets `firstmate`, each secondmate gets its own `2ndmate-<secondmate-id>` - and one TAB per task inside that home's own workspace.
This is the same "one container, one endpoint per task" shape tmux uses (one session, one window per task), refined one level: the container is now scoped per home, not shared machine-wide.

This refines, but does not reverse, P2's original decision (AGENTS.md task herdr-sm-spaces-k4).
P2 established workspace-per-TASK vs. tab-per-task-in-one-shared-workspace and picked tab-per-task on the human-watching axis (below); that axis is untouched here and workspace-per-task stays rejected.
What changed is the container's OWNER: P2 assumed a single firstmate instance per herdr session, so one shared `firstmate` workspace was enough.
With secondmates now spawning their own herdr tasks, jamming every home's tabs into that one shared workspace made a captain's tab bar an unlabeled mix of primary and secondmate work with no visual way to tell them apart.
Workspace-per-HOME fixes that while keeping tab-per-task's original human-watching win intact **within** each home: attaching to a home's own workspace (`herdr`, then switching to its space) still shows every one of *that home's* tasks as a tab in one tab bar, switchable with `ctrl+b <n>`; the ADDITIONAL win is that a captain juggling several homes on one herdr session now sees them as clearly labeled, separate spaces in herdr's spaces sidebar instead of one undifferentiated pile.

### Label derivation (stable, derived from the home itself)

`fm_backend_herdr_workspace_label` (`bin/backends/herdr.sh`) resolves the label from `$FM_HOME`, read fresh on every call rather than cached or threaded through env plumbing:

- The PRIMARY home (no `.fm-secondmate-home` marker at its root) resolves to the constant `firstmate` - byte-identical to every pre-P3 task's recorded label.
- A SECONDMATE home (carrying `.fm-secondmate-home`, written by `bin/fm-home-seed.sh` at seed time and containing exactly that secondmate's id) resolves to `2ndmate-<secondmate-id>`, e.g. `2ndmate-sshhip-h7`.

Because the label is derived from the home's own durable identity - the marker file lives at the home's root, not in an environment variable passed down a call chain - it is automatically stable across every respawn, recovery, and firstmate restart for the life of that home, with no extra bookkeeping required.
Two different secondmate homes always get two different, non-colliding labels because their marker ids are unique (verified: `tests/fm-backend-herdr.test.sh`'s `test_workspace_label_different_secondmates_get_different_labels`).

Every workspace-scoped adapter path reads this SAME resolution: find/ensure (`fm_backend_herdr_workspace_find`/`_ensure`), tab create and its duplicate-label check (`fm_backend_herdr_create_task`), list-live recovery (`fm_backend_herdr_list_live`), and pane-for-tab (`fm_backend_herdr_pane_for_tab`, via the workspace id these resolve).
So a secondmate's own recovery/duplicate-check calls are automatically scoped to its own space and never see (or collide with) the primary's or a sibling secondmate's tabs.

### The one wrinkle: a `--secondmate` spawn is launched BY the primary

For every other spawn kind, `$FM_HOME` at spawn time already names the right home: the primary spawning its own crewmate/scout, or a secondmate spawning a crewmate/scout FROM ITS OWN `fm-spawn.sh` process (its own `$FM_HOME` already IS that secondmate's home).
The one exception is `bin/fm-spawn.sh <id> <secondmate-home> --secondmate`: this command runs IN THE PRIMARY's own process, so the primary's OWN `$FM_HOME` is what the label-resolution helpers would see by default, even though the tab being created belongs to the SECONDMATE.
`fm-spawn.sh`'s herdr case arm handles this with a narrow, targeted shadow: it computes `HERDR_LABEL_HOME` (the secondmate's own home, `PROJ_ABS`, for `KIND = secondmate`; the process's own `$FM_HOME` otherwise) and passes it as a bash temporary-assignment prefix - `FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure ...` and `FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task ...` - which scopes the override to exactly those two calls and is automatically restored afterward (verified: bash's temporary-assignment-before-a-simple-command form applies for the duration of a shell FUNCTION call too, not only external commands).
Nothing else in `fm-spawn.sh` reads `$FM_HOME` again after this point, so no explicit restore is needed.

Every other backend-scoped call site needs no such glue: it already runs inside a process whose own `$FM_HOME` correctly names the home doing the work.
This includes the previously-unexercised path of a crewmate spawned FROM a secondmate's own `fm-spawn.sh` - proven end to end in `tests/fm-backend-herdr-workspace-per-home-e2e.test.sh`, not merely by code inspection (see "End-to-end verification" below).

### Focus behavior: never steals the captain's attention

Verified empirically against the real binary, in an isolated session:

- `herdr workspace create` and `herdr tab create` do NOT focus by default once at least one workspace already exists in the session - matching (and no worse than) the pre-P3 adapter's already-flagless calls.
- The ONE exception: the very first workspace ever created in a brand-new, empty herdr session focuses regardless, because herdr always needs something focused to attach a client to - there is nothing to "not steal focus from" at that point.
- `--focus` reliably DOES focus (both the workspace and, for a tab, the pane within it) - confirming the flag has real effect and isn't a no-op, so its absence is meaningful.

Both `fm_backend_herdr_workspace_ensure`'s workspace create and `fm_backend_herdr_create_task`'s tab create now pass `--no-focus` unconditionally.
This is defense in depth rather than a behavior change in the already-safe steady state: it guards workspace and tab creation after the session already has a focused workspace, but it cannot prevent herdr's unavoidable first-workspace focus in a brand-new empty session.
Once a workspace exists, spawning - primary or secondmate, workspace or tab - should not switch whatever space the captain is actively watching.

### Task tab shell seed: so the pane handoff actually runs

`fm_backend_herdr_create_task` seeds each new task tab with an explicit `--env SHELL=<shell>` and, on native Windows, explicitly starts Git Bash in the pane after `tab create`.
Without a real shell, the `treehouse get` handoff text `fm-spawn.sh` sends into the pane never executes, the worktree subshell never lands, and the spawn hangs - a gating bug for firstmate running its crew on herdr.
On POSIX, `fm_backend_herdr_shell_arg` still resolves the shell from `$SHELL`, falling back to `bash` then `sh` via `command -v`.
On Windows, `fm_backend_herdr_shell_arg` ignores an inherited `$SHELL` and resolves native Git Bash with `command -v bash`, then converts it with `cygpath -w -s` so the path is Windows-native and space-free (see "Native Windows path handling" below).
The `--env SHELL=...` flag is added ONLY when a shell actually resolves - if none does, the tab-create call is byte-identical to before.
This is herdr-backend-only: the shared/tmux spawn path in `fm-spawn.sh` is untouched, so the tmux/Linux/macOS path is unchanged.
Covered by `tests/fm-backend-herdr.test.sh`'s `test_create_task_passes_explicit_shell_env` and `test_windows_create_task_converts_shell_env_for_tab_create`, plus `tests/fm-backend-herdr-handoff.test.sh`'s handoff regression.

### Label collisions: adopt-don't-duplicate, unchanged in spirit

Herdr enforces NO label uniqueness at all for either workspaces or tabs (re-verified for workspaces specifically in this pass: creating a second workspace with an already-used label succeeds and produces two workspaces sharing that label).
`fm_backend_herdr_workspace_find` therefore adopts the FIRST matching workspace `jq` returns for a home's own label - in practice list order, normally creation order / the oldest - rather than attempting to disambiguate; this mirrors the pre-existing tab duplicate-label check in `fm_backend_herdr_create_task` (which still refuses an exact duplicate TAB label within the adopted workspace).
Practical consequence: if a user manually creates their own herdr workspace that happens to share a firstmate home's label (`firstmate`, or `2ndmate-<some-id>`), firstmate's next spawn silently ADOPTS that pre-existing workspace as if it were its own, rather than creating a second one or refusing.
This is a pre-existing characteristic of the adapter's find-before-create pattern, not a new risk introduced by the per-home refinement; avoid naming a personal herdr workspace `firstmate` or `2ndmate-<secondmate-id>` if you want to keep it separate from firstmate's own space.

### No forced migration

Existing live tasks are unaffected by this change: a task's meta already records its own `window=`/`herdr_pane_id=` target, which every backend-scoped operation (send/capture/kill/busy-state) resolves directly and never re-derives from a workspace label.
So a task spawned before this pass keeps working exactly as before, from whatever workspace it already lives in (the old shared `firstmate` workspace, or a pre-rename `firstmate-<secondmate-id>` workspace if that is where its home's tasks previously landed).
New workspace lookup does not adopt old secondmate labels: for new spawns, recovery, and list-live, the adapter exact-matches the current label derived from `FM_HOME` (`2ndmate-<secondmate-id>`).
If an older live workspace is still labeled `firstmate-<secondmate-id>`, rename it with `herdr workspace rename <workspace_id> 2ndmate-<secondmate-id>` before expecting new tasks or recovery/list-live to use that workspace.

Tab-per-task (within each home's own workspace) still wins on the human-watching axis for the reason P2 originally found: attaching once shows every one of that home's tasks as a tab in one tab bar, switchable with `ctrl+b <n>`, matching how a captain already watches a tmux-backed fleet.
Workspace-per-task - tried against the real binary in P2 and again considered here - would still only show one task's workspace at a time by default, requiring a separate top-level "space" switch to see the rest of even a single home's fleet; that tradeoff is unchanged by the per-home refinement and workspace-per-task remains rejected.

## Workspace lifecycle: one persistent per-home workspace, reused

Each home's own workspace (`firstmate` for the primary, `2ndmate-<secondmate-id>` for a secondmate - see "Label derivation" above) is created once per session and reused by every subsequent spawn from that home: `fm_backend_herdr_workspace_ensure` calls `fm_backend_herdr_workspace_find` first and creates a workspace only when none labelled for that home exists yet.
Teardown (`fm_backend_herdr_kill`) closes only the task's pane/tab, never the workspace.

Reserved-keyword guard: never name a `jq --arg`/`--argjson` after a `jq` keyword (`label`, `and`, `or`, `not`, `if`, `then`, `else`, `end`, `reduce`, `foreach`, `import`, `def`, `as`, `__loc__`).
jq <= 1.6 rejects a keyword-named `$`-variable as a compile error, and this adapter pipes `jq`'s stderr to `/dev/null`, so on jq <= 1.6 the error silently becomes an empty result rather than a visible failure.
Use a distinct name such as `$want` instead; `tests/fm-backend-herdr.test.sh` greps `bin/` for this pattern so a new violation fails loudly rather than silently.

### Default-tab prune

`herdr workspace create` seeds the new workspace with one auto-created default tab (label `1`) that firstmate never uses.
`fm_backend_herdr_create_task` prunes it (best-effort, via `fm_backend_herdr_workspace_prune_seeded_default_tab`) right after creating the first real task tab in a freshly created workspace, never earlier: closing a workspace's LAST tab deletes the whole workspace on real herdr, and immediately after creation the default tab is the only one present.

**The prune target is identified structurally (created-vs-adopted), never by label pattern.**
`fm_backend_herdr_workspace_ensure` captures the seeded default tab's `tab_id` straight from its OWN `workspace create` response (`.result.tab.tab_id`, verified empirically to be present on the same response as `.result.workspace.workspace_id` - no follow-up `tab list` call is needed) ONLY when that call itself just created the workspace.
`fm_backend_herdr_container_ensure` threads that id through to its caller as a second field: it echoes `"<session>:<workspace_id>\t<seeded_default_tab_id>"`, the second field empty whenever the workspace was ADOPTED (`fm_backend_herdr_workspace_find` matched a pre-existing workspace by label) rather than created fresh.
`fm_backend_herdr_create_task` accepts that value as an explicit 4th argument and is the ONLY place allowed to act on it; it never re-derives "prunable" from a tab's label or the workspace's tab count.
An adopted workspace's caller always passes an empty 4th argument, so create_task never even looks for a prune candidate in that case - it is structurally impossible for an adopted workspace's tabs to be pruned, regardless of how they are labeled.

Defense in depth on top of that gate (not the primary safety mechanism): before closing the seeded tab, `fm_backend_herdr_workspace_prune_seeded_default_tab` re-verifies the tab is still present, re-checks it is still labeled `1`, and refuses if its pane's `agent get` reports `agent_status: working` (herdr's own native agent-state detection) - belt-and-suspenders against a live agent having landed there through some other path.

#### Incident: the 2026-07-02 self-kill

The previous implementation derived "prunable" at `create_task` time from a pure label heuristic run against whatever workspace `workspace_find` had just resolved: exactly one tab, labeled `1`.
Herdr enforces no label uniqueness (see "Label collisions" above) and derives an unlabeled workspace's DISPLAYED label from its pane cwd's basename.
A captain who launches herdr directly inside a directory named `firstmate` therefore gets a workspace whose label is `firstmate` - byte-identical, by coincidence, to the primary firstmate home's own derived label - with a single auto-created tab, also labeled `1`.
`fm_backend_herdr_workspace_find` adopted that pre-existing, captain-owned, LIVE workspace by the label match (a label match can never distinguish an explicitly `--label`-created workspace from one whose label only coincidentally matches); the old heuristic matched too, since it looked only at the adopted workspace's own tab shape, not at whether THIS spawn had actually created it.
The very next crewmate spawn's `create_task` call closed the captain's own live pane roughly 27ms after creating its own task tab, killing the primary firstmate agent and its watcher mid-turn.
Log evidence: `~/.config/herdr/herdr-server.log` showed `cli:tab:create` (the new task tab) immediately followed by `cli:pane:close` on the captain's pane (pid 36335, launched ~8 minutes earlier); `~/.config/herdr/session.json` showed the adopted workspace's `custom_name: null` with `identity_cwd` pointing at the firstmate repo.

The fix is structural, not another heuristic, and is unit- and E2E-tested: see `tests/fm-backend-herdr.test.sh`'s `test_adopted_workspace_never_prunes_default_tab` and `test_label_collision_startup_workspace_leaves_live_tab_alone`, and `tests/fm-backend-herdr-prune-safety-e2e.test.sh`'s isolated real-herdr reproduction of the exact incident shape.

Because closing a workspace's last tab deletes it, a home's workspace does not outlive a fully idle fleet (zero live tasks for that home) - the next spawn's `workspace_find` simply finds nothing and recreates it. Reuse holds across concurrent and sequential tasks; it is not a guarantee that the workspace itself survives the whole session unconditionally.

A workspace whose label this adapter did not derive (see "Label derivation" above) is never adopted, reused, or torn down by firstmate - `fm_backend_herdr_workspace_find` and `fm_backend_herdr_list_live` only ever match a home's own derived label.

## Target string and meta fields

A herdr task's `window=` meta field holds `<herdr-session>:<pane-id>`, for example `default:w1:p2`.
The pane id itself contains a colon, so the adapter splits on the FIRST colon only, never on every colon.
This mirrors tmux's `session:window` target shape closely enough that normal task-id resolution still returns a task's recorded `window=` value verbatim.
Operational commands should prefer a task selector, either `fm-<id>` or the exact `<id>`, which resolves through this home's metadata.
`fm-send.sh` deliberately refuses unresolved guesses: a raw `herdr_pane_id` without its session prefix is rejected with a hint, an unresolved `fm-<id>` is rejected, and an unrecorded explicit target must be well-formed and live before any key or text is sent.
An explicit herdr target also works when it exactly matches recorded metadata, or when a live unrecorded endpoint is intentionally targeted as an escape hatch outside this firstmate home.

Herdr tasks additionally record:

- `herdr_session=` - the named herdr session this task's server lives in.
- `herdr_workspace_id=` - the id of the workspace belonging to the home that spawned this task (the primary's `firstmate` workspace, or a secondmate's own `2ndmate-<id>` workspace; for reference - not needed for day-to-day operations, which re-derive it from the target string).
- `herdr_tab_id=` - the task's tab id.
- `herdr_pane_id=` - the task's pane id, the fast-path operational target.

## Verified CLI facts

| Operation | Verified herdr call | What was verified |
|---|---|---|
| Version/protocol gate | `herdr status --json` -> `.client.protocol` | Session-independent; `.server.*` fields ARE session-dependent. |
| Headless server start | `HERDR_SESSION=<name> herdr server --session <name>` (backgrounded on POSIX; `nohup`-detached on native Windows - see "Native Windows path handling" below) | A bare socket call does NOT auto-start the server; the adapter always starts-then-polls before any workspace/tab/pane call. This fact is for start only, not cleanup, and the explicit `--session` flag is intentional because `HERDR_SESSION` alone is not safe session targeting. |
| Duplicate task check | `herdr tab list --workspace <id>`, match by `.label` | Herdr does NOT enforce tab-label uniqueness itself; two tabs can share a label. The adapter's own duplicate check is required. |
| Send literal (unsubmitted) | `herdr pane send-text <pane> <text>` | Does NOT auto-submit, contrary to the original design addendum's guess. Verified directly: a unique marker sent this way sits unexecuted in the composer until a separate Enter. Behaves exactly like tmux's `send-keys -l`. |
| Send + submit atomically | `herdr pane run <pane> <command>` | Runs and submits a command in one call; used for the fixed spawn-time commands (`treehouse get`, the `GOTMPDIR` export) exactly where tmux used one `send-keys ... Enter` call. |
| Send key | `herdr --session <session> pane send-keys <pane> <key>` | Verified names: `enter`, `escape` (alias `esc`), `ctrl+c` (aliases `C-c`, `c-c`). `ctrl+c` verified to interrupt a running foreground process immediately. The `--session` flag must be before `pane send-keys` because `send-keys` has a variadic key tail; a trailing `--session` is consumed as another key token instead of a global selector. |
| Bounded capture | `herdr pane read <pane> --source recent --lines N` | See "Verified bug" below - N is never passed through directly. |
| Busy state | `herdr agent get <pane>` -> `.result.agent.agent_status` | Verified live against an interactive `claude` session: reports `working` while generating, `done` once idle. Mapped: `working` -> busy; `idle`/`done` -> idle; `blocked` -> idle (surfaced like a stale pane, not suppressed as busy - a blocked agent is stuck waiting on the human, not grinding); anything else -> unknown (the cue for the shared tail-regex fallback). |
| Kill | `herdr pane close <pane>` | Closing a tab's only (root) pane also closes the tab - no separate tab-close call needed for this adapter's one-pane-per-tab shape. Best-effort: closing an already-closed pane exits non-zero, matching tmux's `kill-window \|\| true` contract. Teardown itself only ever closes the task's own pane/tab, never the workspace - but closing a workspace's LAST tab (verified real-herdr behavior) deletes the workspace as a side effect, so a home's own workspace persists only while at least one task tab remains; see "Workspace lifecycle" above. |
| Default-tab prune (create_task, first task in a fresh workspace only) | `herdr workspace create`'s own response (`.result.tab.tab_id`) identifies the seeded tab; `herdr tab list` + `herdr agent get <pane>` re-verify it; `herdr pane close <pane>` closes exactly that tab id | `herdr workspace create` seeds the new workspace with one auto-created default tab (label `1`, id captured straight from the create response) firstmate never uses. `fm_backend_herdr_create_task` closes EXACTLY that captured tab id right after creating the first real task tab in a freshly created workspace - never right after `workspace create` itself (see Kill row), and never re-derived from a tab's label or the workspace's tab count at create_task time (see "Default-tab prune" above for the created-vs-adopted safety gate and the 2026-07-02 incident it fixes). Best-effort; an ADOPTED workspace (not freshly created by this same call) is never a prune candidate at all. |
| Recovery / list-live | `herdr tab list --workspace <id>`, filter labels starting with `fm-` | Label-based, never trusts a stored id blindly - see "ID stability" below. `<id>` is always THIS home's own workspace (`fm_backend_herdr_workspace_find`), so recovery never sees a sibling home's tabs. |
| Workspace create / tab create (focus) | `herdr workspace create --no-focus`, `herdr tab create --no-focus` | Verified: neither focuses by default once a workspace already exists in the session, matching pre-P3 (flagless) behavior; `--no-focus` is passed anyway for defense in depth, since the very first workspace ever created in a brand-new session focuses regardless of the flag. `--focus` was separately verified to reliably focus, confirming the flag has real effect. |
| Session targeting for DESTRUCTIVE calls | `herdr session stop <name> --session <name> --json`, then `herdr session delete <name> --session <name> --json`; never `herdr server stop` | Used by native-Windows adapter teardown only after the scoped workspace count reaches zero, and by `tests/herdr-test-safety.sh`, which re-queries `herdr session list --json` before every destructive test cleanup call. See "Session targeting" below - `HERDR_SESSION` alone is not reliably honored once another herdr server is already running on the machine. |

## Verified bug: `pane read --lines N` returns empty for small N

This was the most significant finding of this verification pass.

`herdr pane read <pane> --source recent --lines N` returns **completely empty output** when `N` is smaller than the pane's current viewport height, instead of clamping to the last `N` lines.
Reproduced deterministically by binary search against a 23-row pane: `--lines 5/6/8/15` all returned zero bytes; `--lines 20` returned a partial read; `--lines 24` and above returned the full expected content, correctly clamping down even at `--lines 1000`.

This silently broke exactly the small bounded reads the adapter needs most - the composer-state guard and fallback reads used around submit and injection, and would have affected any small `fm-peek.sh` line count too.
Before the workaround, an early version of the real-herdr smoke test flaked intermittently for exactly this reason.

**Workaround:** `fm_backend_herdr_capture` never passes a caller's small requested line count straight through to herdr's own `--lines` flag.
It always requests a generous floor (>= 200 lines, comfortably above any realistic pane viewport) from herdr, then trims to the caller's actual requested bound locally with `tail -n N`.
Verified this eliminates the flake across repeated full smoke-test runs.

## Verified gap: `agent.get` reads idle during a long foreground tool call

`herdr agent get <pane>` -> `.result.agent.agent_status` was verified against a short interactive `claude` exchange (see "Busy state" above): `working` while the model streams a turn, `done` once it stops.
That verification did not cover a crew blocked on its OWN long-running foreground tool call - e.g. `no-mistakes axi run` without `--yes`, which blocks synchronously for the whole pipeline (minutes to tens of minutes) until a gate or outcome, per `AGENTS.md` section 11.
For that entire span the model is not generating - it already finished the turn that invoked the tool and is waiting on the tool's result - so `agent_status` reads `idle` (or `blocked`, which the adapter also maps to `idle`), even though the pane's own rendered text keeps showing the harness's busy banner (`BUSY_REGEX`, e.g. `esc to interrupt`) the whole time, exactly as it would in a plain tmux pane.

This surfaced as a real fleet incident (2026-07-02): `bin/fm-watch.sh`'s absorb-only-when-provably-working stale path (`AGENTS.md` section 8) treated a herdr `idle` verdict from `crew_pane_is_busy` as final, so it skipped the shared tail-regex corroboration that `unknown` already got.
At the same time, an independent no-mistakes run-step attribution fallback could miss this crew's branch when `axi status` reported another branch; current `bin/fm-crew-state.sh` falls back to top-level `no-mistakes runs --limit ${FM_CREW_STATE_RUNS_LIMIT:-200}` for that coarse cross-branch verdict.
Together, those gaps let a genuinely still-working herdr crew read as not provably working, triggering an immediate stale wake instead of the intended absorb-then-escalate behavior.

**Fix:** `bin/fm-crew-state.sh`'s `crew_pane_is_busy` now corroborates BOTH `idle` and unknown/unparseable native verdicts with the shared tail-regex before concluding "not busy" - only a bare `busy` verdict is trusted outright.
The cross-branch attribution fallback now uses the real `no-mistakes runs` command, and the watcher checks provably-working evidence before a stale status-log verb can make a stale pane terminal.
This does not mask a genuinely human-blocked agent (a permission dialog, not mid-tool-call): that pane does not render the busy banner, so the corroboration still correctly reports not-busy for it.

## Slash/`$` autocomplete popup hazard (confirmed, same mitigation as tmux)

Typing `/mem` into a live `claude` composer inside a herdr pane and reading the pane back within 0.1 seconds already shows the full autocomplete popup.
This confirms the same hazard tmux already mitigates: submitting immediately after a `/`- or `$`-prefixed send risks Enter landing on a popup selection instead of the literal typed command.
On herdr, `fm_backend_herdr_send_text_submit` takes the same settle-before-first-Enter parameter tmux's submit core does.
Both POSIX and native Windows type text literally with `pane send-text`, then submit with a named Enter key and confirm the result as described in "Native agent-state submit confirmation" below.
The settle-duration DECISION itself lives in `fm-send.sh` (harness-aware, backend-independent), so the backend adapter does not own that policy.

`escape` was verified to dismiss the popup while leaving the typed text in the composer, not a full clear.

## Incident (2026-07-03): a slash command left fully typed but unsubmitted, silently

Two grok/herdr crewmates were each sent `/no-mistakes` via `fm-send.sh`.
In both panes the command sat fully typed in the composer, unsubmitted (footer still read `Enter:send`), for minutes, until a manual `fm-send.sh <target> --key Enter` landed it instantly.
`fm-send.sh` had exited 0 both times - no failure surfaced to the caller.

Root cause, reproduced live against real grok 0.2.82 on an isolated herdr session: the send-text-submit verification at the time used the old delta-based strategy and declared success whenever the captured pane content changed AT ALL between before and after an Enter.
For an argument-taking slash command, the FIRST Enter does not submit - it closes the completion popup and, for a command like `/compact [context]`, EXPANDS the composer text into an argument-hint placeholder (`/compact` -> `/compact compaction instructions`).
The popup disappearing and the composer text changing is a real, visible content change, so the old delta check declared "submitted" after exactly one Enter, even though the composer still held real, unsubmitted text and the footer still read `Enter:send`.
A genuine second Enter was required to actually submit - exactly the manual recovery that worked both times in the incident.
Plain (non-argument) commands like `/new` did submit on the first Enter in the same live test, so the false-positive was specific to commands whose popup selection fills an argument placeholder rather than submitting outright - `/no-mistakes` (optional task-first argument) is exactly that shape.

The tmux backend was NOT affected by this incident: `fm_tmux_composer_state` reads the actual cursor row and classifies it as pending whenever real text remains, so its retry loop correctly issued the second Enter and landed the same live repro; this was confirmed side-by-side against the same real grok pane.

**Fix:** `fm_backend_herdr_composer_state` replaces the delta-based check with a structural read of the composer's OWN row, mirroring what the cursor-row read gives tmux where herdr needs composer confirmation.
Herdr's CLI exposes no cursor-row primitive, so the composer row is located by shape instead of position: the bordered shape is a line in a generous tail capture whose trimmed content both starts and ends with the same border glyph (`│`, `┃`, or a plain `|`), and the bare shape is an unbordered line beginning with a verified agent prompt glyph (`❯` for claude or `›` for codex).
The scan keeps the last matching row so a stale decorative box earlier in scrollback cannot outrank the live bottom-anchored composer.
A popup-close-with-placeholder-fill still reads as real content on that row, so fallback composer confirmation classifies it as pending and the retry loop sends the required second Enter, instead of stopping early.
Known ghost/placeholder composer text (`Type a message...`, verified grok 0.2.82's empty-composer hint), ANSI-faint bare-prompt tails, and native-Windows Codex rotating idle suggestions are recognized and still read as empty.
`FM_BACKEND_HERDR_IDLE_RE`, `FM_BACKEND_HERDR_CODEX_IDLE_RE`, `FM_BACKEND_HERDR_BARE_PROMPT_RE`, and `FM_BACKEND_HERDR_COMPOSER_LINES` tune those checks and are documented in [`docs/configuration.md`](configuration.md).
See `fm_backend_herdr_composer_state` and `fm_backend_herdr_send_text_submit` in `bin/backends/herdr.sh` for the implementation, and `tests/fm-backend-herdr.test.sh`'s composer-state and send-text-submit sections (including a dedicated regression test asserting the second Enter is actually sent) for the fake-harness coverage.

## Native agent-state submit confirmation

The herdr adapter's submit-verification no longer diffs raw pane content before/after Enter (see the incident above for why that was unsafe).
It now types text once with `pane send-text`, records the pre-Enter native `agent_status`, sends Enter, and treats an idle-baseline transition to submit-active `working` or `blocked` as confirmation that a real turn started.
If the baseline was already non-idle, or if an idle baseline stays idle/done after Enter, the adapter falls back to the ANSI-aware composer classifier described above.
That fallback is what catches popup selection fills, fast turns that have already reached `done`, and positive swallowed-Enter cases without retyping the message.
`FM_BACKEND_HERDR_SUBMIT_POLLS` and `FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP` control the native agent-state confirmation window; both are documented in [`docs/configuration.md`](configuration.md).
An unreadable native agent-state read returns `unknown` rather than retrying blindly, because an inconclusive send is safer than repeated Enters against an unreadable target.
A dedicated composer-state or cursor-row read primitive is still a candidate upstream Herdr feature request; it would simplify the fallback path, but normal idle-baseline submits already use herdr's native agent-state API as the primary confirmation signal.

All implemented backends expose the identical caller-facing verdict vocabulary (`empty`, `pending`, `unknown`, `send-failed`), so `fm-send.sh` needs no backend-specific branching at all.

## Session targeting: the `--session` flag, not `HERDR_SESSION` alone

`HERDR_SESSION=<name>` is still set for the adapter's NON-destructive operations: start, workspace, tab, pane, capture, send, and busy-state calls.
Most of those calls use `fm_backend_herdr_cli`; `pane send-keys` uses `fm_backend_herdr_cli_leading_session` because its positional key tail is variadic.

Destructive session cleanup is different, and this distinction was learned the hard way.
Verified empirically: on the installed herdr 0.7.1 client, neither an exported `HERDR_SESSION` nor an inline `HERDR_SESSION="$name"` prefix reliably targets a CLI subcommand once ANOTHER herdr server (e.g. the captain's live default session) is already bound on the machine - the client silently falls back to whatever server IS running instead of the requested one.
This is not a hypothetical: it killed the captain's live default herdr server, twice, from real-herdr test cleanup that relied on exactly this assumption (2026-07-02; see `tests/herdr-test-safety.sh`'s header for the full account).
`herdr server stop` is the sharpest edge of this, because it takes NO target argument at all - it always acts on "whatever server is running," resolved ambiently, with no positional name to catch a misroute.

The fix, verified against the real binary in an isolated session (both a genuinely separate isolated session and the default session's untouched state confirmed before and after):

- The `--session <name>` GLOBAL FLAG reliably routes the non-variadic herdr subcommands tried (`status`, `workspace *`, `tab *`, `pane *`, `agent *`, `server`, `session stop`/`delete`) to the named session, in either leading (`herdr --session <name> <subcommand>`) or trailing (`herdr <subcommand> ... --session <name>`) position.
- `bin/backends/herdr.sh`'s `fm_backend_herdr_cli` helper wraps most herdr invocations in the adapter: it sets `HERDR_SESSION` (kept for cosmetic/forward-compat reasons - harmless, and it is what the client's own JSON echoes back) AND appends a trailing `--session <name>`, so those adapter calls are correctly scoped regardless of what else is running on the machine.
- `fm_backend_herdr_cli_leading_session` is the exception for `pane send-keys`, whose variadic key tail consumes a trailing `--session` as another key token; it still sets `HERDR_SESSION`, but places `--session <name>` before the subcommand.
- For destructive test cleanup specifically, use `herdr session stop <name>` / `herdr session delete <name>` (the explicit-by-name forms - `<name>` is a REQUIRED positional argument, so herdr cannot resolve it ambiguously; herdr's own help text requires literally typing `default` to affect the default session), never the ambient `herdr server stop`. `tests/herdr-test-safety.sh`'s `herdr_safe_stop_and_delete` does this, plus a read-only hard guard (`herdr_refuse_if_default`, re-querying `herdr session list --json` immediately before EVERY stop/delete call, refusing on a literal `default` name, a not-found name, or `default:true`) as a second, independent layer - fails closed on any ambiguity.
- For native-Windows production teardown specifically, `fm_backend_herdr_release_session_if_empty` may use the same explicit stop/delete calls only after `fm_backend_herdr_workspace_count` proves the named session has zero workspaces.
  That guarded path then reaps only a matching `herdr.exe server --session <same-name>` process if herdr leaves one behind.
  It must never release the firstmate process's own ambient herdr session (`HERDR_SESSION`, or `default` when unset), even if a transient `workspace list` result would make that shared session look empty.
  That self-session guard preserves the Windows leak fix for genuinely dedicated sessions while making firstmate unable to stop, delete, or force-kill the shared server it is running inside.

2026-07-08 native-Windows verification, herdr 0.7.1-preview.2026-06-30-3459798b606d:

- With a shared session containing two workspaces (`firstmate` and `crewmate`) and two live agent panes, `HERDR_SESSION=<shared> FM_PLATFORM_IS_WINDOWS=yes fm_backend_herdr_release_session_if_empty <shared>` left the shared server running, kept exactly one matching `herdr.exe server --session <shared>` process, and left the firstmate pane addressable and readable.
- With a separate empty dedicated session, `HERDR_SESSION=<shared> FM_PLATFORM_IS_WINDOWS=yes fm_backend_herdr_release_session_if_empty <dedicated>` stopped/deleted/reaped that dedicated session, leaving zero matching `herdr.exe server --session <dedicated>` processes.
- The verification cleaned its throwaway sessions and restored the host's `herdr.exe` process count to the pre-test baseline.
  Full command output is recorded in `docs/herdr-release-self-session-guard-f6-live.txt`.

## ID stability across a server restart

The original design addendum flagged this as an open risk to verify.
It turned out better than feared.

`herdr session stop <name>` followed by a fresh `herdr server --session <name>` - the realistic "firstmate restarted, herdr server needs reattaching" recovery scenario - preserves workspace id, tab id, pane id, and every label exactly.
Herdr persists this metadata to disk per named session, independent of the live server process.
What does NOT survive is the underlying shell/agent process inside each pane (a fresh shell starts in its place) and each pane's live `agent_status` (resets to unknown).

P2 verified this in the single-workspace shape only.
Re-verified here in the MULTI-workspace shape (P3, workspace-per-home): with two coexisting workspaces (a `firstmate` and a `2ndmate-<secondmate-id>`, each with its own tab/pane) in one isolated session, a `session stop` + fresh server restart preserved BOTH workspaces' ids and labels, and BOTH tasks' pane ids, exactly - automated in `tests/fm-backend-herdr-smoke.test.sh`'s restart-stability section.

Practical consequence: a stored `herdr_pane_id=` remains a valid, fast-path operational target across an ordinary server restart within the same named session, regardless of how many other homes' workspaces coexist in that session.
The adapter still implements label-based recovery (`fm_backend_herdr_list_live`), both for a differently-configured or freshly-created session where old ids would not exist at all, and as the more defensive default in general.

## Respawn idempotency: a restored task tab is a husk, not a duplicate

A restart's other consequence (the previous section's "what does NOT survive") used to make every fleet respawn after it a manual chore: a restored `fm-<id>` tab comes back alive but with a fresh shell process and no registered agent (`agent_status` reset to unknown, `agent get` reporting `agent_not_found`) - or, if the pane's own process failed to restart at all, structurally gone (`pane get` reporting `pane_not_found`).
Before this fix, `fm_backend_herdr_create_task`'s duplicate-label guard treated either shape identically to a genuinely live duplicate and refused unconditionally, so recovering a fleet after a real herdr server restart (or, worse, a full reboot) meant closing every husk pane by hand before firstmate could spawn into it again - this reproduced in production on 2026-07-03.

The guard is now husk-aware.
`fm_backend_herdr_pane_agent_state` classifies an existing same-labeled tab's pane as one of `dead` (`pane get` -> `pane_not_found`), `no-agent` (the pane exists but `agent get` -> `agent_not_found` - the restored-plain-shell shape, and also what a future `resume_agents_on_restore = false` herdr config would produce unconditionally), `live` (a real registered `agent_status`, including idle/blocked - never just "working"), or `unknown` (anything unparseable or unexpected).
Only `dead` and `no-agent` are treated as a husk; `live` and `unknown` both refuse exactly as before, fail-safe toward refusal whenever the state cannot be classified with confidence.
A confirmed husk is closed and replaced instead of refused: `fm_backend_herdr_create_task` always creates the REPLACEMENT tab first, closes the preexisting husk tab by id only after that succeeds, and verifies no same-labeled tab except the replacement remains before returning success.
It never closes the husk first, because closing a workspace's last remaining tab deletes the whole workspace on real herdr (see "Workspace lifecycle" above) and a session-restore husk can legitimately be that workspace's only tab.
This is the identical create-before-close safety argument `fm_backend_herdr_workspace_prune_seeded_default_tab` already established for the seeded default tab.

Verified against the real binary (`tests/fm-backend-herdr-respawn-idem-e2e.test.sh`, an isolated non-default session): a real `session stop` + fresh `herdr server` restart, followed by a same-labeled `fm_backend_herdr_create_task` call, closes and replaces the restored no-agent husk for both a crewmate/scout-shaped and a `--secondmate`-shaped task (the same function serves both spawn paths), while a pane carrying a genuinely registered agent (via herdr's own `pane report-agent`) still refuses.
The `dead` (`pane_not_found`) classification is covered at the unit level (`tests/fm-backend-herdr.test.sh`, canned-response fake) but not end-to-end against the real binary: killing a pane's underlying process on a live server was observed to make herdr immediately reap both the pane AND its tab together (so the tab never lingers in `tab list` for the duplicate check to even find), and a session restart was never observed to produce a structurally-dead-but-still-listed pane either - only a live, agent-less one.
The `dead` branch remains a conservative, defensively-coded path for a herdr failure mode (e.g. a restored process that fails to start) that has not been reproduced against the real binary.

## End-to-end verification (spawn -> steer -> peek -> done -> merge -> teardown)

Beyond the fake-CLI unit tests (`tests/fm-backend-herdr.test.sh`) and the real-CLI smoke tests (`tests/fm-backend-herdr-smoke.test.sh` and `tests/fm-backend-autodetect-smoke.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME`, a scratch `local-only` git project, and an isolated `HERDR_SESSION`:

1. `FM_HOME=<scratch> FM_BACKEND=herdr HERDR_SESSION=<isolated> bin/fm-spawn.sh herdr-e2e-t1 projects/scratch-e2e-project claude` - spawned successfully, printing `backend=herdr` in the summary and writing `herdr_session=`/`herdr_workspace_id=`/`herdr_tab_id=`/`herdr_pane_id=` to the task's meta.
2. `bin/fm-peek.sh fm-herdr-e2e-t1` - showed the live claude trust dialog.
3. `bin/fm-send.sh fm-herdr-e2e-t1 --key Enter` - accepted the trust dialog.
4. `bin/fm-peek.sh fm-herdr-e2e-t1` again - showed claude actively working through the brief (creating the branch, writing the file).
5. `bin/fm-send.sh fm-herdr-e2e-t1 "captain says: proceed as planned"` - a plain-text steer, exercising the send-and-verify path; the text appeared correctly in the pane.
6. The crewmate appended `done: hello.txt committed on fm/herdr-e2e-t1` to its status file, and its commit (`add hello.txt` on branch `fm/herdr-e2e-t1`) was confirmed present in the project's git history.
7. `bin/fm-teardown.sh herdr-e2e-t1` **REFUSED**, exactly as required: `REFUSED: local-only worktree ... has work not yet merged into main and not on any remote.`
8. `bin/fm-merge-local.sh herdr-e2e-t1` - fast-forwarded local `main` to the crewmate's commit.
9. `bin/fm-teardown.sh herdr-e2e-t1` now succeeded: returned the treehouse worktree, closed the herdr pane (verified gone via `herdr pane get`), and removed all of the task's `state/` files.

Two real, non-obvious bugs were caught and fixed by this pass alone, both already reflected above and in `bin/backends/herdr.sh`:

- The `pane read --lines N` small-N bug (see above) - without the fix, this E2E run flaked intermittently on the very first `send_text_line` call.
- `pane get`'s `.result.pane.cwd` field is frozen at pane-creation time and never updates; `fm_backend_herdr_current_path` originally read it and would have made `fm-spawn.sh`'s worktree-discovery poll misresolve the acquired treehouse worktree path (it would see the pane's ORIGINAL directory, not where `treehouse get`'s subshell actually landed) - fixed by reading `.result.pane.foreground_cwd` instead, which tracks the live running process.

The isolated herdr session, the treehouse pool worktree, and the scratch `FM_HOME` were all stopped/deleted/removed after this run, using the guarded teardown described in "Session targeting" above; the captain's default herdr session and the live tmux fleet were never touched at any point.

## End-to-end verification: workspace-per-home (P3)

`tests/fm-backend-herdr-workspace-per-home-e2e.test.sh` drives `bin/fm-spawn.sh` and `bin/fm-teardown.sh` for real, in a scratch `TMP_ROOT` holding two scratch firstmate homes (a primary-shaped one with no marker, and a secondmate-shaped one carrying `.fm-secondmate-home`) and two scratch local-only projects, on one isolated `HERDR_SESSION` (never the captain's default), with the same `herdr_safe_stop_and_delete` guarded cleanup.
This exercises the fm-spawn.sh-level behavior the adapter-primitive smoke test cannot reach: the label-resolution home-shadowing for a `--secondmate` spawn, and - the one path that had never run before this test - a crewmate spawned FROM a secondmate's own `fm-spawn.sh` process.

1. A primary-shaped home spawns an ordinary crewmate (`cm1`) on the herdr backend: its tab lands in a workspace herdr itself labels `firstmate`.
2. The PRIMARY spawns a `--secondmate` task (`e2esm1`, home = the secondmate-shaped scratch home): its tab lands in a DIFFERENT workspace than `cm1`'s, labeled `2ndmate-e2esm1` by herdr - proving the `fm-spawn.sh` FM_HOME-shadow glue for this one launched-by-the-primary case.
3. A crewmate (`cm2`) is spawned by running `bin/fm-spawn.sh` again, this time with `FM_HOME` set to the SECONDMATE's own home (simulating the secondmate running its own spawn, exactly as it would live) - no special-casing needed. Its tab lands in the SAME workspace as `e2esm1`'s (`2ndmate-e2esm1`), never the primary's - confirming per-home resolution "falls out" naturally for this path, as the design predicted, now proven rather than merely inspected.
4. `fm_backend_herdr_list_live`, called with `FM_HOME` set to each home in turn, sees only that home's own tab(s): the primary's list shows only `cm1`; the secondmate's list shows both `e2esm1` and `cm2`, and neither list leaks into the other.
5. `bin/fm-teardown.sh cm1` closes only `cm1`'s pane - the secondmate's own pane and `cm2`'s pane, both confirmed still open via `herdr pane get`, survive untouched. `bin/fm-teardown.sh cm2` (run with the secondmate's own `FM_HOME`) then closes only `cm2`'s pane, leaving the secondmate's own pane (same workspace) open.

All ten assertions passed on the real binary on the first run.
As with every other real-herdr test in this document, the default session's own workspace state (label, tab count) was confirmed byte-identical immediately before and immediately after the run.

## Away-mode daemon: herdr supervisor-pane support

`bin/fm-supervise-daemon.sh` (the `/afk` sub-supervisor) was tmux-only through 2026-07-03: it discovered its own injection target from `$TMUX_PANE`, and injected via raw `tmux display-message`/`tmux capture-pane`/`tmux send-keys` calls with no backend indirection.
On a herdr-based fleet (firstmate itself running with `HERDR_ENV=1`, no `$TMUX_PANE`), this failed outright at startup: `TMUX_PANE` is unset, so discovery fell through to the legacy `firstmate:0` fallback, which then failed the tmux pane-exists probe and refused to start.

The herdr supervisor-pane fix is transport-layer only - discovery, injection, and the busy/composer guards now dispatch through the SAME `bin/fm-backend.sh` primitives every other backend-aware script already uses (`fm_backend_target_exists`, `fm_backend_busy_state`, `fm_backend_capture`, `fm_backend_send_text_submit`, and the new `fm_backend_composer_state` dispatcher added alongside this work).
The daemon's classification policy, max-defer escape, `FM_INJECT_MARK` sentinel contract, locks, and wake-queue handling remain backend-independent.
Current daemon hardening also dedupes repeated persistent-stale escalations while the same window plus last-status combination is already buffered, and flushes catch-all scan findings immediately when `FM_ESCALATE_BATCH_SECS=0`.
The `/afk` entrypoint now starts this daemon through `bin/fm-afk-start.sh`, which sets `state/.afk`, reuses an identity-matched live daemon lock when present, and otherwise execs the daemon in the foreground so Codex/herdr can track the background session lifecycle instead of reaping a fire-and-forget `nohup ... &` child.

**Discovery.** `FM_SUPERVISOR_TARGET` remains the explicit override, now accepting either a tmux target or a herdr `"<session>:<pane-id>"` target.
A new `FM_SUPERVISOR_BACKEND` override (`tmux`|`herdr`) resolves independently, mirroring `bin/fm-backend.sh`'s own `fm_backend_detect`: `$TMUX_PANE` set selects tmux (even nested inside herdr, matching the innermost-first rule); `$HERDR_ENV=1` with `$HERDR_PANE_ID` present selects herdr, composing the target as `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"`; absent both, the daemon falls back to tmux/`firstmate:0`, byte-identical to its pre-herdr-support behavior.
Other runtime backends, including zellij, orca, and cmux, are not yet supported as supervisor backends - the daemon refuses loudly at startup (`FM_SUPERVISOR_SUPPORTED_BACKENDS="tmux herdr"`) rather than misapplying tmux primitives to a pane that isn't a tmux pane.

**Injection dispatch.** `inject_msg`'s pane-exists probe, busy-guard (`pane_is_busy`), composer-guard (`pane_input_pending`), and verified submit all take an optional `<backend>` argument (defaulting to `tmux` when omitted, so every pre-existing caller/test is unaffected) and route through the generic dispatchers instead of calling `tmux` directly.
For `backend=tmux` every dispatch resolves to the exact same underlying call as before (`fm_backend_capture`'s tmux arm runs the identical `tmux capture-pane -p -t <target> -S -40`; `fm_backend_tmux_send_text_submit` re-exports `fm_tmux_submit_core` verbatim), so tmux behavior is unchanged byte-for-byte.
For `backend=herdr`, busy detection tries the native `agent.get`-backed `fm_backend_herdr_busy_state` first, trusts only `busy` outright, and corroborates every non-`busy` verdict with the shared regex-over-capture reader before treating the supervisor pane as not busy.
This mirrors the per-task stale-pane busy check `bin/fm-supervise-daemon.sh`'s `stale_window_is_busy` already used; composer/pending detection and the verified submit reuse `fm_backend_herdr_composer_state`/`fm_backend_herdr_send_text_submit` unchanged.
The wedge alarm's supervisor-client status-line flash (`tmux display-message ...`) is tmux-only cosmetic UI with no herdr equivalent; it is skipped for non-tmux backends, while the ERROR log line and the durable `state/.subsuper-inject-wedged` marker (the actual signal) are backend-independent and unaffected.

**A pre-existing bug this surfaced: `fm_backend_target_exists`'s herdr arm.** Before this task, that function's herdr case called `HERDR_SESSION="$session" herdr pane get "$pane"` directly, WITHOUT the `--session` flag.
Per "Session targeting" above, `HERDR_SESSION` alone is not reliably honored once another herdr server is already bound on the machine - it silently falls back to whatever server IS running.
This function happened to look correct in every prior test because those tests only ever had ONE herdr server running at a time.
Verifying the away-mode daemon end to end against a real, isolated `HERDR_SESSION` - while the ambient default herdr session was also running (the normal shape of an actual firstmate fleet) - reproduced it directly: the daemon's own startup target-exists check spuriously refused a genuinely live pane in the isolated session because the ambient default session's socket answered instead.
Fixed by routing through `fm_backend_herdr_cli` (which appends `--session` on top of the env var) instead of the raw ad hoc call.
This fix is backend-plumbing, not daemon-specific: it also corrects the same liveness check other callers use (`bin/fm-session-start.sh`'s per-task endpoint-liveness digest read).

**Empirical verification (real herdr, isolated session only).** `tests/fm-afk-inject-herdr-e2e.test.sh` mirrors `tests/fm-afk-inject-e2e.test.sh`'s three scenarios (human-partial-input deferral, swallowed-Enter retry, a normal single digest) plus a fourth (a persistently pending composer that never clears must alarm via `state/.subsuper-inject-wedged`, preserve the buffer, and never crash the daemon) against a real, throwaway, NEVER-default `HERDR_SESSION`, torn down with `herdr_safe_stop_and_delete` exactly like `tests/fm-backend-herdr-smoke.test.sh`.
The "supervisor pane" is a tiny deterministic bash loop drawing a bordered composer row (not a real harness binary), and it registers itself as a herdr agent with `pane report-agent` so the native agent-state submit confirmation sees an idle/working/idle cycle around each submitted digest.
A thin `herdr` PATH shim swallows exactly one `pane send-keys <pane> enter` call to simulate the swallowed-Enter scenario, since herdr's real CLI has no built-in way to drop a keystroke.
The same four-scenario test now runs on native Windows Git Bash with no blanket Windows defer; the 2026-07-08 command output and zero-process-leak baseline are recorded in `docs/herdr-afk-inject-native-windows-2026-07-08.txt`.

Building that test surfaced one more real finding worth recording for anyone writing a similar herdr-driven composer script: `tput cols`, called from WITHIN a script launched into a herdr pane via `pane run`/`send-text`, reported a stale/default `80` regardless of the pane's actual width, while an interactively-typed one-off `tput cols` in the same pane correctly reported its real width (54, in the environment this was verified in).
A composer redraw that trusts `tput cols` for its own line-wrapping math can therefore silently overflow the pane's real width and wrap across two terminal rows - breaking the structural single-row border classifier's assumption (the digest looked "concatenated with itself" because the guard never fired: the composer read `unknown` instead of `pending`, so the busy/composer guard did not defer a second attempt).
The test's composer script works around this with a hardcoded conservative width rather than trusting `tput cols` in this execution context.
This is a test-harness-only concern - `fm_backend_herdr_composer_state` and `fm_backend_herdr_send_text_submit` themselves are unchanged and were reverified correct once the test's own composer script stayed within the pane's real width - but it is a sharp edge for any future herdr-launched interactive script that computes its own layout from `tput`.

## Native Windows (Git Bash) path handling

Most real-binary verification above was on macOS aarch64, and the spawn handoff path is also verified on native Windows Git Bash as recorded below.
On native Windows herdr is a Windows-native process that speaks Windows-form paths and emits CRLF line endings while the surrounding bash speaks POSIX (`/c/...`) paths and LF.
Six narrow, additive conversions bridge that gap, each gated on `fm_platform_is_windows` (`bin/fm-platform-lib.sh`) so the POSIX path is byte-for-byte unchanged:

- **`--cwd` out to herdr is converted with `cygpath -w`.** `fm_backend_herdr_cwd_arg` translates the POSIX `--cwd` to its Windows form before every `workspace create` and `tab create`, so Windows-native herdr lands the workspace/tab in the intended directory instead of misreading a `/c/...` string.
- **The seeded task-tab shell is native Git Bash and space-safe.** `fm_backend_herdr_shell_arg` ignores inherited `$SHELL` on Windows, resolves Git Bash from `command -v bash`, and passes `cygpath -w -s` output in `--env SHELL=...`; `fm_backend_herdr_create_task` then runs that shell explicitly with `pane run <pane> "<shell> -l"`.
This avoids both failure modes observed on Windows: an inherited WSL-flavored `$SHELL` selecting the wrong shell, and `C:\Program Files\...` breaking herdr's shell handoff.
- **The live cwd is actively probed on Windows.** Native Windows herdr 0.7.1 reports only the pane's frozen creation-time `cwd` in `pane get`; it does not emit `.result.pane.foreground_cwd` there.
On Windows, `fm_backend_herdr_current_path` therefore submits a marked `pwd` probe into the live pane and parses the marked output from `pane read`, so `fm-spawn.sh` sees the cwd of the `treehouse get` subshell.
POSIX keeps the passive `foreground_cwd` read and normalizes that value with `cygpath -u` only when the Windows branch is active.
- **A trailing carriage return is stripped from every value read back from herdr.** `fm_backend_herdr_windows_strip_cr` runs `tr -d '\r'` on Windows and passes through (`cat`) on POSIX. Because Windows-native herdr emits CRLF, a trailing `\r` would otherwise taint every jq-extracted value the adapter compares or returns - protocol/version gate, server-running poll, default-tab prune label/agent-status checks, pane-agent-state round-trips and error-code compares, `parse_target`'s session/pane split, bounded `capture` and composer-state reads, busy-state, `pane_for_tab`, and `list_live`'s tab id/label - breaking exact-string compares such as `[ "$status" = working ]` and polluting captured pane text, returned targets, and paths. The strip is applied to each such value before it is compared or emitted.
- **The headless server is launched detached via `nohup`.** `fm_backend_herdr_server_start` starts the server through `nohup bash -c '... herdr server ...' & disown` on Windows, where the POSIX `( ... & )` backgrounded-subshell form does not reliably survive; POSIX keeps the exact pre-existing subshell launch.
- **Watcher liveness is refreshed around slow pane reads.** On native Windows, `fm-watch.sh` touches `state/.last-watcher-beat` before and after each herdr-backed pane capture during the stale-pane scan.
This prevents a cycle supervising multiple slow `herdr pane read` calls from tripping `fm-guard.sh` or `fm-watch-arm.sh` as stale before the next poll boundary.
POSIX and non-herdr backends keep the normal poll-boundary beacon behavior.
- **An empty native-Windows session is released after the last task pane closes.** Verified on 2026-07-08 against herdr `0.7.1-preview.2026-06-30-3459798b606d`: `pane close` removed the task tab but left `herdr.exe server --session <name>` alive, and `session stop/delete` could report the isolated session stopped while that process still remained.
  `fm_backend_herdr_kill` now checks the scoped workspace count after closing the pane; when it is zero on Windows, it stops and deletes that exact named session, then reaps only a stubborn `herdr.exe server --session <same-name>` process.
  POSIX does none of this extra release work, and Windows never releases a session that still has workspaces or the firstmate process's own ambient herdr session.
- **The composer's leading prompt glyph is stripped as a literal fixed string.** `fm_backend_herdr_composer_state`'s prompt-glyph strip uses `${stripped#'❯ '}`-style exact-prefix removals on Windows, because msys2/Git-Bash bash's byte-oriented `${x#??}`/`${x#?}` parameter expansions mangle the 3-byte prompt glyph U+276F (`❯`) and would misclassify the empty-composer ghost placeholder as pending. POSIX keeps the original byte-count `${x#??}`/`${x#?}` expansions; the ASCII prompts (`>`, `$`, `%`, `#`) are handled on both paths.

On POSIX every conversion is a no-op: no `cygpath` is invoked (the cwd and the resolved shell path are passed through untouched), the CR strip is an identity passthrough, the composer prompt-glyph strip is the original byte-count parameter expansion, and the server launch is the original backgrounded subshell.
This Windows handling is covered by fake-CLI unit tests (`tests/fm-backend-herdr.test.sh`'s `test_windows_*`/`test_posix_*` pairs, which assert the Windows branch calls `cygpath`/`nohup` and strips CR from each value it compares or returns, and that the POSIX branch never does and stays byte-identical - including that a POSIX empty `foreground_cwd` emits no bytes), by `tests/fm-backend-herdr-handoff.test.sh`, and by `tests/fm-backend-herdr-release.test.sh` for the empty-session release path, the self-session guard, and the POSIX no-op path.

### Native Windows handoff verification (2026-07-07)

Verified on native Windows Git Bash against real herdr 0.7.1 with an isolated `HERDR_SESSION=fm-husk-live-fixed2`, a scratch Git project, and a scratch `FM_HOME`.
The exact spawn command was:

```bash
env HERDR_SESSION=fm-husk-live-fixed2 SHELL=/usr/bin/bash FM_ROOT_OVERRIDE=/c/Users/viktor/.treehouse/firstmate-upstream-0bcca5/1/firstmate-upstream FM_STATE_OVERRIDE=/tmp/fm-herdr-live-fixed2.nXmBw5/state FM_DATA_OVERRIDE=/tmp/fm-herdr-live-fixed2.nXmBw5/data FM_CONFIG_OVERRIDE=/tmp/fm-herdr-live-fixed2.nXmBw5/config FM_PROJECTS_OVERRIDE=/tmp/fm-herdr-live-fixed2.nXmBw5/projects FM_SPAWN_NO_GUARD=1 /c/Users/viktor/.treehouse/firstmate-upstream-0bcca5/1/firstmate-upstream/bin/fm-spawn.sh husklivefix2 /tmp/fm-herdr-live-fixed2.nXmBw5/scratch-project --backend herdr "sh -c 'echo live-herdr-ok; pwd; sleep 5'"
```

The shell path used by the backend was `C:\PROGRA~1\Git\usr\bin\bash.exe`.
The command exited `0` and printed:

```text
spawned husklivefix2 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-husk-live-fixed2:w1:p2 worktree=/c/Users/viktor/.treehouse/scratch-project-0fc173/1/scratch-project
```

`fm_backend_herdr_current_path` then returned `/c/Users/viktor/.treehouse/scratch-project-0fc173/1/scratch-project`.
The pane capture showed PowerShell starting `C:\PROGRA~1\Git\usr\bin\bash.exe -l`, `treehouse get` entering `~\.treehouse\scratch-project-0fc173\1\scratch-project`, the marked `pwd` probe returning `/c/Users/viktor/.treehouse/scratch-project-0fc173/1/scratch-project`, and the raw launch command printing `live-herdr-ok` from that same worktree.
`bin/fm-teardown.sh husklivefix2` then returned the treehouse worktree and closed the herdr pane.

### Native Windows session-lock verification (2026-07-09)

Verified on native Windows Git Bash against real herdr 0.7.2-preview.2026-07-07-f5354780e4ef with an isolated `HERDR_SESSION=fm-lock-singlefile-live-1598827` and a real Herdr pane whose live agent metadata reported `claude`.
The verification used the Herdr backend helpers to create the isolated session and pane, then ran `bin/fm-lock.sh` with `FM_PLATFORM_IS_WINDOWS=yes`, `HERDR_ENV=1`, `HERDR_SESSION=fm-lock-singlefile-live-1598827`, and `HERDR_PANE_ID=w1:p2`.

The exact observed output was:

```text
lock acquired: herdr agent herdr:fm-lock-singlefile-live-1598827:w1:p2:term_656315c9392a32
lock=herdr:fm-lock-singlefile-live-1598827:w1:p2:term_656315c9392a32
sidecar=no
lock: held by live herdr agent herdr:fm-lock-singlefile-live-1598827:w1:p2:term_656315c9392a32
expected=herdr:fm-lock-singlefile-live-1598827:w1:p2:term_656315c9392a32
agent=claude
```

That proves the native-Windows Herdr fallback now uses `state/.lock` as the single commit point and re-derives liveness from live `herdr pane get` and `herdr agent get` data.

Legacy numeric-lock migration was verified on the same native Windows host against real herdr 0.7.2-preview.2026-07-07-f5354780e4ef with an isolated `HERDR_SESSION=fm-lock-legacy-live-2070959`.
The verification created a real Herdr pane, reported a live `claude` agent on that pane, wrote a test fixture matching the old deployed format (`state/.lock` containing a numeric bash pid and read-only `state/.lock.herdr` containing `pid=`, `session=`, `pane=`, and `agent=claude`), and then ran `bin/fm-lock.sh status`.

The exact observed output was:

```text
lock: held by live harness pid 2070959
sidecar_pid=2070959
pane=w1:p2
terminal=term_65633a864dace2
agent=claude
```

That proves a live pre-upgrade numeric-plus-sidecar Herdr lock is still honored during migration without reintroducing any sidecar writer.

The follow-up cleanup path was verified on 2026-07-10 against real herdr 0.7.2-preview.2026-07-07-f5354780e4ef with an isolated `HERDR_SESSION=fm-lock-cleanup-live-2106569`.
The verification pre-created a legacy `state/.lock.herdr`, acquired the lock through a live Herdr pane reporting `claude`, and confirmed the new-format owner replaced it while the legacy sidecar was removed.

The exact observed output was:

```text
lock acquired: herdr agent herdr:fm-lock-cleanup-live-2106569:w1:p2:term_65634629922d92
lock=herdr:fm-lock-cleanup-live-2106569:w1:p2:term_65634629922d92
sidecar=no
expected=herdr:fm-lock-cleanup-live-2106569:w1:p2:term_65634629922d92
agent=claude
```

That proves the single-file acquisition path cleans up obsolete legacy sidecars without writing a replacement sidecar.

### Herdr lock identity field verification (2026-07-08)

Verified on native Windows Git Bash against real herdr with isolated sessions `fm-lock-json-claude-2997616` and `fm-lock-live-print-17793`.
`herdr agent get w1:p1 --session fm-lock-json-claude-2997616` returned a settable `"name"` and, after Claude initialized, a detected `"agent":"claude"` field.
After `herdr --session fm-lock-json-claude-2997616 agent rename w1:p1 fm-lock-json`, the same `agent get` returned `"name":"fm-lock-json"` while preserving `"agent":"claude"`.
That proves `bin/fm-lock.sh` must key herdr lock identity off `.result.agent.agent`, falling back to `.result.agent.name` only for older herdr responses that lack the detected field.

Live lock verification used:

```bash
herdr --session fm-lock-live-print-17793 agent start fm-lock-live --cwd /c/Users/viktor/.treehouse/firstmate-upstream-0bcca5/1/firstmate-upstream --no-focus -- claude --print --dangerously-skip-permissions "<prompt that runs fm-lock.sh>"
```

The verification poll showed `name=fm-lock-live agent=claude status=idle`, and the scratch lock contained a Herdr owner string with the live session, pane, and terminal identity:

```text
herdr:fm-lock-live-print-17793:w1:p1:<terminal-id>
```

`HERDR_PROCESS_BASELINE=1 AFTER=1` confirmed the isolated herdr session cleanup returned the machine to the original herdr process count.

### Native Windows afk and process-release verification (2026-07-08)

Verified on native Windows Git Bash against real herdr `0.7.1-preview.2026-06-30-3459798b606d` with an isolated `HERDR_SESSION=fm-afk-liveverify-<pid>`.
The live script created a real herdr supervisor pane, started `bin/fm-supervise-daemon.sh` with `FM_SUPERVISOR_BACKEND=herdr`, set `.afk`, wrote a delayed `needs-decision:` status event, waited for the daemon to inject the escalation digest, simulated the captain's unmarked return through `should_exit_afk`, cleared `.afk`, stopped the daemon, closed the panes, and ran guarded session cleanup.
The full native-Windows run of `tests/fm-afk-inject-herdr-e2e.test.sh` is recorded separately in `docs/herdr-afk-inject-native-windows-2026-07-08.txt`; it covers partial-input deferral, swallowed-Enter retry, a normal digest, and the max-defer wedge alarm, with the host `herdr.exe` process count restored to its pre-run baseline.
The exact observed output was:

```text
before_count=0
escalation_delivered=injection
return_cleared_afk=yes
after_count=0
```

That proves the native-Windows herdr away-mode path delivered an escalation, recognized an unmarked return and cleared away mode, and returned `herdr.exe` process count to the original baseline after teardown.

## Known herdr 0.7.1-preview limitations (native Windows)

The following limitations are known behavior of the external herdr `0.7.1-preview` tool on native Windows, not firstmate bugs.
They were observed during live herdr acceptance testing and should be treated as operator-facing recovery guidance until a newer herdr build proves otherwise.

### Server can die under fleet load

During real fleet activity on native Windows, observed during an `/afk` away-mode teardown, the herdr server for a session can die entirely under load.
The recognizable state is that `status.server.running` becomes unreachable, `agent list` errors, every pane and workspace from that session is lost, and zero `herdr.exe` processes remain.
Firstmate's own empty-session release path is already guarded against taking down the session firstmate is itself running in: see "Session targeting: the `--session` flag, not `HERDR_SESSION` alone" for the `fm_backend_herdr_release_session_if_empty` / `fm_backend_herdr_windows_kill_server_processes` self-session guard.
The remaining risk documented here is herdr `0.7.1-preview` instability under native-Windows fleet load, independent of that closed firstmate path.

Recovery: start a fully fresh herdr session with a new `--session` name and relaunch there.
Do not try to recover by restarting the dead session's server; a restarted server for the same session can preserve listings while reads remain broken, as described below.

### Restarted servers can list panes but cannot serve reads

After a herdr server death, restarting the herdr `0.7.1-preview` server for the same session can leave herdr in an inconsistent state.
The agent can re-register, and both `agent list` and `pane list` can show the agent and pane, but `pane read <pane>` and `agent read <agent>` return `pane_not_found` or `agent_not_found`.
This list/read disagreement was reproducible across multiple restarts and blocks observing or steering any firstmate process recovered onto the restarted server.
Treat it as a herdr `0.7.1-preview` internal inconsistency, not a firstmate bug.

Recovery: do not restart the herdr server for the same session as the recovery path.
Start a fully fresh herdr session with a new `--session` name and relaunch there.

## Known gaps and follow-up notes

- **No `events.subscribe` native push.** The busy-state semantic read (`agent.get`) is consumed through the EXISTING `fm-watch.sh` poll loop (same 15-second cadence as every other window), not a persistent async subscriber pushing events directly into the wake queue.
  This satisfies the adopted design's "polling remains as the reconciliation backstop" language without a separate watcher rewrite; herdr tasks already get materially better busy-state accuracy than tmux's regex guessing from this alone.
  A genuine `events.subscribe`-driven push is a reasonable follow-up, not implemented here.
- **`bin/fm-bootstrap.sh`'s required-tools list is unchanged.** It still unconditionally requires `tmux`, and does not yet conditionally add `herdr` and `jq` when a backend selection resolves to herdr.
  The version/tool gate happens at spawn time instead and refuses loudly, so this is bootstrap-detection polish, not a functional gap.
- **Worktree-discovery isolation guard is symlink-fragile for a project path under a symlinked prefix (e.g. macOS's `/tmp` -> `/private/tmp`).** Discovered while building the runtime-backend-auto-detection real smoke test (`tests/fm-backend-autodetect-smoke.test.sh`), which needed a scratch project. `fm-spawn.sh`'s `PROJ_ABS` is a LOGICAL `cd && pwd` (symlink components kept), while herdr's `foreground_cwd` (and real tmux's `pane_current_path`, on the same OS-level cwd primitive) report the PHYSICALLY resolved path.
  When the project itself lives under a symlinked directory, the very first worktree-discovery poll sees two different strings for the identical starting directory and the isolation guard false-refuses the spawn as "not isolated" before `treehouse get` ever moves the pane - backend-agnostic, not specific to herdr. Worked around in the test by resolving its scratch `TMP_ROOT` through `pwd -P` before use; the underlying `fm-spawn.sh` path-comparison gap (worth resolving `PROJ_ABS` physically, or comparing physically-resolved forms in the isolation guard) is unfixed and worth a dedicated follow-up.
- **RESOLVED: a restart's restored-layout husk no longer needs a manual pane close before respawn.** See "Respawn idempotency: a restored task tab is a husk, not a duplicate" above for the fix (`fm_backend_herdr_pane_agent_state`, `fm_backend_herdr_create_task`'s close-and-replace).
  Left over from that fix: the `dead` (`pane_not_found`) husk classification is exercised only at the unit level, never against the real binary - killing a pane's process on a live server was observed to make herdr reap the whole tab immediately (never leaving a dead-but-still-listed pane for the duplicate check to find), and a real session restart was never observed to produce one either.
  It remains a conservative, defensively-coded path for a herdr failure mode (e.g. a restored process that fails to start) nobody has reproduced against the real binary yet.
