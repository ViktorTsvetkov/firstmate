# Windows native support - design analysis

Status: design analysis, written 2026-07-05.
This is a proposal document, not a verification record: every upstream platform claim below comes from vendor documentation and public sources as of July 2026, and per this repo's empirical-verification discipline none of it may be treated as a verified adapter fact until reproduced on a real Windows machine and recorded with date, version, exact commands, and exact output.
Nothing in this document changes runtime behavior.

## 1. Summary

Firstmate today is explicitly macOS/Linux only, and nothing in the repo mentions Windows, WSL, MSYS, or PowerShell.
The blocker is not bash syntax: the shell plumbing is already written defensively for BSD-vs-GNU portability and is roughly 80% Git-Bash-clean as it stands.
The blocker is the substrate underneath the scripts: the session multiplexer (tmux by default), symlink-based locking, POSIX process/signal semantics, tracked repo symlinks, and `curl | sh` tool installers.

Two facts change the picture and make a native port realistic without a rewrite:

1. The runtime-backend abstraction (`bin/fm-backend.sh` + `bin/backends/*.sh`) is already the exact seam a Windows port needs, and two upstream backends now run on native Windows: herdr ships a Windows preview build (`irm https://herdr.dev/install.ps1 | iex`) and Orca ships native Windows binaries.
2. The dominant harness, Claude Code, runs natively on Windows and requires Git for Windows, executing its Bash tool through Git Bash - so on any Windows machine where firstmate's primary agent can run at all, a bash interpreter for `bin/*.sh` is already installed.

The recommended approach is therefore NOT a PowerShell port and NOT a rewrite: keep `bin/` as bash, define Git Bash as the Windows substrate, fix the small set of genuinely POSIX-only mechanisms behind a platform seam, and deliver Windows-native task endpoints through the existing backend adapter layer, with herdr as the primary Windows backend and Orca as the secondary.

## 2. Where firstmate stands today (review)

### 2.1 Architecture layers

Firstmate is a layered system, and each layer has a different Windows story:

| Layer | What it is | Windows status today |
| --- | --- | --- |
| Agent instructions | `AGENTS.md` + skills, loaded by the harness | Platform-neutral markdown |
| Orchestration scripts | ~50 bash scripts in `bin/`, `bin/backends/` | Bash-only, but largely Git-Bash-compatible |
| Supervision engine | watcher, wake queue, guards, afk daemon (bash processes + on-disk state) | Bash-compatible except locks, signals, pid identity |
| Session backend | tmux (reference), herdr, zellij, orca, cmux via `fm-backend.sh` | tmux/zellij: no Windows; cmux: macOS-only; herdr: Windows preview upstream; orca: Windows native upstream |
| Worktree provider | treehouse (orca replaces it) | treehouse is Go with a native Windows build and `install.ps1` |
| Harnesses | claude, codex, opencode, pi, grok CLIs | claude native (needs Git for Windows), codex native (experimental), opencode cross-platform, pi/grok unverified |
| External tools | no-mistakes, tasks-axi, gh-axi, lavish-axi, chrome-devtools-axi, jq, gh, curl | npm/Node tools nominally portable; `curl \| sh` installers are Unix-only; jq/gh/curl have Windows builds |

### 2.2 What is already right for a port

- The backend adapter seam is real and complete: every capture, send, key, kill, liveness, and composer-state operation dispatches through `fm-backend.sh` into `bin/backends/<name>.sh`, callers are backend-agnostic, and the verdict vocabulary (`empty|pending|unknown|send-failed`) is uniform.
- Backend capability differences are already tolerated: no native busy-state degrades to regex peeking, missing composer classifiers degrade to `unknown`, orca's missing Escape is a documented gap, and the afk daemon whitelists the backends it supports.
- The scripts already branch on `uname = Darwin` for `stat`, fall back across `md5`/`md5sum` and `timeout`/`gtimeout`/`perl`, avoid `flock`, avoid GNU-only `date -d`, avoid bash-4-only features, and gate every external tool with `command -v`.
- The repo has a strong extension discipline (empirical verification, per-backend docs, fake-CLI unit tests plus self-skipping smoke tests, shellcheck CI) that a platform port can ride on unchanged.

### 2.3 The genuinely POSIX-bound mechanisms

The dependency inventory found five clusters that block native Windows regardless of shell:

