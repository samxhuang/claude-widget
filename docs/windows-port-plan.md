# Windows port plan

Status: **proposal, not started.** Written 2026-07-26 against commit `e449fec`.

## TL;DR

The two components have wildly different port costs and they should be
treated as two separate projects:

| Component | LOC | Verdict |
|---|---|---|
| `claude-autoresume` (Python daemon) | ~6,100 prod | **Port in place.** ~65% is platform-agnostic arithmetic. The rest is 6 concrete blockers, all solvable with stdlib `ctypes`. |
| `ClaudeUsageOverlay` (Swift/AppKit) | ~5,700 | **Rewrite.** AppKit/SwiftUI/WebKit have no Windows story. Swift-on-Windows exists but gives you Foundation only — no UI, no WKWebView. |

The daemon port is the high-value, low-risk half and it is worth doing on
its own: a Windows daemon writing `state.json` is immediately useful (it can
be read by a remote Mac widget via the existing `remote_sync` path — a
Windows box becomes just another Shape-C remote host).

**Recommended sequencing:** Phase 0 recon → Phase 1 daemon → *then* decide
whether the widget rewrite is worth it. Do not start the widget until Phase 0
has answered the open questions, because two of them (does Claude Code on
Windows write `shell-snapshots`? does Claude Desktop ship Cowork on Windows?)
determine how much of the widget even has data to display.

---

## Phase 0 — reconnaissance (blocking; ~1 day on a real Windows box)

Nearly everything the daemon knows about session state was derived
empirically from live macOS ground truth (see the big comment above
`WORK_STATUS_RUNNING_WINDOW_SECONDS` in `autoresume.py`). None of that
carries over by assumption. These must be answered on an actual Windows
machine running Claude Code + Claude Desktop before writing code.

