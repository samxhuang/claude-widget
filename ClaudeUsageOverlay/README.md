# Claude Usage Overlay

A small always-on-top macOS widget, pinned to the top-right of your screen, showing
your Claude Pro usage: the current 5-hour session limit and the weekly limit, both
pulled live from claude.ai — the same numbers you'd see under **Settings → Usage**,
covering usage from the chat app, Claude Code, and Cowork combined.

It also lists any Claude Code sessions that got cut off by the rate limit
(detected by the companion **claude-autoresume** daemon — see the
`claude-autoresume/` folder) and lets you choose, per session, whether it
should auto-resume when the limit resets. Nothing resumes unless you
explicitly turn it on for that session, or hit "Resume Now."

## How it works

There's no public API for "usage remaining" on a Claude subscription. This app
works by running a hidden, invisible `WKWebView` (Apple's built-in web engine)
signed into claude.ai with your real session cookie — the same way your browser
would be — and periodically calling the two requests the claude.ai web app itself
makes when you open Settings → Usage:

```
GET https://claude.ai/api/organizations                     -> your org id
GET https://claude.ai/api/organizations/{org id}/usage      -> five_hour / seven_day usage
```

**Important caveats:**
- These are undocumented, unofficial endpoints. They could change or disappear
  without notice — if the overlay suddenly stops updating, that's likely why.
- This polls claude.ai every 2 minutes by default. That's deliberately conservative;
  don't lower it much further.
- This is for your own personal use with your own account. Don't distribute a
  build of this or automate it at higher frequency/scale.
- Your login session cookie lives only in this app's local WebKit data store —
  the same sandboxed storage a real browser would use. It isn't sent anywhere
  except claude.ai.

## What it shows

- **Session (5h):** percent used of your rolling 5-hour limit, and when it resets.
- **Weekly:** percent used of your weekly limit, and when it resets.

## Requirements

- macOS 13 (Ventura) or later
- Xcode (for the Swift toolchain — Xcode Command Line Tools are enough, you don't
  need to open Xcode itself if you'd rather use the Terminal)

## Build & run

### Option A — Terminal (fastest)

```bash
cd ClaudeUsageOverlay
./build_and_run.command
```

This compiles the app, packages it as `ClaudeUsageOverlay.app`, kills any
previous running instance, and opens it. The app has no Dock icon or window
by default — look for a small gauge icon in your menu bar (top of screen). A
login window will pop up automatically the first time, since you're not
signed in yet.

To quit: click the menu bar gauge icon → Quit.

Re-run `./build_and_run.command` any time you want to rebuild after a code
change — it replaces the running instance.

### Option B — Xcode

1. Open Xcode → File → Open… → select the `ClaudeUsageOverlay` folder (the one
   with `Package.swift` in it). Xcode will treat it as a Swift Package project.
2. Press Run (▶). The app will launch the same way as above.

### First run: signing in

On first launch (or whenever your session expires), a normal browser-style
window titled "Sign in to Claude" will appear — log in there like you would on
claude.ai. Once you're signed in, close that window; the overlay will pick up
your session automatically within a couple of minutes (or use the menu bar
icon → "Refresh Now").

## Menu bar controls

Click the gauge icon in the menu bar for:
- **Refresh Now** — fetch usage immediately
- **Show Overlay** — toggle the floating widget on/off
- **Sign In…** — reopen the login window
- **Sign Out** — clears the stored session (you'll need to sign in again)
- **Quit**

## Launch at login (optional)

macOS doesn't make this trivial for a plain Swift Package build. Easiest way:

1. Build the release binary (`swift build -c release`, as above).
2. System Settings → General → Login Items → click the **+** under
   "Open at Login" → navigate to and select
   `ClaudeUsageOverlay/.build/release/ClaudeUsageOverlay` → Add.

## Customizing

- **Refresh interval:** `refreshInterval` in `AppDelegate.swift` (default: 120 seconds).
- **Position:** `positionTopRight(...)` in `AppDelegate.swift` — change the margin
  or logic if you'd rather anchor it elsewhere.
- **Panel size / look:** `OverlayView.swift`.

## Known limitations

- Only reflects `five_hour` (session) and `seven_day` (weekly) limits — the
  same top-level numbers claude.ai's own Usage page shows. It does not break
  down usage per product (app vs. Code vs. Cowork) since claude.ai's own usage
  page doesn't expose that breakdown either.
- If Anthropic changes the shape of these endpoints, the overlay will start
  showing "Unexpected response" or similar until updated.
- Multi-monitor: the overlay defaults to the primary display. Drag it manually
  if you want it elsewhere — it remembers position only for the current run.
