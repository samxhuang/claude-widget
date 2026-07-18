# claude-autoresume

Watches Claude Code (CLI) sessions on this Mac. When a session gets cut off
by your Pro/Max plan's rate limit, this daemon detects it and lists it in
the **Claude Usage Overlay** widget — resuming only happens for sessions you
explicitly opt into there. Nothing auto-resumes by default.

## Scope — read this first

- **Claude Code (terminal) sessions only.** Claude Code writes a local log
  per session (`~/.claude/projects/**/*.jsonl`) that records exactly when a
  rate limit cut a session short and when it resets — this daemon reads
  that log directly.
- **Cowork is not covered.** Cowork sessions run server-side and never write
  a local transcript, so there's nothing on disk for this daemon to watch or
  a way to resume Cowork from your machine.
- **Plain chat isn't covered either** — and doesn't need to be. A chat
  conversation isn't a background task that stops running; it just won't
  accept new messages until the limit clears. There's nothing to relaunch.

## How it works, and how you control it

1. A background daemon (`autoresume.py`) polls `~/.claude/projects/` every
   30 seconds for session files touched in the last 20 minutes.
2. If a session's log ends with a `rate_limit_event` (rather than a normal
   completion), it's recorded in `~/.claude-autoresume/state.json` — the
   session's id, project directory, a short preview of what it was doing,
   and the reset time — with **`enabled: false`**. At this point nothing
   happens except that it becomes visible.
3. The **Claude Usage Overlay** widget reads that same file and lists every
   pending session under "Interrupted Sessions," with a toggle per session
   and a "Resume Now" button.
   - Flip the toggle **on** and the daemon will resume that specific session
     automatically once its reset time passes — and only that one.
   - "Resume Now" resumes it immediately, regardless of the toggle or the
     reset time.
   - Leave it alone and it just sits there, inert, until you decide.
4. When a resume does fire, it runs:
   ```
   claude --resume <session-id> --print "continue" --output-format json --permission-mode bypassPermissions
   ```
   in the session's original project directory, in the background, logging
   output to `~/.claude-autoresume/logs/<session-id>.log`.
5. Each session is only auto-resumed once.

## The tradeoff worth knowing

Because a resumed session runs with nobody at the keyboard, it runs with
permission prompts bypassed (`--permission-mode bypassPermissions`) — there's
no one there to approve them turn-by-turn. That's true whether it fires from
your toggle or "Resume Now." The widget's job is to make sure that only
happens for sessions *you* picked, not silently for everything. Still worth
glancing at `~/.claude-autoresume/logs/<session-id>.log` after a resume you
opted into.

## Install

```bash
cd claude-autoresume
./install.sh
```

This finds your `claude` and `python3` binaries, installs the daemon to
`~/.claude-autoresume/bin/`, and registers it as a macOS LaunchAgent
(`~/Library/LaunchAgents/com.samhuang.claude-autoresume.plist`) so it runs
continuously in the background and restarts automatically at login.

If you already had a previous version installed, just re-run `./install.sh`
— it overwrites the daemon script and reloads the LaunchAgent.

## Verify it's running

```bash
launchctl print gui/$(id -u)/com.samhuang.claude-autoresume
tail -f ~/.claude-autoresume/daemon.log
```

## Uninstall

```bash
cd claude-autoresume
./uninstall.sh
```

## Known rough edges

- **`--permission-mode bypassPermissions`** is the flag/value most likely to
  be correct as of when this was written, but Claude Code's exact CLI
  surface changes between releases. If a resume attempt fails, check
  `~/.claude-autoresume/logs/<session-id>.log` — if it's a flag error, run
  `claude --help` and fix `PERMISSION_MODE` in `autoresume.py` (then re-run
  `./install.sh`).
- **Project directory detection** relies on a `cwd` field Claude Code
  usually writes into its session log, with a fallback that tries to decode
  the project folder's name back into a path. If your project path contains
  dashes, the fallback can guess wrong — the `cwd`-based path is the
  reliable one and should cover most cases.
- **The widget polls state.json every 5 seconds** and both it and the
  daemon take the same file lock (`state.json.lock`) before writing, so a
  toggle click and a daemon poll cycle can't corrupt each other's update.
- This depends on Claude Code continuing to log a `rate_limit_event` with a
  reset time in its session file — an internal implementation detail, not a
  documented, stable API. If Anthropic changes this, detection will silently
  stop working; check `daemon.log` occasionally.