| # | Question | How to check | What it gates |
|---|---|---|---|
| R1 | Does Claude Code on Windows write `%USERPROFILE%\.claude\projects\**\*.jsonl` in the same format? | `dir /s %USERPROFILE%\.claude\projects` then diff a transcript's JSON keys against a Mac one | Everything. If no, the port is dead. |
| R2 | How is the project folder name encoded from a Windows cwd (`C:\Users\sam\git\x`)? | Inspect the folder names | `guess_project_dir_from_folder` (`autoresume.py:881`) |
| R3 | Does `%USERPROFILE%\.claude\sessions\<pid>.json` exist, and is the pid a real Win32 pid? | `dir %USERPROFILE%\.claude\sessions` while a session runs | The whole process-liveness half of `classify_work_status` |
| R4 | Does the Bash tool write `%USERPROFILE%\.claude\shell-snapshots\` and does the Git Bash child's command line contain that path? | Run a long `sleep 60` Bash tool call, snapshot the process tree | `_TOOL_CHILD_MARKERS` (`autoresume.py:212`) — the "is Bash actually executing" signal |
| R5 | Where does Claude Desktop keep `local-agent-mode-sessions` on Windows? Does Cowork ship on Windows at all? | `dir /s /b %APPDATA%\Claude %LOCALAPPDATA%\Claude` | `COWORK_SESSIONS_DIR` (`autoresume.py:89`, `usage_collector.py:129`); if Cowork is macOS-only, drop that entire scan |
| R6 | Is the per-model 429 / `rate_limit` transcript event shape identical? | Deliberately hit a Fable cap, inspect the tail | `_parse_cli_transcript`'s waiting detection |
| R7 | What is `claude` on the PATH — `claude.cmd`, `claude.exe`, or a shim? | `where claude` | `subprocess.Popen` at `autoresume.py:1399` (a `.cmd` needs `shell=True` or an explicit resolve) |
| R8 | Does the tmp+rename atomic-write pattern survive Defender/AV? | Hammer `os.replace` on `state.json` in a loop while another process reads it | See "The Windows-specific hazard" below |

Deliverable: `docs/windows-recon.md` with the answers, in the same
empirical style as the existing `work_status` comment block. Do not skip
this and guess — the macOS classifier was written against ground truth and
its Windows twin has to be too.

---

## The Windows-specific hazard (read before writing any code)

macOS-hardened lessons in `CLAUDE.md` do **not** transfer, and Windows adds
one that macOS doesn't have.

**What stops mattering.** The "never `FileManager.createFile` on the lock
file, flock is per-inode" discipline (hardening item #1) is POSIX-specific.
Windows locks are handle-and-range based, not inode based. Carry the *intent*
(a stable lock object shared between processes), not the mechanism.

**What starts mattering — sharing violations on rename.** The codebase uses
tmp-write + atomic rename everywhere (`state.json`, `config.json`,
`snapshots*.jsonl` compaction). On POSIX, `rename(2)` over an open file is
fine — readers keep their inode. On Windows, `os.replace()` onto a path that
another process holds open **fails with `PermissionError` (ERROR_SHARING_
VIOLATION)** unless every opener used `FILE_SHARE_DELETE`, which Python's
`open()` does not. Defender/indexers open files opportunistically, so this
fails *intermittently* — the worst failure mode.

Mitigation, applied uniformly in the new platform module:

- A `replace_with_retry(tmp, dst)` helper: bounded exponential retry
  (~10 attempts over ~1s) on `PermissionError`, then raise. Every atomic
  write in the daemon and the widget goes through it.
- Keep read handles open for as short a time as possible (read whole file,
  close, then parse — several call sites already do this).
- Never hold a read handle on `state.json` across a lock acquisition.

This one issue will cause more Windows bugs than everything else in this doc
combined. Budget test time for it (R8).

---

## Phase 1 — daemon port

### 1.1 Introduce a platform module

New file `claude-autoresume/platform_compat.py`, stdlib-only (hard
constraint preserved), exporting:

```
locks:      FileLock(path)              # flock ⇄ LockFileEx
paths:      projects_dir(), cowork_sessions_dir(), sessions_dir(), state_dir()
processes:  process_snapshot() -> [(pid, ppid, cmdline)]
spawn:      spawn_detached(argv, cwd, log_fh)
fs:         replace_with_retry(tmp, dst)
```

Everything else imports from here. macOS keeps its current implementations
verbatim behind the same interface, so **the Mac path must not regress** —
that's the acceptance bar for 1.1, checked by the existing 86-test suite
passing unchanged on macOS.

### 1.2 The six blockers

**B1 — `fcntl.flock` → `LockFileEx`.**
Sites: `autoresume.py:60,545`, `usage_collector.py:116,229,252`,
`remote_ctl.py:47,102,141`.
`fcntl` does not exist on Windows. Two options:

- `msvcrt.locking(fd, LK_LOCK, n)` — stdlib, but blocking mode retries only
  10× over 10s then raises, and it's byte-range on a handle. Workable but the
  timeout semantics differ from `flock(LOCK_EX)`'s indefinite block.
- **`kernel32.LockFileEx` via `ctypes`** with `LOCKFILE_EXCLUSIVE_LOCK` and
  no `LOCKFILE_FAIL_IMMEDIATELY` — a true indefinite blocking exclusive lock,
  the exact `flock(LOCK_EX)` analogue. **Recommended.**

Lock the first byte of a dedicated `.lock` file (matching today's layout:
`state.json.lock`, `config.json.lock`, `usage/snapshots.lock`). The
cross-language protocol with the widget survives — the Windows widget takes
`LockFileEx` on the same byte of the same file.

**B2 — `ps -axo pid=,ppid=,command=` → Toolhelp32 + command lines.**
Site: `collect_runtime_snapshot`, `autoresume.py:224`.
Runs once per 10s poll. Approach:

- pid/ppid/exe-name: `ctypes` → `CreateToolhelp32Snapshot` +
  `Process32FirstW/NextW`. Fast (single syscall pair, no process spawn).
- command line: needed for the `_TOOL_CHILD_MARKERS` match. Toolhelp32
  doesn't provide it. Options, in order of preference:
  1. Skip it if R4 shows the Git Bash child is identifiable by **exe name +
     parentage** alone (e.g. `bash.exe` whose ancestor is the session's
     `node.exe`). This is the cheap, likely-sufficient answer.
  2. `NtQueryInformationProcess` + PEB read via `ctypes` — exact, but needs
     matching bitness and `PROCESS_QUERY_INFORMATION|VM_READ`.
  3. One `powershell -NoProfile Get-CimInstance Win32_Process` per cycle —
     simple, but ~300-500ms and a process spawn every 10s. Fallback only.

**B3 — hardcoded macOS paths.**
`COWORK_SESSIONS_DIR = HOME / "Library" / "Application Support" / ...`
(`autoresume.py:89`, `usage_collector.py:129`) → whatever R5 finds, behind
`platform_compat.cowork_sessions_dir()`. If R5 says Cowork isn't on Windows,
that function returns `None` and every Cowork scan short-circuits — cleaner
than a phantom path. `HOME = Path.home()`, `PROJECTS_DIR`, `SESSIONS_DIR`,
`DEFAULT_STATE_DIR` all already work as-is via `pathlib`.

**B4 — `_TOOL_CHILD_MARKERS`.**
`(".claude/shell-snapshots/", "sandbox-exec")` at `autoresume.py:212`.
`sandbox-exec` is macOS-only; drop it on Windows. The snapshot-path marker
needs backslash-normalization and R4's answer. This is the single highest-
risk classification change — an incorrect answer here reproduces exactly the
false-`needs_input` bug fixed in the 2026-07-19 session (CLAUDE.md item #4),
in a new form.

**B5 — resume spawn.**
`subprocess.Popen(cmd, cwd=project_dir, ...)` at `autoresume.py:1399`.

- Resolve `claude` properly per R7 (`shutil.which` returns the `.cmd`;
  `Popen` on a `.cmd` without `shell=True` raises).
- Add `creationflags=CREATE_NO_WINDOW | DETACHED_PROCESS` — without it every
  auto-resume flashes a console window on the user's desktop, which for a
  background daemon is unacceptable.
- Verify `--permission-mode acceptEdits` behaves identically (the hard
  constraint on the resume default stands).

**B6 — service management.**
`install.sh` + `com.samhuang.claude-autoresume.plist.template` →
`install.ps1` + a Scheduled Task.

- `schtasks /create /tn ClaudeAutoresume /sc onlogon /tr "pythonw.exe ..."`
  (`pythonw.exe`, not `python.exe` — no console window).
- Add `/rl LIMITED` (no elevation) and restart-on-failure via the task XML.
- Environment (`CLAUDE_BIN`, `AUTORESUME_PERMISSION_MODE`) that the plist
  carries today has no Scheduled Task equivalent as clean as launchd's — put
  it in a small `env.json` beside `config.json`, read at daemon start.
- Log rotation at 5MB already exists in `autoresume.py` and is portable.

### 1.3 Free, or nearly

- `plan_fit.py` (2,091 LOC) — pure arithmetic + `urllib` pricing fetch. Only
  the `HOME`-derived cache path. **The lockout-time verdict work from
  2026-07-26 ports untouched.**
- `autoresume_config.py` (211) — free.
- `cowork_resume.py` (299) — pure orchestration, no OS calls; `DRY_RUN = True`
  stands. The macOS UI automation it *would* eventually drive doesn't exist
  yet, so nothing to port. Keep the gate.
- `usage_collector.py` (818) — free apart from B1 and B3.
- `remote_sync.py` (642) — shells out to `ssh`. Windows 10+ ships OpenSSH
  client (`ssh.exe`) in PATH, so this is near-free; verify `BatchMode=yes`
  and key discovery under `%USERPROFILE%\.ssh`.
- `remote_ctl.py` (310) — runs on the *remote* (Linux) host. **Unchanged**
  unless you want a Windows box to be a remote target, in which case it needs
  B1 too.

### 1.4 `deploy_remote.sh` → Python

`deploy_remote.sh` is bash and the Mac widget invokes it (`HostDeployer.swift:151`
runs `/bin/bash`). Windows has no bash without Git for Windows.

**Recommendation: rewrite it as `deploy_remote.py` (stdlib, `subprocess` →
`ssh`/`scp`), keeping the `@@STEP/@@OK/@@FAIL` marker protocol byte-for-byte
so the existing Swift parser and `test_remote_sync.py`'s `PAYLOAD_FILES`
regression test keep working.** This is a net win on macOS too — it removes
a bash dependency and makes the payload list a real Python constant instead
of something parsed out of shell with a regex.

Requiring Git Bash on Windows is the cheaper alternative, but it adds a
non-obvious install prerequisite for a feature (remote hosts) that is
already the most fragile part of the system.

#### Latent bugs found in `deploy_remote.sh` during the port (NOT fixed)

Surfaced while proving byte-for-byte marker equivalence. All are
**pre-existing**, all were **reproduced faithfully in the Python port rather
than fixed**, because none can be tested without a reachable remote host.
Fix them together, on a real host, as one deliberate pass — not blind.

1. **Verify stage uses the wrong interpreter.** It runs
   `python3 ~/.claude-autoresume/bin/remote_ctl.py dump`, not `$REMOTE_PY` —
   the interpreter the daemon was actually installed under. On a host where a
   non-login ssh shell resolves `python3` differently, deploy verification
   passes under an interpreter that isn't the one running the daemon. The
   script already flags the adjacent config-side version of this hazard in
   its `_remote_ctl_command` note. **Highest-value fix of the five.**
2. **`@@OK version=uninstalled`.** The Swift side stores whatever follows
   `version=` into `config.json`, so an uninstall writes the literal string
   `uninstalled` into a field that otherwise holds a payload hash.
3. **systemctl probe conflates two failures.** `if rssh 'command -v systemctl'`
   cannot distinguish "remote has no systemctl" from "the ssh call failed", so
   a connection blip at that moment silently degrades the deploy to the nohup
   path instead of failing loudly.
4. **Empty `NRestarts` reads as healthy.** `[ -n "$NRESTARTS" ] && [ "$NRESTARTS" != "0" ]`
   — an older systemd, or a `show` returning nothing, passes the crash-loop check.
5. **`sed` delimiter injection.** Template rendering uses `s|__PYTHON3__|$REMOTE_PY|g`;
   a `|` in `$REMOTE_PY`/`$REMOTE_HOME`/`$CLAUDE_REMOTE` yields
   `@@FAIL:service: rendering unit template failed` with no clue why. The
   Python port's `str.replace` has no such failure mode — a free robustness
   win on cutover.

### 1.5 Tests

The 86-test suite is mostly filesystem-fixture based and should port with
path fixes. Add:

- `test_platform_compat.py` — lock mutual exclusion across two real
  processes (the macOS equivalent of this caught hardening bug #1, and the
  Windows lock needs the same proof, not a unit-test mock).
- `replace_with_retry` under contention (R8's scenario, as a test).
- Run the suite on both OSes. There is no CI today; at minimum add a
  GitHub Actions matrix (`macos-latest`, `windows-latest`) for
  `python3 -m unittest` — this is the first point in the project's life where
  CI actually pays for itself, because you can no longer test both targets on
  your own desk.

---

## Phase 2 — widget rewrite

### The decision that gates everything

Swift on Windows is real, but it gives you Foundation and Dispatch — **not**
AppKit, SwiftUI, or WebKit. Every line of `AppDelegate.swift`,
`OverlayView.swift`, `SettingsWindow.swift`, `GraphView.swift`, and
`WebSession.swift` is UI-framework-bound. There is no incremental path.

| Option | Tray | Auth webview | Charts | Verdict |
|---|---|---|---|---|
| **WPF / .NET 8 + WebView2** | WinForms `NotifyIcon` interop, mature | WebView2 official WPF control, persistent `UserDataFolder`, `CoreWebView2CookieManager` for the session-key paste path | `DrawingContext` maps almost 1:1 onto SwiftUI `Canvas` | **Recommended.** Most boring, best documented, WebView2 ships with Win11. |
| WinUI 3 | Yes, but tray support is historically rough | Same WebView2 | Same | Newer, more churn, no real advantage here. |
| Tauri (Rust + web UI) | Good | WebView2, hidden window on a shared data dir | HTML/Canvas — a rewrite of the chart code in JS | Pick this **only** if the goal is to eventually replace the Mac app too. |
| Electron | Good | Trivial (hidden `BrowserWindow` + shared session) | JS | ~150MB+ resident for an always-on tray widget. Reject. |
| Avalonia | Yes | Third-party WebView | XAML | Cross-platform without Tauri's Rust cost, but the WebView story is the weak link — and the WebView is load-bearing here. |

**Recommendation: WPF + .NET 8 + WebView2**, unless you want one codebase
across both platforms, in which case Tauri and accept that you're also
rewriting the Mac app.

### 2.1 The authenticated-webview problem, and a shortcut worth considering

`ClaudeWebSession` (`WebSession.swift`) is the load-bearing trick: a hidden
WKWebView on the shared persistent `WKWebsiteDataStore` runs `fetch()` inside
a logged-in claude.ai page, so there is no token handling anywhere. WebView2
maps onto this cleanly:

| WebKit | WebView2 |
|---|---|
| `WKWebViewConfiguration.websiteDataStore = .default()` | shared `UserDataFolder` between login window and hidden view |
| `callAsyncJavaScript` | `ExecuteScriptAsync` |
| `httpCookieStore.setCookie` (session-key paste) | `CoreWebView2CookieManager.AddOrUpdateCookie` |
| `webViewWebContentProcessDidTerminate` | `CoreWebView2.ProcessFailed` |
| `didFailProvisionalNavigation` | `NavigationCompleted` with `IsSuccess == false` |

All four of the hardening behaviors in `WebSession.swift` (backoff retry,
reject-newest backlog cap, process-crash recovery, session-key install) have
direct equivalents. Port the *comments* along with the code — they document
bugs that will recur.

**Shortcut worth evaluating in Phase 0:** the manual session-key path added
2026-07-20 means the app can already authenticate with a bare `sessionKey`
cookie value. A Windows build could skip WebView2 for data fetching entirely
and call the endpoints with plain HTTP + that cookie, using WebView2 only for
the interactive login. That deletes the hardest ~250 LOC of the port.

Tradeoffs, honestly: you lose the "cookie rotates and the webview just keeps
working" property (the user re-pastes when it expires), you take on explicit
credential storage (currently the app holds zero secrets — the OS cookie jar
does), and you'd have to decide where the ClaudeAPI knowledge lives, since
`CLAUDE.md`'s single-module constraint assumes one implementation. **Do not
adopt this without an explicit call** — it trades a real architectural
property for implementation speed.

### 2.2 UI surface mapping

| macOS | Windows | Notes |
|---|---|---|
| `NSStatusItem` (`AppDelegate.swift:455`) | tray `NotifyIcon` | Template images auto-invert on macOS; Windows does not — ship explicit light/dark icons and watch `SystemEvents.UserPreferenceChanged` |
| Borderless `NSPanel` (`:683`) | `WindowStyle=None`, `ShowInTaskbar=False`, `WS_EX_TOOLWINDOW` | |
| Custom `ResizeHandleView`/`MoveHandleView` using `NSEvent.mouseLocation` | The bug that motivated these (gesture frame moving with the handle) recurs identically in WPF | Use screen coords from `Win32 GetCursorPos`, not element-relative — same fix, same reason |
| `DispatchSource` kqueue on the state dir (`:417`) | `FileSystemWatcher` | Keep the 200ms debounce and the delete/recreate re-arm (hardening S10) — `FileSystemWatcher` has the *same* stale-handle failure |
| SwiftUI `Canvas` charts (`GraphView`, `ExpandedGraphView`, 790 LOC) | WPF `DrawingContext` / `DrawingVisual` | Most mechanical part of the rewrite |
| `NSWorkspace.openApplication` (foreground Claude Desktop) | `Process.GetProcessesByName` + `SetForegroundWindow` (needs `AllowSetForegroundWindow`) | Same "no deep link" fallback as macOS — do not reintroduce `claude://resume` (CLAUDE.md item #2) |
| `Process` → `/bin/bash`, `/usr/bin/ssh` (`HostDeployer.swift:151,317`) | `ssh.exe` (built in); bash gone if 1.4 lands | |
| `scripts/check_api_boundary.sh` | PowerShell port, or run under the CI's bash | Keep the boundary enforced |