1. Session backends: 217 tmux call sites concentrated in `bin/backends/tmux.sh` and `fm-tmux-lib.sh`; no tmux exists on native Windows, and `fm-tmux-lib.sh` is also the shared composer/busy engine.
2. Symlink-based locking: `fm-wake-lib.sh` uses atomic `ln -s` creation as its concurrency primitive, with `readlink` owner records and `[ -L ]` checks; Git Bash's `ln -s` copies by default (unless `MSYS=winsymlinks:*` is set) and native symlink creation needs Developer Mode or elevation, so lock atomicity silently breaks.
3. Process model: process-group kills (`kill -TERM -$pid`), `ps -p <pid> -o lstart= -o command=` pid-identity fingerprinting, `trap TERM INT HUP`, and a perl `fork`/`setpgrp` timeout fallback all assume Unix semantics.
4. Tracked repo symlinks: `CLAUDE.md -> AGENTS.md` and `.claude/skills -> ../.agents/skills` check out as plain text files on default Windows git, which breaks harness instruction loading in every clone and worktree.
5. Unix-only installers and hook plumbing: treehouse/no-mistakes install via `curl | sh`; turn-end hooks rely on `/bin/sh`, `touch`, `chmod +x`, and `~/.grok/hooks/`; `fm-spawn.sh` hardcodes `/tmp/fm-<id>` for the per-task temp root.

One further contract is implicit and must become explicit for Windows: the spawned pane itself must speak POSIX shell.
`fm-spawn.sh` types `treehouse get`, `export GOTMPDIR=...`, and an env-var-prefixed launch command into the pane as literal text, so a pane whose default shell is PowerShell or cmd cannot host a firstmate task as spawned today.

## 3. Options considered

### Option A: WSL2 (documented fallback, not the goal)

Everything works today inside WSL2 unchanged, because WSL2 is Linux.
This should be documented as the zero-effort path for Windows users, but it is not native support: it requires WSL setup, projects live best on the Linux filesystem, and Windows-native tooling (native harness installs, Windows browsers, Windows build toolchains) is a boundary away.
Keep it as the supported stopgap while native support matures.

### Option B: Git Bash substrate + Windows-native backends (recommended)

Keep `bin/` as bash and declare Git Bash (MSYS2 runtime, bundled with Git for Windows) the supported Windows interpreter.
Deliver task endpoints through the backends that already run on native Windows upstream: herdr (primary) and Orca (secondary).
Fix the POSIX-bound clusters from section 2.3 behind a small platform seam.
This is the only option that preserves one codebase, reuses the existing backend seam, matches the repo's incremental empirical-verification culture, and inherits new upstream backends cheaply.

### Option C: PowerShell port of `bin/`

Rejected.
It doubles ~14k lines of maintenance across two script dialects that will drift, contradicts the one-owner rule, and still would not produce a tmux, so it solves the easy 80% and none of the hard 20%.

### Option D: Rewrite the orchestration core in a portable language (Go/Rust/Node)

Not now.
It is the cleanest long-term answer to process/lock/signal portability, but it is a full rearchitecture of a young, fast-moving, solo-maintained system whose product is deliberately a transparent bash-and-markdown template.
Revisit only if Option B's platform seam accumulates enough weight to justify it.

## 4. Recommended approach in detail

### 4.1 Principle: Windows is a platform contract on existing seams, not a new architecture

The port should add zero new architecture.
It should (a) harden the substrate assumptions behind one platform library, (b) make backend platform support an explicit, declared capability in the adapter registry, and (c) verify per-harness and per-tool facts on Windows using the same evidence discipline the repo already applies to backends and harnesses.

### 4.2 Substrate: require Git for Windows, target Git Bash

- Declare the supported Windows environment: Windows 10/11, Git for Windows (provides bash, coreutils, `ps`, `touch`, `mkdir -p`, fractional `sleep`), Node, and the chosen backend's Windows build.
- This adds no burden for Claude Code users, since Claude Code's native Windows install already requires Git for Windows and runs its Bash tool through Git Bash - meaning the firstmate agent's own tool calls into `bin/*.sh` work unmodified.
- Verify and record which Git Bash `ps` fields exist; `ps -o lstart= -o command=` will need a Windows-safe pid-identity fallback (see 4.4).

### 4.3 Backend strategy: herdr primary, Orca secondary, capability-declared

Feature-parity comparison for the two Windows-capable backends, against tmux as the reference:

| Capability | tmux (reference) | herdr on Windows | Orca on Windows |
| --- | --- | --- | --- |
| Upstream Windows support | none | preview/beta (`install.ps1`) | native builds |
| Worktree provider | treehouse | treehouse | Orca itself (drops treehouse dep) |
| Native busy-state | no (regex peek) | yes (`agent get`) - best supervision signal | no (regex peek) |
| Composer-state classifier | yes | yes | yes |
| Escape key (interrupt for claude/codex/opencode/pi) | yes | yes | NO - only Enter and Ctrl-C |
| Secondmate support | yes | yes (per-home workspaces) | no |
| Away-mode daemon (`fm-supervise-daemon.sh`) | yes | yes (only non-tmux backend supported) | no |
| Runtime auto-detection | yes (`$TMUX`) | yes (`HERDR_ENV=1`) | never (explicit only) |
| Headless/CI viable | yes | yes | no (GUI app must be running) |

