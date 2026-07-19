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

## Remote hosts (SSH)

Claude Code running over a plain ssh terminal or VS Code Remote-SSH writes its
transcripts to the **remote** machine's `~/.claude/projects`, where the Mac
daemon can't see them. The fix is to run this same stdlib daemon on each remote
host and have the Mac fetch its state over ssh and merge it in — full
classification fidelity, and auto-resume fires natively on the remote instead of
over fragile ssh-exec.

- The remote runs the identical `autoresume.py`, launched with
  `AUTORESUME_REMOTE=1` so it does the session classification but skips the
  Mac-only usage/pricing writes.
- The Mac's sync worker talks to the remote through `remote_ctl.py` (a tiny
  stdlib bridge deployed alongside the daemon): `dump` reads the remote
  `state.json` under the same flock the daemon uses, `apply-toggles` pushes your
  widget toggles back (whitelisted keys only, never creating entries).
- Remote sessions show up in the widget merged with local ones; their entries
  are keyed `"<host>::<remote_session_id>"`.

### The normal path — add a host in Settings

You don't run any of this by hand. Open **Settings** from the menu-bar icon,
go to **Remote Hosts → Add Host**, give it a name and an ssh target
(`sam@devbox` or an `~/.ssh/config` alias), and the widget auto-deploys the
daemon to that host and starts syncing. Remote sessions default to
`enabled: false` exactly like local ones — nothing auto-resumes until you flip
its toggle.

### Manual deploy / uninstall

The Settings **Add Host** flow just runs the deploy script for you; you can also
run it directly (both from the repo checkout and from the installed
`~/.claude-autoresume/bin/` copy — it finds its payload beside itself):

```bash
# deploy (or redeploy) to a host
~/.claude-autoresume/bin/deploy_remote.sh sam@devbox

# stop the remote daemon and remove ~/.claude-autoresume/bin on the host
# (remote state.json, usage/, and transcripts are left untouched)
~/.claude-autoresume/bin/deploy_remote.sh sam@devbox --uninstall
```

The script is fully non-interactive (every ssh/scp uses `BatchMode=yes` and
never prompts) and prints machine-readable markers the widget parses to drive
its progress checklist — `@@STEP:<connect|python|copy|service|start|verify>` at
each stage, then `@@OK version=<hash>` or `@@FAIL:<reason>`; exit code mirrors
the last marker. It installs a `systemctl --user` unit where available (with
`loginctl enable-linger` so it survives logout) and falls back to
`nohup` + a pidfile otherwise.

### Troubleshooting remote deploy

- **`@@FAIL:connect …`** — ssh couldn't reach the host without prompting.
  Remote deploy requires **key-based ssh auth**; `BatchMode` never types a
  password. Make sure `ssh <target>` works from a terminal with no password
  prompt (add your key to the host's `~/.ssh/authorized_keys`, and for a brand
  new host accept its host key once by connecting manually first).
- **`@@FAIL:python …`** — the remote's `python3` is missing or older than 3.9.
  The daemon is pure stdlib but needs 3.9+. Install/point PATH at a newer
  `python3`.
- **`claude` not found on remote** — deploy still succeeds (you get a warning),
  but auto-resume can't launch sessions there until `claude` is on the remote's
  PATH. Install Claude Code on the host.
- **Daemon stops after you log out** — `loginctl enable-linger` didn't take (you
  saw a warning). Have an admin run `loginctl enable-linger <user>` on the host,
  or the systemd `--user` manager will exit when your last session ends.
- **No `systemctl --user`** — the script uses the `nohup` + pidfile fallback;
  the daemon runs but won't restart automatically on remote reboot. Re-running
  the deploy relaunches it (it kills the old pid first).

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