### 2.3 Suggested MVP cut

If the widget happens, ship it in two tranches rather than chasing parity:

- **MVP:** tray icon, usage bars (session + weekly, incl. the estimated-usage
  projection dot), sessions list, arm/disarm toggles writing `state.json`.
  This is the daily-driver 80%.
- **Later:** Graph tab, Plan-fit tab (the whole lockout-verdict UI), Settings
  window + `ConfigStore`, remote-host deployment UI, budget bars.

---

## Effort estimate

Part-time, one person, assuming Phase 0 comes back clean:

| Phase | Estimate |
|---|---|
| 0 — recon | 1 day |
| 1 — daemon (`platform_compat`, B1-B6, tests, CI) | 1.5-2 weeks |
| 1.4 — `deploy_remote.py` | 2 days |
| 2 — widget MVP (WPF) | 3-4 weeks |
| 2 — widget parity | +4-6 weeks |

The daemon alone is the good trade. The widget is a genuine rewrite and
should only start once you know you want a Windows box as a *primary*
machine rather than a remote host.

## The cheap alternative worth naming

If the Windows machine is a secondary/work box rather than your primary, you
do not need the widget at all. Phase 1 alone makes it a Shape-C remote host:
the Windows daemon writes `state.json` locally, `remote_sync.py` on the Mac
merges it over ssh under `host::<sid>` keys, and the Mac widget shows and
controls those sessions with zero new UI. That's ~2 weeks instead of ~8, and
it reuses machinery that already exists and is already tested — it just needs
`remote_ctl.py` to get B1 (the Windows lock) so a Windows box can serve as a
remote target.