herdr is the strategic Windows backend: it is the only backend besides tmux that the away-mode daemon supports, the only one with native busy-state (which reduces reliance on the tmux-lib regex model), and it supports secondmates and auto-detection.
Its Windows build is upstream-labeled preview, so firstmate must version-gate and empirically verify it exactly as `docs/herdr-backend.md` did on macOS, recording a "Windows verification" evidence section in that same doc.

Orca is the complementary second: native Windows upstream and it replaces treehouse, which shrinks the external-tool surface on Windows.
But its capability gaps are structural on every OS - no Escape means it cannot interrupt four of the five harnesses (only grok uses Ctrl-C), and it has no secondmate or afk-daemon support - so it should be offered as a supported-with-documented-gaps option, not the default.

The pane-shell contract from section 2.3 must be pinned: on Windows, the backend's pane/terminal default shell must be Git Bash for `fm-spawn.sh`'s typed commands (`treehouse get`, `export GOTMPDIR=...`, env-prefixed launch templates) to work.
Verify whether herdr and Orca on Windows can pin a per-pane shell; if a backend cannot, its adapter needs a launch-dialect shim (e.g. wrapping the typed line in `bash -lc '...'`), which stays inside that adapter per the one-owner rule.

### 4.4 Platform seam: one library for the OS-specific mechanisms

Create a small `bin/fm-platform-lib.sh` (mirroring how `fm-wake-lib.sh` and `fm-classify-lib.sh` centralize shared mechanics) and route the known-divergent operations through it:

- Locking: replace the `ln -s` atomic lock in `fm-wake-lib.sh` with an atomic `mkdir` lock holding an owner file, on all platforms.
  `mkdir` is atomic on POSIX and NTFS alike, removes the Developer-Mode/symlink-privilege dependency entirely, keeps one code path (no per-OS branch), and is the smallest change that fixes the highest-risk Windows failure (a lock that silently degrades to a copy is a correctness bug, not an inconvenience).
- Pid identity: keep `ps -o lstart= -o command=` where it works and fall back to a start-time-free identity (command line only, or MSYS `ps -p` output shape) when `lstart` is unsupported, with the accepted-risk note that pid-reuse detection weakens.
- Process-group kill: `kill -TERM -$pid` has no reliable MSYS equivalent for native-Windows children; scope it (it is used in bootstrap timeout handling) and provide a best-effort child-walk fallback.
- Temp root: replace the hardcoded `/tmp/fm-<id>` in `fm-spawn.sh` and `fm-teardown.sh` with `${TMPDIR:-/tmp}/fm-<id>`; audit the remaining bare `/tmp` sites (most already use `${TMPDIR:-/tmp}`).
- `$HOME`: guard the `~/.grok/hooks` and similar uses with a `%USERPROFILE%` fallback when `$HOME` is unset.
- Exec bits: relax `[ -x ]` gates to `[ -f ]`-plus-interpreter invocation (`bash script`) where the executable bit may not survive a Windows checkout, and stop relying on `chmod +x` semantics for generated shims.

### 4.5 Tracked symlinks: detect and repair, do not redesign

`CLAUDE.md -> AGENTS.md` and `.claude/skills -> ../.agents/skills` are load-bearing for harness compatibility.
On Windows:

- Document the requirement: clone with `core.symlinks=true` and Windows Developer Mode enabled (which makes unprivileged symlink creation work), which Git for Windows supports.
- Add a bootstrap diagnostic (`SYMLINKS: CLAUDE.md is not a symlink - <repair command>`) so a wrong checkout surfaces at session start instead of as silent harness misbehavior; the CI symlink invariant already protects the repo side.
- `fm-ensure-agents-md.sh` already has a copy-fallback pattern to draw on if a hard requirement proves too hostile in practice, but a real symlink should stay the primary mechanism so the one-file-one-owner property of `AGENTS.md` holds.

### 4.6 Bootstrap and external tools

