# claude-widget

Two components that watch and surface Claude Code / Cowork / Desktop session
activity on this Mac, talking to each other through a shared file.

- **ClaudeUsageOverlay** — Swift/AppKit menu-bar widget (SwiftUI content
  hosted in a borderless `NSPanel`). Shows session/weekly usage %, a Graph
  tab, a Plan-fit tab, and a unified Sessions list (local CLI, Cowork, cloud,
  and claude.ai chats merged and sorted by status).
- **claude-autoresume** — Python daemon (stdlib only), launchd-managed,
  deployed from `claude-autoresume/*.py` to `~/.claude-autoresume/bin/` via
  `claude-autoresume/install.sh`. Polls `~/.claude/projects/**/*.jsonl` (Code
  CLI transcripts) and `~/Library/Application Support/Claude/
  local-agent-mode-sessions/` (Cowork), classifies each session's status,
  and writes `~/.claude-autoresume/state.json`. Auto-resume only fires for
  sessions explicitly armed from the widget — nothing is automatic by
  default.

Owner is on Claude Max 20x; local transcript history and plan-fit data
collection both start 2026-07-18, so 30d/90d moving averages don't mature
until Aug/Oct 2026 — don't be surprised by sparse plan-fit numbers before
then.

## Hard constraints (do not relax without explicit sign-off)

- **Opt-in only.** Nothing auto-resumes or auto-automates without an
  explicit per-session toggle in the widget. `cowork_resume.py` has
  `DRY_RUN = True` hardcoded — live UI automation of Claude Desktop needs
  explicit sign-off first, separate from the dry-run scaffolding already
  landed.
- **Daemon is pure stdlib.** It runs under the system `python3` via launchd
  (see the plist template) — no pip dependencies in `autoresume.py` or
  anything it imports at daemon-runtime (`cowork_resume.py`,
  `usage_collector.py`, `plan_fit.py`). `chat_history.py` and its
  `ccl_chromium_indexeddb`/`python-snappy` deps are a standalone research
  module, not imported by the daemon.
- **Pricing is never hardcoded-only.** `plan_fit.py` resolves: override file
  → fetched LiteLLM cache (daily refresh) → bundled defaults. Keep that
  fallback chain if touching pricing.
- **The widget never truncates `~/.claude-autoresume/usage/snapshots.jsonl`.**
  It only appends; the Python compactor owns pruning.
- **`state.json` writes go through the flock-based lock** (`StateLock` in
  `autoresume.py`; Swift side does the equivalent before writing back
  `enabled`/`force_resume`/etc.). Respect that when adding fields.

## Build / deploy

- Widget: `cd ClaudeUsageOverlay && ./build_and_run.command` — builds
  release, kills any running instance, repackages `ClaudeUsageOverlay.app`,
  relaunches. No Xcode project; it's a SwiftPM executable target.
- Daemon: edit `claude-autoresume/autoresume.py` (or the other `.py`
  modules) in the repo, then `cd claude-autoresume && ./install.sh` —
  copies to `~/.claude-autoresume/bin/`, rewrites the LaunchAgent plist, and
  bounces launchd (`bootout` + `bootstrap`). Tail
  `~/.claude-autoresume/daemon.log` to confirm a clean restart.
- Neither has an automated test runner wired to CI (no CI configured).
  `claude-autoresume/test_autoresume.py`, `test_plan_fit.py` and
  `test_usage_collector.py` can be run directly with `python3`.
- Remote: `origin` → github.com/samxhuang/claude-widget.

## Session/status data flow

`state.json` (`~/.claude-autoresume/state.json`) is the contract: one dict
keyed by session id (the CLI transcript UUID, or a Cowork `local_<uuid>`),
each entry carrying `project_dir`, `session_title`, `status` (`active` /
`waiting` / `resumed` / `failed`), `work_status` (`running` / `needs_input`
/ `idle` — daemon-computed every poll, display-only), `enabled` /
`force_resume` (widget-owned, drive auto-resume), and Cowork's
`resume_armed`/`needs_attention`.

`work_status` classification (`classify_work_status` in `autoresume.py`) is
evidence-based, not time-guessed — see the big comment above
`WORK_STATUS_RUNNING_WINDOW_SECONDS` for the on-disk signals it keys off
(pending `tool_use` block flushed before results, `~/.claude/sessions/
<pid>.json` → process table → shell-snapshot children for "is Bash actually
executing", subagent/tool-result sidecar mtimes for delegated work, explicit
`stop_reason == "end_turn"` for a clean finish). If you touch this function,
re-derive the rules from that comment rather than guessing — it was written
against live ground-truth sessions, not speculation.

## Robustness hardening pass (2026-07-19, later session)