The only thing missing in that world is the sshd side: Windows needs OpenSSH
Server enabled (an optional feature, one PowerShell command) and the
Scheduled Task from B6 to keep the daemon alive. That is the plan I'd start
with.

---

# Appendix A — maximizing shared code across both platforms

Written as a follow-up to the plan above. The question: what architecture
minimizes the ongoing cost of maintaining both platforms, not just the
one-time port cost?

## A.1 What actually churns (evidence, not intuition)

Measured over all 51 commits, by number of commits touching each file:

| File | Commits | Layer |
|---|---|---|
| `OverlayView.swift` | 21 | **widget UI** |
| `autoresume.py` | 20 | daemon logic |
| `AppDelegate.swift` | 20 | **widget UI** |
| `plan_fit.py` | 11 | daemon logic |
| `SessionsModel.swift` / `CloudSessionsModel.swift` | 10 / 10 | widget model |
| `GraphModel.swift` / `PlanFitModel.swift` / `ChatsFetcher.swift` | 9 / 9 / 9 | widget model |
| `SettingsWindow.swift` | 7 | **widget UI** |
| `ClaudeAPI/Client.swift`, `Models.swift`, `Validate.swift` | 3 / 3 / 2 | API surface (new — extracted at `103a9ae`; its predecessors `UsageFetcher`/`ChatsFetcher` carried this churn before, 6 and 9 commits) |