- Add Windows install branches to `bin/fm-bootstrap.sh`'s installer table: treehouse and herdr already ship `install.ps1` (`irm ... | iex`); npm tools (`tasks-axi`, `gh-axi`, `lavish-axi`, `chrome-devtools-axi`) install identically via npm; `jq`/`gh` via winget.
- no-mistakes is the open verification item: its installer is `curl | sh` and its runtime (a git proxy in front of the remote plus isolated-worktree pipeline) must be empirically verified under Git Bash; until then, Windows projects can be limited to `direct-PR` and `local-only` delivery modes, which is an honest, mode-shaped degradation the system already expresses per project.
- Turn-end hooks: verify per harness on Windows - the claude Stop hook command string (`touch '<path>'`) and `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh` must be confirmed to execute under Claude Code's Windows hook runner; the grok global-hook path (`~/.grok/hooks/` + `chmod +x`) and the pi/opencode/codex hook mechanics each need one empirical pass.

### 4.7 CI: make Windows breakage visible before it lands

Add a `windows-latest` CI leg running shellcheck and the fake-CLI unit tests under Git Bash.
The test suite's existing convention - fake-CLI unit tests plus real-tool smoke tests that self-skip when the tool is absent - means a large fraction of `tests/*.test.sh` can run on the Windows leg immediately and act as the port's regression net, with real-herdr/orca Windows smoke tests as machine-gated follow-ups.
This turns the port from a one-time verification event into an enforced property, which is what keeps future backends cheap.

## 5. Keeping future backends cheap (the extensibility ask)

The adapter seam already makes a new backend a bounded task: one `bin/backends/<name>.sh`, registry entries (`FM_BACKEND_KNOWN`/`FM_BACKEND_SPAWN`, `fm_backend_source`, dispatcher case arms, `fm-spawn.sh` container/wrapper arms), a verification doc, and tests.
Three additions keep Windows from re-complicating that:

1. Declare platform support per adapter: alongside the tool/version gate each adapter already has, add a platform gate (`fm_backend_<name>_platform_check`) so `--backend tmux` on Windows refuses loudly at spawn with the same UX as a version gate, instead of failing mid-spawn.
2. Declare capabilities instead of discovering them: the port surfaces that capability gaps (Escape support, native busy-state, secondmate support, afk-daemon support, auto-detection) are currently encoded as scattered special cases (orca's `send_key` error, the daemon's whitelist, spawn's `--secondmate` refusals).
   A small per-adapter capability declaration that those call sites consult would make the next backend's gaps a one-line declaration rather than N call-site edits.
3. Keep the pane-shell dialect inside the adapter: if a future Windows backend cannot give a POSIX pane, its adapter owns the wrapping; `fm-spawn.sh`'s typed-command contract stays single-owner.

With those in place, "a new upstream backend gained Windows support" costs exactly: flip its platform declaration, run the Windows smoke test, record the evidence section in its backend doc.

## 6. Suggested phasing

1. Phase 0 - substrate hardening (no Windows machine needed, benefits all platforms): mkdir-based lock, `${TMPDIR:-/tmp}` temp root, `$HOME` guards, exec-bit relaxations, platform lib skeleton, backend platform/capability declarations.
2. Phase 1 - CI: `windows-latest` leg with shellcheck + fake-CLI unit tests under Git Bash; fix what it finds.
3. Phase 2 - backend verification on a real Windows machine: herdr Windows preview end-to-end (spawn, steer, peek, busy-state, teardown) recorded in `docs/herdr-backend.md`; Orca Windows the same in `docs/orca-backend.md`; pin the pane-shell contract per backend.
4. Phase 3 - harness verification on Windows: claude first (native install, Stop-hook execution, turn-end file), then codex/opencode; record in `harness-adapters` per its existing per-harness evidence format.
5. Phase 4 - tool verification: treehouse Windows build against the worktree/lease flows; no-mistakes under Git Bash (gates `no-mistakes` delivery mode on Windows); tasks-axi/gh-axi smoke.
6. Phase 5 - docs: a `docs/windows.md` setup guide (requirements, Developer Mode + `core.symlinks`, backend choice, known gaps) and README platform-badge update; WSL2 documented as the fallback throughout.

Phases 0-1 are pure wins with no Windows hardware; phases 2-4 are strictly evidence-gathering in the repo's existing style; nothing requires an architectural decision beyond adopting the platform-contract principle in section 4.1.

## 7. Sources for upstream platform claims

- herdr Windows preview install and platform matrix: https://herdr.dev and https://github.com/ogulcancelik/herdr
- Orca native Windows/macOS/Linux builds: https://www.onorca.dev/ and https://github.com/stablyai/orca
- treehouse Windows build and `install.ps1`: https://github.com/kunchenguid/treehouse
- Claude Code native Windows requirements (Git for Windows, Git Bash execution): https://code.claude.com/docs/en/setup
- Codex CLI native Windows (experimental): https://developers.openai.com/codex/windows

All of the above require empirical re-verification before any adapter fact derived from them is written into a backend doc or the `harness-adapters` skill.
