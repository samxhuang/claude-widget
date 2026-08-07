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

## ClaudeAPI module (claude.ai internal-API isolation, 2026-07-19)

All knowledge of claude.ai's internal HTTP API (endpoint paths, JSON field
names, status vocabularies, deep-link URL shapes) lives in ONE SwiftPM
target: `ClaudeUsageOverlay/Sources/ClaudeAPI/` (WebSession = hidden authed
WKWebView transport; Client = ClaudeAPIClient, the only entry point; Models
= public DTOs; DeepLinks = ClaudeWebURLs; Validate = contract validator;
CONTRACT.md = observed endpoint shapes, kept current). When the internal
API changes, fix that module only — the app consumes typed DTOs
(UsageReport / ChatConversation / CloudSessionRecord / CloudWorkState) and
must not learn raw field names. Enforced by
`scripts/check_api_boundary.sh` (grep; comment lines allowed; carve-out
for SnapshotLogger/GraphModel/PlanFitModel which own widget-side on-disk
formats whose names historically mirror the API's but are frozen
independently). Contract validation:
`ClaudeUsageOverlay.app/Contents/MacOS/ClaudeUsageOverlay --validate-api
[--json] [--dump-raw <scratch-dir>]` — must run from the PACKAGED app
binary (cookie-store bundle-id keying), exits 0 pass / 1 contract drift /
2 logged-out. The `/validate-claude-api` command
(`.claude/commands/validate-claude-api.md`) wraps the full
validate→diagnose→fix-module-only→re-verify loop; design rationale in
`docs/claude-api-module-plan.md`.

## Hard constraints (do not relax without explicit sign-off)

- **Opt-in only.** Nothing auto-resumes or auto-automates without an
  explicit per-session toggle in the widget. `cowork_resume.py` has
  `DRY_RUN = True` hardcoded — live UI automation of Claude Desktop needs
  explicit sign-off first, separate from the dry-run scaffolding already
  landed.
- **Daemon is pure stdlib.** It runs under the system `python3` via launchd
  (see the plist template) — no pip dependencies in `autoresume.py` or
  anything it imports at daemon-runtime (`cowork_resume.py`,
  `usage_collector.py`, `plan_fit.py`, `autoresume_config.py`).
  `chat_history.py` and its `ccl_chromium_indexeddb`/`python-snappy` deps are
  a standalone research module, not imported by the daemon. The same
  constraint applies to anything deployed to remote SSH hosts
  (`remote_ctl.py`, the daemon payload) — remote boxes only get system
  `python3`.
- **Pricing is never hardcoded-only.** `plan_fit.py` resolves: override file
  → fetched LiteLLM cache (daily refresh) → bundled defaults. Keep that
  fallback chain if touching pricing.
- **The widget never truncates `~/.claude-autoresume/usage/snapshots.jsonl`.**
  It only appends; the Python compactor owns pruning.
- **`state.json` writes go through the flock-based lock** (`StateLock` in
  `autoresume.py`; Swift side does the equivalent before writing back
  `enabled`/`force_resume`/etc.). Respect that when adding fields.
- **`config.json` writers.** The MAC's `~/.claude-autoresume/config.json`
  has exactly one writer: the widget's Settings window (via ConfigStore,
  flock on `config.json.lock`, tmp+rename, unknown keys preserved). The
  Python side (`autoresume_config.load_config`) only reads, is fully
  defensive, and treats a missing/malformed file as the defaults; hand-
  editing works but is never required. A REMOTE host's config.json may
  additionally be written by `remote_ctl.py apply-config` — solely as a
  relay of the widget's settings (currently
  `sessions.idle_retention_minutes`, pushed by `remote_sync`'s retention
  relay), same lock + atomic-write discipline, never touching any other
  key. The daemon itself never writes config.json on any host.
  Note: retention convergence is ONE-WAY by design — on an enabled remote
  the Mac's Settings value always wins (the relay re-pushes whenever the
  remote's dump reports a differing value), so a remote operator cannot
  keep a locally-set retention while the host is enabled; disable the host
  in Settings if a remote needs to own its own value. Flagged for explicit
  sign-off if two-way (or per-host) retention is ever wanted.

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
  `claude-autoresume/test_autoresume.py`, `test_plan_fit.py`,
  `test_usage_collector.py` and `test_remote_sync.py` can be run directly
  with `python3`.