Three conclusions, and the third is the important one:

**1. The UI is the single biggest churn site.** `OverlayView` + `AppDelegate`
+ `SettingsWindow` alone account for 48 file-touches. Any plan that keeps two
hand-written UIs pays double on exactly the code that changes most.

**2. Features cross layers routinely.** `d3e8511` (session-key sign-in)
touched 16 files spanning ClaudeAPI, six widget files, and two daemon files.
`e449fec` (Enterprise spend limit) touched ClaudeAPI + `OverlayView` +
`UsageModel`. A seam placed mid-feature doesn't save work — it multiplies it.

**3. The existing Python-computes / Swift-renders seam is *not* cheap.**
`plan_fit.py` has 11 commits; `PlanFitModel.swift` has 9. They churn in
near-lockstep, because the Swift side is a hand-written parser tracking an
evolving JSON contract with nothing checking the two agree. That is direct,
in-repo evidence against the intuitive "just push all the logic into the
shared Python daemon and make the UIs thin" answer. Pushing more logic across
that seam without fixing the seam itself would make things worse, not better.

## A.2 The highest-leverage fix, independent of every other decision

**Version and machine-check the on-disk contracts.** There are five
cross-language file formats — `state.json`, `config.json`, `plan_fit.json`,
`usage/snapshots*.jsonl`, `usage/scoped_limits.json` — and their schemas
exist only as prose in `CLAUDE.md` plus matching hand-written readers and
writers. Nothing detects drift; you find out when a field silently reads as
`nil` in the UI.

