# claude-autoresume / ClaudeUsageOverlay — handoff to Claude Code

Two related macOS projects built in a prior Cowork session, now moving to Claude Code for continued work.

## What this is

- **ClaudeUsageOverlay** — a Swift/AppKit menu-bar widget showing Claude session/weekly usage %, plus a "Sessions" list of Claude Code CLI and Cowork sessions that are active or got cut off by a rate limit.
- **claude-autoresume** — a Python daemon (launchd-managed) that polls for Code CLI and Cowork sessions, tracks their status, and (opt-in only, per-session, via a toggle in the widget) can auto-resume a Code CLI session once its rate limit resets. Nothing ever auto-resumes without the user explicitly arming that session — this is a hard design constraint, keep it that way.

They talk to each other via a shared file: `~/.claude-autoresume/state.json` (daemon writes, widget reads and can also write back — e.g. flipping `enabled`/`force_resume` — under an flock-based lock).

## Directories (all real paths on this Mac)

**Source / dev folder** (edit here, this is what's under version control mentally, though not yet a git repo):
```
/Users/sam/Library/Application Support/Claude/local-agent-mode-sessions/0c69632b-2aa7-448c-825c-cea87fee3004/7a211a9b-dfc9-48f9-897c-4f17e132d7e3/local_de72a183-3590-41b5-89bd-ebd57e357c59/outputs/
├── claude-autoresume/
│   ├── autoresume.py              # the daemon
│   ├── install.command / install.sh / uninstall.sh
│   ├── com.samhuang.claude-autoresume.plist.template
│   └── README.md
└── ClaudeUsageOverlay/
    ├── Package.swift
    ├── Info.plist
    ├── build_and_run.command
    ├── Sources/ClaudeUsageOverlay/
    │   ├── main.swift
    │   ├── AppDelegate.swift
    │   ├── UsageModel.swift         # 5h/weekly % fetching
    │   ├── UsageFetcher.swift
    │   ├── SessionsModel.swift      # reads/writes state.json
    │   ├── OverlayView.swift        # the panel UI
    │   └── LoginWindowController.swift
    └── ClaudeUsageOverlay.app       # last build output
```

Consider moving this whole folder out from under Claude Desktop's internal session storage (e.g. to `~/git/claude-autoresume-project/` or similar) and `git init`-ing it — it currently lives inside a Cowork session's ephemeral-looking path and isn't in version control.

**Deployed daemon** (installed via `install.command`):
```
~/.claude-autoresume/
├── autoresume.py       # deployed copy — re-run install.command after editing the source above
├── state.json           # shared state file, the daemon/widget contract
├── daemon.log
└── logs/<session>.log   # output from each auto-resumed session
~/Library/LaunchAgents/com.samhuang.claude-autoresume.plist
```

**What the daemon watches:**
```
~/.claude/projects                                        # Code CLI session jsonl transcripts
~/Library/Application Support/Claude/local-agent-mode-sessions   # Cowork session metadata + audit.jsonl
```

**Claude Desktop app itself** (relevant for the reverse-engineering work below):
```
/Applications/Claude.app/Contents/Resources/app.asar       # minified Electron source, readable via strings/grep
~/Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb/   # real chat content, LevelDB
~/Library/Application Support/Claude/Local Storage/leveldb/                          # Cowork/session UI state
```

## State so far (all verified working)

- Menu-bar panel collapse bug (SwiftUI/AppKit fighting over frame size) — fixed via `NSHostingView.sizingOptions = []` in `AppDelegate.swift`.
- Session titles shown (not just project folder name) — parsed from `ai-title`/`custom-title` events in the jsonl.
- Human-vs-internal message classification uses `origin.kind == "human"` on `type:"user"` events (an earlier Haiku-model heuristic was wrong and got replaced).
- "Active" detection considers subagent activity too (`<session>/subagents/*.jsonl` mtimes), not just the parent transcript file — otherwise long delegated tasks looked idle.
- Cowork sessions now show up in the widget with real titles, using `audit.jsonl`'s last-event `type` as a genuine running/idle signal (`type != "result"` = still running) rather than a time-based guess. Auto-resume toggle is hidden for Cowork rows since Cowork manages its own retry cycle.

## Two open tracks (research done, not yet implemented)

Both came out of reverse-engineering `app.asar` and the local LevelDB caches, cross-checked with a second-opinion model consult. Concrete plan below — pick up from here.

### Track 1 — Cowork session auto-resume

Currently Cowork sessions can't be auto-resumed (only detected/displayed). Investigated whether the app's internal `claude://resume` URL scheme or its internal `signalIntent({kind:"resume", sessionId})` IPC could be driven externally — concluded no: `claude://resume` is for importing a *Code CLI* transcript into the Desktop app (evidence: error strings like `"transcript_missing": "CLI session transcript not found"`), and the IPC handler is renderer-internal, only reachable via Chrome DevTools Protocol, which would mean launching Sam's daily-driver Desktop app with an open unauthenticated debug port — not worth the security tradeoff.

**Recommended approach instead:** the Desktop app has its own native "Resume" tab/space (confirmed via an internal enum: `Code`/`Design`/`Resume`/`Cowork`/`LocalSessions`). Drive that via OS-level accessibility/UI automation (same pattern already used to build/deploy this project), orchestrated from the Python daemon (it already owns session state), not from Swift.

Plan:
1. Add a second, distinct toggle state to the widget: `resume-armed` (separate from the existing per-session `enabled` opt-in — nothing arms automatically).
2. Daemon-side automation primitive: bring Claude Desktop forward → navigate to the Resume space (verify the actual label/location with a screenshot first, don't hardcode coordinates blind) → match the target session by title/id → click Resume.
3. Fail safe on ambiguity: Resume space or control not found → abort + flag "manual attention needed"; session not in the list → abort just that one, continue others; multiple armed-and-ambiguous matches → resume none, flag.
4. Verify success with a before/after screenshot check, not just "did the click happen."
5. **Gate: don't execute any live click against the real Desktop app until doing a dry run (screenshots + planned click targets, no actual clicking) and confirming the plan first.**

### Track 2 — Reading regular (non-Cowork) Desktop chat history locally

Confirmed feasible: `~/Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb/000006.log` contains real plaintext conversation content when grepped with `strings` (verified against an actual message from a real session). Values are V8 structured-clone-serialized and Snappy-compressed inside LevelDB though, so don't ship a strings-based hack — decode it properly.

Plan:
1. `pip install ccl_chromium_indexeddb python-snappy` (needs system `libsnappy`, `brew install snappy`).
2. Before reading: confirm Claude.app isn't holding an exclusive lock on the leveldb dir (or just always copy it to a scratch path first — never open the live one directly).
3. API shape: `WrappedIndexDB(path)` → enumerate `.database_ids` and each db's object store names first (schema isn't stable across app updates, discover it, don't hardcode) → `store.iterate_records()` → `rec.value` comes back as an already-deserialized dict.
4. Validate before trusting: decode 1-2 conversations visible in the live app, assert the text matches verbatim, assert record count > 0 and values are dicts not raw bytes.
5. Build as a small reusable module (`chat_history.py`: `read_conversations(path)`, `detect_schema(path)`), not a one-off script — but don't wire decoded content into `state.json` or the widget until showing Sam a decoded sample and getting explicit confirmation it's correct and something he actually wants surfaced there.

## Constraints to keep in mind

- No blind/silent automation — every resume or newly-surfaced-data feature needs an explicit per-item opt-in, matching the existing pattern.
- Both `app.asar` grepping and LevelDB reading are reverse-engineering internals with no stability guarantee — expect drift across Claude Desktop app updates, and design for graceful failure (detect schema, don't assume).
- The daemon polls every 30s and takes an flock lock around `state.json` reads/writes — respect that when adding new fields.