A full audit → fix → re-audit × 2 cycle over both components. Tests green
(79 Python tests incl. new `test_autoresume.py`, `swift build -c release`
clean). Deploy status at commit time: **widget deployed**
(build_and_run.command run several times since), **daemon NOT redeployed** —
`install.sh` was sandbox-blocked, so the fixed Python is not live until the
owner runs it. Note the widget's snapshot appends now take
`usage/snapshots.lock`, which the still-deployed old compactor doesn't take —
run install.sh to complete the pair. Highlights (each was empirically
confirmed before fixing):

1. **Lock actually locks now.** `SessionsModel.withLock` used to call
   `FileManager.createFile` on the lock file first, which REPLACES the inode
   every call — flock is per-inode, so widget/daemon mutual exclusion was
   illusory (verified: inode changed per call; post-fix, a Python flock-holder
   blocks the Swift acquisition path). Never reintroduce createFile there, or
   in `SnapshotLogger`'s lock.
2. **No more spurious auto-resume into live sessions.** The rate-limit scan
   (`_parse_cli_transcript`) now treats a rate_limit event as current only at
   the effective transcript tail (breaks on any genuine user/assistant turn;
   still skips metadata + the limit's own `<synthetic>` notice). Tradeoff
   accepted: a user message queued after a cutoff cancels "waiting".
3. `parse_reset_timestamp` normalizes stringified epoch-ms (was parsing
   "17529…000" as year ~57k → never resumed).
4. **Resume default is now `acceptEdits`**, not bypassPermissions
   (AUTORESUME_PERMISSION_MODE still overrides). Widget tooltips disclose it.
5. **Daemon poll rearchitecture**: all transcript reading/parsing/classifying
   happens OUTSIDE StateLock (`compute_*_records` → `merge_*_records` under
   the lock), with an (mtime,size)-keyed parse cache (`_PARSE_CACHE`, ~10x
   cheaper warm) — merge preserves widget-owned fields exactly. Usage
   analytics moved to a daemon thread. Widget side: all locked I/O moved off
   the main thread onto a serial queue.
6. **snapshots.jsonl append/compact race closed** via a shared flock at
   `usage/snapshots.lock` — Swift appender holds it per append, Python
   `compact()` holds it across its stage-1 read→rename. Keep both sides.
7. **Explicit `kind: "cli"|"cowork"` field** on every state.json entry is now
   the type sentinel (project_name == "Cowork" is only a legacy fallback).
8. `ClaudeWebSession` recovers from launch-time navigation failures AND
   WebContent-process crashes (backoff retry; `didFailProvisionalNavigation`
   implemented). Backlog cap rejects the NEWEST call with `.backlogFull`
   (never evicts queued closures — evicting stranded
   `ChatsFetcher.recentsInFlight` forever).
9. Title dedupe tightened both layers: local-local only collapses when ≤1 of
   the group is recently active (mixed groups show only the live rows);
   cloud-local skips generic titles ("Cowork session", "General coding
   session", "Untitled") and only matches recently-active local titles.
10. Smaller: corrupt state.json backed up to `state.json.corrupt` before
    starting fresh; latest (not first) `cwd` wins for resume; daemon.log
    rotates at 5MB and no longer double-writes to launchd.out.log; org
    selection prefers capability-matched org over `orgs[0]`; state-dir
    watcher survives dir deletion; `mutate()` failures NSLog'd.

## What changed this session (2026-07-19) — checkpoint before next feature work

All of the below is committed as of this checkpoint tag. Read this before
picking up new work so you don't re-diagnose the same things.

1. **Resizable panel (three bugs, one drag handle).** The panel is
   borderless (`NSPanel` with `.borderless` in its styleMask), and borderless
   windows never get AppKit's native edge-drag resize no matter what's in
   `styleMask` — there's no themed border to hit-test. Fixed with a custom
   `ResizeHandleView` (raw `NSView`, `AppDelegate.swift`/`OverlayView.swift`)
   using `NSEvent.mouseLocation` (real screen coordinates) instead of
   SwiftUI's `DragGesture` — the gesture's own coordinate frame moves as the
   handle (pinned to the resizing edge) repositions itself, which was
   silently undercounting drag distance by about half. Also fixed: (a)
   visible stutter, caused by `panelSize` being `@ObservedObject` directly on
   `OverlayView` so every drag tick re-ran the whole body including
   `combinedSessionRows`' sort — isolated into a small leaf view
   (`ResizableSessionsHeight`) that alone observes it; (b) the resize floor
   was wrongly pinned to the *default* Sessions height, so the panel could
   only grow, never shrink — added a real, separate
   `SectionLayout.sessionsMinContentHeight` (~1.5 rows) and allowed
   `PanelSizeState.userExtraHeight` to go negative.
   **Externally to this conversation** (already in the tree, don't re-fix):
   panel *moving* (drag-to-reposition) got the same NSEvent-based treatment
   via a parallel `MoveHandleView`, scoped to just the title row so it
   doesn't fight the resize handle — this replaced the old
   `isMovableByWindowBackground` whole-panel-drag-anywhere behavior.

2. **Click-to-open duplicate tabs (local sessions).** `claude://resume?
   session={id}` (Desktop's deep link) always creates a distinct
   `local_<id>`-prefixed imported session server-side
   (`LocalSessionManager.importCliSession` in Claude.app's `app.asar`), with
   no awareness of any pre-existing native tab for that same transcript. First
   diagnosed against Cowork rows (duplicate "General coding session" tab,
   plus it silently switched focus away from the live tab, which read as
   "auto mode got turned off" — it hadn't, focus had just moved to a
   different session object that never had it set). A follow-up report
   showed the identical symptom on plain Code/CLI rows too, so the "CLI has
   no competing native tab" assumption was wrong in general. Fix: removed
   the deep link entirely for **all** local rows — `openLocalSession` in
   `OverlayView.swift` now just foregrounds Claude Desktop
   (`NSWorkspace.openApplication` by bundle id
   `com.anthropic.claudefordesktop`) and leaves tab selection to the user.
   If a future fix wants the direct-open convenience back, it needs a way to
   detect an existing native tab from outside Desktop's process — nothing
   like that is currently known to exist.

3. **Deleted sessions lingering in the widget.** Two independent causes,
   both fixed:
   - Daemon (`autoresume.py`): Desktop's "Delete" archives a session
     (`isArchived: true` in the Cowork metadata / cloud `/recents` status)
     rather than removing files. `scan_cowork_sessions` skipped archived
     entries with an early `continue` *before* reaching its own cleanup
     logic, and `scan_sessions` only ever cleaned up a CLI entry when it
     revisited an existing jsonl file and found it stale — a fully deleted
     file is just never revisited, so it wasn't cleaned up either. Both
     cases eventually got caught by `prune_old_entries`'s
     `ACTIVE_STALE_MINUTES` (60 min) safety net, but only after a long,
     visibly-wrong delay. Added `prune_deleted_sessions` (checks on-disk
     existence / archived-state directly, independent of any scan-window
     cutoff) to the poll loop, so deletion reflects on the very next 10s
     cycle. Caveat documented in that function: deleting Desktop's own
     imported copy of a CLI session does not necessarily delete the
     underlying `~/.claude/projects` transcript — if that file still exists,
     the widget correctly keeps showing it.
   - Widget (`CloudSessionsModel.swift`): cloud `/recents` rows with
     `status == "archived"` and an idle worker are now filtered out
     client-side too (this also incidentally cleans up cloud-side echoes of
     the old duplicate-tab imports from bug #2, once those dupes are
     deleted).

4. **`work_status` false `needs_input` for sessions running a subagent.**
   `SUBAGENT_TOOLS = {"Agent", "Task"}` was already defined in
   `autoresume.py` with a comment saying a pending subagent call's liveness
   should be judged by sidecar-file freshness, not an age timeout — but
   it was never actually referenced in `classify_work_status`. A pending
   `Agent`/`Task` tool call fell into the generic "invisible/remote tool"
   bucket (`PENDING_SLOW_GRACE_SECONDS`, 60s — meant for WebFetch/MCP), and
   subagent work routinely goes quieter than that between disk writes (long
   thinking bursts, slow nested tool calls), so it kept flipping to
   `needs_input` while genuinely still running. There is no valid
   `needs_input` reading for a pending Agent/Task call at all — any
   human-facing approval happens inside the *subagent's own* transcript, not
   as a blocking state on the parent. Fixed by giving `SUBAGENT_TOOLS` an
   effectively infinite grace in that fallback. Verified against a live
   session before deploying (see commit — reproduced the false positive,
   confirmed the fix flips it to `running`).

5. **Usage bars: estimated-usage projection.** Added to both the Session
   (5h) and Weekly bars: a small dot marking where usage is projected to
   land by reset (linear extrapolation from elapsed vs. remaining window
   time — `UsageModel.estimatedPercent`), turning red and pinning at 100% if
   the projection would exceed it, plus a muted `"(N%)"` next to the actual
   percent label. No estimate shown in the first minute of a window (too
   little data to extrapolate from).

## Open threads / things a future session might reasonably pick up

- Click-to-open for local sessions is now a "just foreground Desktop, no
  navigation" fallback (see #2 above) — a genuine fix would need a reliable
  way to detect Desktop's existing native tab for a given CLI session id,
  which isn't currently known to be exposed anywhere externally.
- Cowork auto-resume automation (`cowork_resume.py`) is still hardcoded
  `DRY_RUN = True` — logs intended actions, never clicks anything. Needs
  explicit sign-off before flipping live per the hard constraints above.
- `chat_history.py` (direct IndexedDB/LevelDB decoding of Desktop's local
  chat cache) is research-stage, not wired into the daemon or widget — the
  claude.ai internal API via the widget's authenticated `ClaudeWebSession`
  WKWebView is the path actually in use for chat data today.