This is exactly the problem `ClaudeAPI/CONTRACT.md` + `Validate.swift` already
solve for the *outward* claude.ai API. Apply the same pattern inward:

- `docs/contracts/*.schema.json` — one JSON Schema per format, versioned.
- A stdlib validator in the daemon that asserts its writes conform (cheap;
  runs in tests, not in the poll loop).
- A validator on each UI side that asserts its reads conform, wired into the
  same `--validate-*` style entry point that already exists.

Cost: ~2-3 days. Benefit: it makes the `plan_fit.py`↔`PlanFitModel.swift`
lockstep churn cheap, it is a prerequisite for *any* second UI, and it pays
off even if you never build one. **Do this first regardless of which path
below you choose.**

> **DONE 2026-07-26** — `docs/contracts/` + `claude-autoresume/contracts.py`
> + 74 round-trip tests against the real writers. It surfaced 24 drift
> findings; see `docs/contracts/README.md`. One of them is port-blocking:

### A.2.1 — PORT BLOCKER: no version gating (finding F0-1)

Four of the five on-disk formats carry **no version field**, and the one that
does (`config.json`) never gates on it. Every reader compensates with silent
per-field defaults, which makes "written by an older build" and "this file is
garbage" indistinguishable. The worked example already in the tree:
`throttle_days_*_per_month` kept its name across the 2026-07-26 cap-days →
lockout-time change while its *meaning* changed, with no signal to a reader.