- Remote: `origin` → github.com/samxhuang/claude-widget.
- Remote SSH hosts: `claude-autoresume/deploy_remote.sh <user@host>` (also
  staged into `~/.claude-autoresume/bin/` and invoked automatically by the
  widget's Settings → Add Host). Non-interactive; emits `@@STEP/@@OK/@@FAIL`
  markers the widget parses. See README's "Remote hosts (SSH)" section.

## API-budget + remote-SSH phase (2026-07-19, second session)

Landed da82606..88c640e: `config.json` (account type + weekly/monthly dollar
budgets + remote hosts; widget's Settings window is the ONLY writer, Python
only reads via `autoresume_config.load_config`), budget bars replacing the
Max % bars for `account.type == "api"` (spend from the existing plan_fit
cost pipeline, remote hosts' tokens folded in as `code_cli@<host>`
surfaces), and Shape-C remote sessions: the same daemon runs on each remote
host (`AUTORESUME_REMOTE=1`, systemd user unit or nohup), `remote_sync.py`
on the Mac merges its state over ssh (`remote_ctl.py dump`/`apply-toggles`,
`host::<sid>` keys, clock-skew-adjusted, one-shot `force_resume` handoff),
and remote resumes fire natively on the remote — opt-in toggles relayed
from the widget. Two adversarial audit/fix rounds followed the initial
5-agent build; notable traps documented in the code: the sync thread always
starts (idle, lock-free tick) so the first host added at runtime works; the
deploy payload MUST include `remote_sync.py` (top-level import — regression
tests parse `PAYLOAD_FILES` out of deploy_remote.sh); the deploy verify
stage checks real daemon liveness, not just `remote_ctl.py`. Not yet done:
live end-to-end test against a real remote host (no test host was
reachable this session).

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

5. **Throttle-tolerance plan-fit verdict (replaces peak-based viability).**
   A tier's `viable` flag no longer means "the all-time projected peak never
   crossed 100%" (one monster session permanently vetoed cheaper tiers). It
   now counts **projected cap-days** — superseded 2026-07-26 by projected
   lockout TIME, see the section below; the rest of this entry still
   describes the plumbing. Per-UTC-day peak utilization
   (`_daily_peaks` — per-day maxima survive bucket compaction, unlike
   percentiles) rescaled per tier, days ≥100% counted and normalized to a
   30-day month (`_tier_throttle`), viable when within tolerance
   (`THROTTLE_TOLERANCE_*`: 5h ≤1 cap-day/mo, 7d 0 — weekly-cap lockouts are
   treated as disqualifying). Severity (median cap-day peak) and
   `price_delta_vs_current_usd` ride along in `verdict.plans`;
   `throttle_projection` + `verdict.throttle_tolerance` are new top-level
   report blocks; the 7d tolerance compare uses exact rates, not the
   display-rounded ones. Widget: tier grid's last column is now "Cap d/mo"
   (with peak/severity in the tooltip), and `TierVerdict.isFlagged` trusts
   the backend verdict when throttle fields are present — the legacy local
   peak>100 red-flag only applies to old plan_fit.json files, since a >100%
   peak on a viable tier is now expected, not an error. All-time peaks stay
   in the report/UI as context only. The recommendation string is succinct
   and always peeks at the adjacent tier: one tier DOWN when the
   recommended tier fits ("A tier down, Max 5x would be capped ~30 d/mo
   (5h)…"), one tier UP when the current plan is over tolerance. The widget
   now actually renders it (plus the data-maturity line) on the Plan-fit
   tab — it had been parsed-but-never-displayed since the tab was built —
   and because the fixed `planFitPanelHeight` was probe-measured before
   those lines existed, `AppDelegate.planFitTextExtra()` measures the live
   strings (NSString boundingRect at render fonts) and adds that to the
   panel height so the text never clips.

6. **Usage bars: estimated-usage projection.** Added to both the Session
   (5h) and Weekly bars: a small dot marking where usage is projected to
   land by reset (linear extrapolation from elapsed vs. remaining window
   time — `UsageModel.estimatedPercent`), turning red and pinning at 100% if
   the projection would exceed it, plus a muted `"(N%)"` next to the actual
   percent label. No estimate shown in the first minute of a window (too
   little data to extrapolate from).

## Per-model (Fable) cap → waiting + auto-resume (2026-07-20)

Fable-limited (and any per-model-capped) CLI sessions were vanishing from the
widget's Sessions list. Root cause: the daemon only recognizes a "waiting"
(rate-limited) session from a `rate_limit`-**typed** transcript event (the
account-wide 5h/weekly cap, which carries its own `resetsAt`). A **per-model**
cap is a different shape — a plain `assistant` turn with
`isApiErrorMessage:true` + `apiErrorStatus:429` ("You've reached your Fable 5
limit…"), model `<synthetic>`, and **no reset time of its own**. So it was
never marked waiting; the session went silent and aged out of the ~35m scan
window. The reset time DOES exist, but only on the usage page — the usage
endpoint's `limits[]` array has a `kind:"weekly_scoped"`,
`scope.model.display_name:"Fable"`, `is_active`, `percent`, `resets_at` entry.

Fix spans all three layers (the daemon is pure-stdlib and can't reach
claude.ai, so the reset is **relayed** from the widget):

1. **ClaudeAPI** — `UsageReport.scopedLimits: [ScopedLimit]` parsed from
   `limits[]` (model-scoped entries only) in `Client.decodeUsage`; documented
   in CONTRACT.md; `--validate-api` prints active caps. Raw field names stay
   inside the module (boundary check still clean).
2. **Widget** — `ScopedLimitLogger` writes active caps to
   `~/.claude-autoresume/usage/scoped_limits.json` (atomic replace, widget's
   own frozen on-disk format like snapshots.jsonl; single-writer → no flock),
   fired from `UsageFetcher` on every usage fetch.
3. **Daemon** (`autoresume.py`) — `_parse_cli_transcript` detects a 429
   model-limit tail *only when there's no structured `rate_limit` event*
   (the 5h cap emits both; regression-tested), captures the concrete model
   via `model_limit_model` (nearest non-`<synthetic>` assistant model).
   `compute_cli_records` marks it `waiting`, reset via `scoped_limit_reset`
   (family-token match, `normalize_model_token`: `claude-fable-5`↔`Fable`).
   `scoped_model` is stored on the entry; `reconcile_scoped_limit_resets`
   (poll loop, under lock, **independent of the scan window**) fills/refreshes
   the reset once the relay catches up — covers the case where the dead
   transcript already left the window. Auto-resume stays **opt-in**:
   `enabled` defaults False, resume fires via the unchanged
   `resume_due_sessions` (model left as-is on resume). A model-limited wait
   with `resets_at=None` shows but isn't armed; it's never quiet-pruned
   (waiting entries aren't, same as a 5h wait).

Tests: `TestScopedModelLimits` + `TestReconcileScopedResets` in
test_autoresume.py (63 total green). **Deploy status: widget rebuilt +
bundle binary swapped for --validate-api; daemon NOT yet redeployed** — run
`claude-autoresume/install.sh` to make the fixed daemon live, and
`ClaudeUsageOverlay/build_and_run.command` to relaunch the widget so it
starts writing scoped_limits.json. Until both run, existing already-vanished
Fable sessions won't retroactively reappear (their transcripts are long out
of window); the fix catches *future* Fable caps while they're still fresh.

## Plan-fit: cap-days → lockout TIME (2026-07-26)

The throttle verdict's unit was wrong, and wrong in the aggressive
direction. Counting UTC days whose projected peak touched 100% charged a
whole day for a cap hit in the last hour of a window, and — because a
weekly window's utilization stays over the line until it resets — charged
every remaining day of that week too, so a single early-week overrun read
as "capped ~30 d/mo". The metric now measures what it always meant: **how
much time the tier would leave you unable to work**.

- `_utilization_segments(points)` re-expresses the merged snapshot series
  as time segments — raw sample pairs (interval between them, endpoints as
  the range), compacted buckets (nominal 15m/1h span, min/max as the range,
  coverage capped at `n * LOCKOUT_SAMPLE_NOMINAL_SECONDS` so a sparse
  bucket isn't credited a full hour). Holes wider than
  `LOCKOUT_MAX_SAMPLE_GAP_SECONDS` (widget/Mac off) count as neither
  observed nor locked-out time.
- `_above_cap_fraction(low, high)` interpolates linearly across the
  crossing — for a raw pair that IS interpolation between samples; for a
  bucket it's the only defensible read from min/max alone.
- Segments carry BOTH dimensions (`ranges: {dim: (low, high)}`) rather than
  being built per-dimension, which is what makes the "either cap" aggregate
  a real union. `_tier_lockout` emits a third block, `any_cap`: union =
  `max(frac_5h, frac_7d)` per segment, overlap = `min(...)`, under a
  nested-interval model (both caps climb while you work, so within a segment
  both crossings sit at its busy end). Adding the two dimensions would
  double-count heavily — on live data Max 5x reads 87h + 644h but only 677h
  union. The block also carries `overlap_hours` + `<dim>_only_hours` so a
  consumer can name the binding cap; `_brief_capped_time` uses that for the
  recommendation's "(weekly cap)" / "(5h cap)" / "(5h + weekly caps)" tag.
- `_tier_lockout(segments, plan)` (replaces `_daily_peaks` +
  `_tier_throttle`) rescales each segment per tier and sums capped time.
  Emits `capped_hours_per_month` (the honest unit),
  `capped_days_per_month`, episode stats (`cap_episodes`,
  `median_episode_hours`, `longest_episode_hours` — "how long am I stuck
  when it happens"), `days_with_cap` (the old cap-day count, demoted to
  context) and `median_throttle_peak_pct`.
- Tolerances are hours/month now: `THROTTLE_TOLERANCE_5H_HOURS_PER_MONTH`
  = 5 (one fully-capped rolling window a month — the old "1 cap-day"
  intent stated honestly), `..._7D_...` = 2 (effectively none, with
  headroom for a brief end-of-window overrun / bucket-boundary noise).
  Day-equivalents stay in `verdict.throttle_tolerance` for old readers.
- Documented bias: the series was measured on the CURRENT plan, where
  usage kept accruing past the point a cheaper tier would have cut it off,
  so projected **5h** lockout is an upper bound. Weekly is unaffected (the
  window resets on a fixed schedule either way).
- `verdict.plans` gains `capped_hours_{5h,7d,any}_per_month` +
  `median_lockout_*` / `longest_lockout_*`; `throttle_days_*` keeps its
  name (older widget builds read it) but now means days' WORTH of lockout.
  Widget column renamed "Cap d/mo" → "Capped/mo", cell is
  "any 28d · 5h 3.6d · 7d 27d" (auto-unit via `PlanFitModel.lockoutText`:
  2.1d / 40m / 0), tooltip explains the union and typical lockout length.
  Recommendation strings say "locked out ~X (weekly cap)", not
  "capped N d/mo". The cell width was measured against the fixed 280pt
  panel (238pt of 256pt available at the widest realistic values) — check
  it again before adding a fourth number to that column.
- Tests: `LockoutVerdictTests` in test_plan_fit.py (86 in that file),
  headline cases
  `test_weekly_cap_hit_late_charges_only_the_time_left_in_the_window`
  and `test_either_cap_is_a_union_not_a_sum`.

## Windows-port foundation (2026-07-26) — no Windows code ships yet

Planning + platform-decoupling groundwork for a Windows port. **Nothing
Windows-specific is live**; every change below is behavior-preserving on
macOS and was accepted only on that basis. Plans: `docs/windows-port-plan.md`
(phases, blockers, Phase-0 recon table R1-R8) and `docs/swift-windows-audit.md`
(API inventory, toolchain status, verdict, 45-min Windows spike script in
§6.3). Chosen direction is **Path 3**: shared Swift core + native UI per
platform — but read the audit's §6.1 verdict first, which finds the
economics marginal and the shareable core smaller than the file list
suggests (~800-1,000 of 2,076 lines are the expensive-to-duplicate part).

**Decided, and load-bearing:** `ClaudeAPI` is split at the **transport/decode
line, not the WebSession file boundary**. `Client.swift` is not an HTTP
client — ~120 of its lines are JavaScript run inside an authenticated
WebView, and on Windows that WebView lives in C# above the FFI. Sharing it
as-written forces a bidirectional FFI carrying JS source. Don't build that.
Share DTOs + decoders; keep the fetch loop native per platform.

What landed:

1. **`claude-autoresume/platform_compat.py`** — the daemon's one OS seam
   (`FileLock`, path resolvers, `process_snapshot`, `spawn_detached`,
   `replace_with_retry`, `tool_child_markers`). POSIX branches are literal
   lifts of what they replaced. Windows branches exist but are unverified;
   every unknown is a single named constant tagged `# RECON-UNVERIFIED (Rn)`
   against the plan's recon table. **`platform_compat.py` is now a
   top-level import of autoresume/usage_collector/plan_fit/remote_ctl, so it
   MUST stay in `PAYLOAD_FILES`** (both deploy scripts) or the remote daemon
   crash-loops at import — same trap `remote_sync.py` already guards.
   `remote_ctl.py` now imports it: a deliberate exception to its
   "standalone" rule, because a re-typed lock primitive diverges silently
   and breaks cross-process exclusion by construction.
2. **`docs/contracts/` + `claude-autoresume/contracts.py`** — JSON Schemas
   for the five on-disk formats, a pure-stdlib validator, and round-trip
   tests that run the REAL writers. Surfaced 24 drift findings (see
   `docs/contracts/README.md`); the structural one is **F0-1: four of five
   formats have no version field**, so every reader compensates with silent
   defaults and "old build" is indistinguishable from "garbage". Fix that
   before any third reader exists. Confirmed instances:
   `autoresume_config.py:123` defaults host `enabled` **True** while
   `ConfigStore.swift:402` defaults it **false**; `PlanFitModel.swift:274`
   reads `viable ?? true` (a truncated verdict marks every tier viable);
   `SessionsModel.swift:201` reads `status ?? "active"`.
3. **`deploy_remote.py`** — stdlib port of `deploy_remote.sh`, **not yet
   wired up** (`HostDeployer.swift` still runs `/bin/bash`; no reachable
   test host). Marker equivalence is proven by running BOTH scripts against
   identical fake `ssh`/`scp` and byte-diffing stdout. Five latent bugs in
   the shell version are reproduced faithfully, not fixed — documented in
   `docs/windows-port-plan.md` §1.4.
4. **Combine removed from the model layer** — `Observation.swift` provides
   `Observable` + `@Observed` (36 conversions across 7 files). **View code
   changed zero lines.** Two invariants a future edit must not break: the
   setter fires `objectWillChange` BEFORE `stored` updates
   (`AppDelegate.swift:322` depends on willSet ordering), and the projection
   is a **`CurrentValueSubject`, not `PassthroughSubject`**, because
   `@Published` replays the current value to each new subscriber and
   `AppDelegate.swift:325` relies on that to seed the "Show Sessions" menu
   check state at launch. `HostDeployer.swift` still uses Combine on purpose
   (Apple-only `Process`/ssh code).
5. **`ClaudeAPI/JSONValue.swift`** — typed accessors replacing 23 unguarded
   `as?` scalar casts that worked only via ObjC bridging (two of them,
   `Client.swift` `loggedOut`/`ok`, gate every API response). Measured, not
   assumed: on Darwin `1 as? Bool` is `true` and `0 as? Bool` is `false`, so
   `jsonBool` accepting 0/1 is PARITY — "strict booleans only" would have
   been a silent narrowing. Boolean-ness is discriminated by
   `CFGetTypeID == CFBooleanGetTypeID`, since a JSON `true` also casts to
   `Int` 1 and a naive `as? Bool` guard would discard real 0/1 percents.
6. **`ClaudeAPI/Transport.swift`** — `ClaudeScriptRunner` protocol;
   `ClaudeAPIClient` no longer constructs `ClaudeWebSession` concretely.
   `ClaudeWebSessionError` → transport-neutral `ClaudeTransportError`.
   First unit tests for this client ever (`Tests/ClaudeAPITests`, 34 tests,
   swift-testing — this Mac has CLT only, no Xcode, so use
   `ClaudeUsageOverlay/run_tests.command`, not bare `swift test`).
7. **`GraphModel` UTC** — five `TimeZone(identifier: "UTC") ?? .current`
   fallbacks (which would have put LOCAL time into UTC-keyed bucket math)
   replaced with an arithmetic `TimeZone(secondsFromGMT: 0)!`. No bucket-key
   math changed. **`CoreLog.swift`** replaces 16 `NSLog` sites and passes the
   message as an argument, not a format string.

Test baseline is now **384 Python** (7 files: autoresume 63, plan_fit 88,
remote_sync 54, usage_collector 26, deploy_remote 48, platform_compat 31,
contracts 74) plus **34 Swift**. Earlier numbers in this file ("79 Python
tests", "63 total", "86 green") are per-file counts, not repo-wide.

**Deploy status: NOTHING redeployed this session.** The daemon changed
substantially — run `claude-autoresume/install.sh`. The widget changed —
run `ClaudeUsageOverlay/build_and_run.command`. Until both run, the live
daemon and widget are the pre-session builds.

## Budget projection basis: calendar days vs. weekdays (2026-08-06)

The API-mode budget bars already carried a projection dot (weekly AND
monthly — `budgetRow` passes `budgetProjectedPct` for both), but the
elapsed fraction it extrapolates on was always wall-clock calendar time.
For a weekday-only workload that reads low all week and sags further every
weekend: the numerator keeps the weekday spend, the denominator keeps
adding days that were never going to carry any.

New config key `budget.projection_basis` = `"calendar"` (default, exactly
the old behavior) | `"weekdays"`, applying to BOTH windows:

- `plan_fit.py`: `_budget_tz_helpers` factored out of
  `_budget_period_bounds` (period bounds and weekday-ness must be judged in
  the same timezone — the DST-safe per-date localization is unchanged, just
  moved); `_weekday_seconds(start, end, tzname)` intersects the interval
  with Mon–Fri calendar dates; `_budget_window` picks the elapsed/total pair
  off the basis and echoes `projection_basis` into the window (contract C2 —
  a NEW required field in `budgetWindow`; older files lacking it read as
  "calendar", which is what they were computed with). Weekend spend still
  counts toward `spent_usd` — only the extrapolation changes.
  `BUDGET_PROJECTION_MIN_ELAPSED_SECONDS` is measured in whichever clock is
  in use, so a month opening on a Saturday (Aug 2026) reports no projection
  until an hour into Monday rather than dividing by a near-zero denominator.
- `autoresume_config.py`: `VALID_PROJECTION_BASES` (duplicated from
  plan_fit's tuple on purpose — same standalone-deploy rule as
  `VALID_PLANS`); anything else degrades to "calendar".
  `_plan_fit_config_inputs` in autoresume.py includes the key, so changing
  it rewrites plan_fit.json within one poll instead of at the hourly cadence.
- Widget: `AppConfig.projectionBasis` + a "Project spend over" picker in
  Settings → Account & Budget (Every day / Weekdays only), written through
  the same per-field touched/untouched resolution as the other budget
  fields. `BudgetWindow.projectionBasis` feeds a new `.help()` on each
  budget bar saying which clock produced the dot — the setting isn't
  visible on the 280pt row, and the dot's position is meaningless without it.

Tests: `BudgetProjectionBasisTests` in test_plan_fit.py (6, incl. the
weekend-freeze and the Saturday-open suppression cases) + basis validation
in test_autoresume.py and the config schema in test_contracts.py. Baseline
is now **393 Python** (autoresume 65, plan_fit 94, remote_sync 54,
usage_collector 26, deploy_remote 48, platform_compat 31, contracts 75)
plus **34 Swift**; `swift build -c release` and the API-boundary check are
clean.

**Deploy status: still NOTHING redeployed** — this session's changes stack
on top of the undeployed Windows-port-foundation session. Both
`claude-autoresume/install.sh` and
`ClaudeUsageOverlay/build_and_run.command` are needed, and the option only
does anything on an `account.type == "api"` config (this Mac's is `max`).

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
