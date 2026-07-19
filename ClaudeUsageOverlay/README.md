# ClaudeUsageOverlay

The menu-bar widget half of [claude-widget](../README.md) — see the root
README for what it does, install steps, and the privacy/safety posture.

This folder is a SwiftPM executable target (no Xcode project):

```bash
./build_and_run.command   # build release, package ClaudeUsageOverlay.app, relaunch
swift build -c release    # compile only
```

## How the usage numbers work

There's no public API for "usage remaining" on a Claude subscription. The
widget runs a hidden `WKWebView` signed into claude.ai with your own session
cookie — the same way your browser would be — and periodically calls the same
internal requests the claude.ai web app makes for Settings → Usage
(`/api/organizations` → `/api/organizations/<id>/usage`), plus `/recents` and
the chat list for the Sessions panel. Credentials never leave the app's own
WebKit cookie store. These endpoints are undocumented and can change without
notice; when they do, the affected panels degrade to "collecting…"/"sign in
needed" states rather than breaking the app.

## Talking to the daemon

The widget reads `~/.claude-autoresume/state.json` (session list),
`usage/plan_fit.json` + the snapshot tiers (graphs, plan fit), and is the
sole writer of `config.json` (Settings) — all shared-file contracts are
documented in the repo root's `CLAUDE.md`. Every state.json/config.json
read-modify-write takes the same flock the daemon uses.