Today that costs one divergence (Python writer vs Swift reader). **Under
Path 3 it costs three**, because the C# reader will invent its own third set
of defaults — and the same JSON is also the C ABI payload, so the divergence
propagates across the FFI boundary where it is hardest to debug.

Confirmed instances of the pattern, each verified in source:

| Finding | Site | Failure direction |
|---|---|---|
| F2-1 | `autoresume_config.py:123` defaults `enabled` **True**; `ConfigStore.swift:402` defaults it **false** | A hand-edited host with no `enabled` key is synced by the daemon while Settings shows it off. CLAUDE.md requires hand-editing to keep working. |
| F3-2 | `PlanFitModel.swift:274` — `viable ?? true` | A truncated verdict renders **every** tier viable and unflagged. Plan-fit fails toward "the cheap plan is fine." |
| F1-3 | `SessionsModel.swift:201` — `status ?? "active"`; only `project_dir` is mandatory | A malformed entry renders as a live session. |

**Required before any C# reader is written:** add a version field to all five
formats, gate on it, and decide per field whether a missing value is a
default or a rejection. Fixing the three sites above without fixing the
mechanism just moves the next instance somewhere else.

## A.3 The paths, ranked

### Path 1 — no second UI (maximum sharing: 100%)

Windows is a Shape-C remote host. One widget, one codebase. Covered in "The
cheap alternative" above.

Right answer if the Windows box is secondary. Nothing beats not writing the
code.

### Path 2 — one cross-platform UI, retire the Swift app

