# claude-widget

A macOS menu-bar widget + background daemon for people who run a lot of
Claude sessions and want to actually *see* them: live usage meters, an
API-equivalent cost graph, plan-fit analysis, a unified list of every
Claude Code / Cowork / cloud session (local **and** on remote SSH hosts),
and opt-in auto-resume for sessions cut off by a rate limit.

Two cooperating components, talking through files in `~/.claude-autoresume/`:

| Component | What it is | What it does |
|---|---|---|
| **ClaudeUsageOverlay** | Swift/AppKit menu-bar app (SwiftPM, no Xcode project) | Usage bars (Max session/weekly % — or dollar budget bars for API-billed accounts), cost/utilization graphs, plan-fit tab, unified sessions list, Settings window |
| **claude-autoresume** | Python daemon, **stdlib only**, launchd-managed | Watches Claude Code transcripts + Cowork sessions, classifies each session's status (`running` / `needs_input` / `idle`) from on-disk evidence, tracks rate-limited sessions, optionally auto-resumes the ones you explicitly arm, syncs sessions from remote SSH hosts |

## Features

- **Usage at a glance** — Max plan session (5h) and weekly bars with a
  projection dot showing where you'll land by reset; API-billed accounts get
  weekly/monthly **dollar budget bars** instead (spend, projection, and the
  dollar overrun when you're on track to blow through the limit).
- **Cost graph** — API-equivalent cost of your usage over 5h/24h/7d/1mo/3mo,
  with measured totals and full-period estimates. Pricing comes from a live
  LiteLLM price feed (daily refresh) with an override file and bundled
  fallbacks — never hardcoded-only.
- **Plan fit** — moving averages, monthly run rate, cost/utilization peaks,
  and a tier recommendation (Pro / Max 5x / Max 20x) computed from your own
  observed usage.
- **Sessions list** — local Claude Code CLI sessions, Cowork sessions,
  claude.ai cloud sessions, and recent chats, merged and sorted by status.
  Configurable idle retention.
- **Remote SSH hosts** — add a host in Settings and the daemon payload
  auto-deploys over ssh (systemd user unit, or nohup fallback). Remote
  sessions appear in the widget with a host badge; their token usage folds
  into your budget; auto-resume fires natively on the remote host.
- **Opt-in auto-resume** — when a Code session hits a rate limit, arm it in
  the widget and the daemon resumes it (`claude --resume`) once the limit
  resets. **Nothing ever auto-resumes without an explicit per-session
  toggle.**

## Requirements

- macOS 13+ (Apple Silicon or Intel), with the system `python3` (≥ 3.9)
- [Claude Code](https://claude.com/claude-code) and/or Claude Desktop
- A claude.ai account (the widget signs into claude.ai in an embedded
  WebKit view to read usage/session data; credentials stay in the app's own
  WebKit cookie store and are never written anywhere else)
- Remote hosts: ssh key-based auth (`BatchMode` — no password prompts) and
  `python3` ≥ 3.9 on the remote

## Install

```bash
git clone https://github.com/samxhuang/claude-widget.git
cd claude-widget

# 1. The daemon (launchd agent; also stages the remote-deploy payload)
cd claude-autoresume && ./install.sh && cd ..

# 2. The widget (builds release, packages the .app, launches it)
cd ClaudeUsageOverlay && ./build_and_run.command
```

Or grab the pre-built `ClaudeUsageOverlay.app` from the
[latest release](https://github.com/samxhuang/claude-widget/releases) —
it's unsigned, so on first launch right-click → Open (or
`xattr -d com.apple.quarantine ClaudeUsageOverlay.app`). You still need
step 1 for the daemon.

Look for the gauge icon in your menu bar. First launch opens a claude.ai
login window; after that, everything is automatic.

## Settings

Everything is configured from the Settings window (menu-bar icon →
Settings…, or the gear on the panel) — no config files to edit:

- **Account & Budget** — Max tier (Pro / 5x / 20x) or API billing, with
  weekly/monthly dollar budgets. Buffered behind Apply/Cancel.
- **Sessions** — how long idle sessions stay listed (5 min – 24 h).
- **Remote Hosts** — add `user@host` (or an `~/.ssh/config` alias), test the
  connection, and it deploys automatically with a step-by-step checklist.
  Remove offers a full remote uninstall.

Configuration lives in `~/.claude-autoresume/config.json` (the Settings
window is its only writer; hand-editing works but is never required).

## Privacy & safety posture

- Everything runs and stays on your machine(s): transcripts are read from
  `~/.claude/projects`, state lives in `~/.claude-autoresume/`, and the only
  network calls are to claude.ai (your own account, via the embedded
  login), the LiteLLM public pricing feed, and your own ssh hosts.
- No telemetry, no third-party services.
- Auto-resume is **per-session opt-in**, default off, and resumed sessions
  run with `acceptEdits` permission mode (not `bypassPermissions`) — an
  unattended resume may stall on a permission prompt rather than run fully
  trusted. Override via `AUTORESUME_PERMISSION_MODE` if you knowingly want
  otherwise.
- The claude.ai endpoints the widget reads (`/api/organizations/*/usage`,
  `/recents`, chat lists) are internal and undocumented — they can change
  without notice, in which case those panels degrade gracefully until
  updated.

## Uninstall

```bash
cd claude-autoresume && ./uninstall.sh   # stops + removes the launchd agent
rm -rf ~/.claude-autoresume              # state, config, usage history
# quit the menu-bar app and delete ClaudeUsageOverlay.app
# remote hosts: ./deploy_remote.sh <host> --uninstall
```

## Development

- Widget: `cd ClaudeUsageOverlay && swift build -c release` (or
  `./build_and_run.command` to build+package+relaunch).
- Daemon: edit under `claude-autoresume/`, run the test suites directly —
  `python3 test_autoresume.py`, `test_plan_fit.py`, `test_remote_sync.py`,
  `test_usage_collector.py` — then `./install.sh` to deploy locally.
- `CLAUDE.md` documents the architecture, the on-disk contracts between the
  two components, and the hard constraints (start there before changing
  anything).

## License

[MIT](LICENSE)