Rewrite the widget once in a cross-platform stack (Tauri is the pick from
§2 — WebView2 on Windows, WKWebView on macOS, tray on both) and delete the
Swift app once it proves out. Sharing: ~95% of the widget, plus the daemon
already at ~100%.

The non-obvious argument in favor: look at what the hardening work in
`CLAUDE.md` actually consisted of. Borderless-`NSPanel` resize needing raw
`NSEvent.mouseLocation`; kqueue watchers going stale on directory re-create;
`flock` per-inode semantics; `WKWebView` WebContent-process crashes. **Those
are AppKit/WebKit-specific traps.** In a Tauri app, window resize is CSS,
cookies are the runtime's problem, and file watching is a library. You don't
port those bugs — most of them stop existing. You do inherit a different set,
but you inherit *one* set instead of two.

Cost: ~8-10 weeks part-time to parity, and you're rewriting working software.

Right answer if Windows becomes primary or co-primary and you expect to keep
adding features for a while — which the churn data suggests you do.

### Path 3 — shared core, two native UIs

Extract the model layer (`UsageModel`, `SessionsModel`, `GraphModel`,
`PlanFitModel`, `CloudSessionsModel`, `ConfigStore`, `ClaudeAPI` — ~2,300 LOC)
into something both a Swift UI and a C# UI can call, leaving ~3,400 LOC of
per-platform view code.

Honest assessment: **the interop tax exceeds the benefit here.** Swift does
compile on Windows, but only Foundation/Dispatch — calling it from C# needs a
C ABI shim, and `ClaudeAPI/Client.swift` is built around `WKWebView` so its
transport needs abstracting anyway. Rust as the shared core works technically
(clean C ABI both directions) but adds a third language to a solo-maintained
project. And §A.1's finding stands: you'd be introducing a new seam of exactly
the kind that already costs double.

Name it, don't pick it — unless the shared core is small and stable, which
brings us to the one piece where this *is* right:

### Path 3a — share only the claude.ai API surface (worth doing under any path)

The one module with a real argument for language-independent extraction is
`ClaudeAPI`, because it tracks an external system that changes without notice
and it already has a contract document and a validator. Duplicating it in
Swift *and* C# means every internal-API break gets diagnosed and fixed twice.

If Path 2 happens this is moot — there's one implementation. If Path 3 or a
two-native-UI world happens, the cheapest sharing mechanism is not shared code
but a **shared contract plus a shared validator**: keep `CONTRACT.md` as the
single source of truth, and make `--validate-api` a suite both
implementations run against live endpoints. Second-best, but it catches drift
once instead of twice.

## A.4 Do-now list (increases sharing under every path)

Ordered by leverage per day of work:

1. **Versioned JSON Schemas for the five on-disk contracts + validators on
   both sides** (§A.2). ~2-3 days. Prerequisite for everything else.
2. **`deploy_remote.sh` → `deploy_remote.py`** (§1.4). Removes the bash
   dependency from the Mac too, and turns `PAYLOAD_FILES` from a
   regex-scraped shell array into a real constant.
3. **`check_api_boundary.sh` and `build_and_run.command` → Python.** Same
   reasoning; leaves zero bash in the repo.
4. **`platform_compat.py`** (§1.1). The daemon's sharing mechanism, and the
   template for how per-OS differences should be isolated everywhere else:
   one module, same interface, macOS implementation unchanged.
5. **CI matrix on `macos-latest` + `windows-latest`.** Once two platforms
   exist you can no longer test both at your desk. There's no CI today; this
   is the point where it starts paying.

Items 1-4 are all useful on a Mac-only future. None of them commit you to the
Windows port.

## Open questions for the owner

1. Is the Windows machine primary or secondary? (Decides Path 1 vs. Path 2 —
   and therefore whether Phase 2 exists at all.)
2. If a second UI happens: is retiring the Swift app on the table? If not,
   Path 2's economics collapse and you're in Path 3 with its double-maintenance
   cost accepted going in.
3. Is the session-key-only HTTP shortcut (§2.1) acceptable, given it puts a
   real credential in app storage for the first time?
