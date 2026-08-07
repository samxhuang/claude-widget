#!/usr/bin/env python3
"""
deploy_remote.py — deploy (or remove) the claude-autoresume daemon on a
remote host over ssh. Pure-stdlib Python port of deploy_remote.sh.

  !! NOT YET WIRED UP !!
  The widget (HostDeployer.swift) still runs `deploy_remote.sh` via /bin/bash.
  This file is a byte-for-byte-equivalent replacement that removes the last
  bash dependency from the deploy path (Windows has no bash), but the live
  cutover has NOT been made: no real remote host was reachable to verify it
  end to end. Both files are staged into ~/.claude-autoresume/bin/ by
  install.sh; keep them in sync until the owner flips HostDeployer over.
  See docs/windows-port-plan.md §1.4.

Non-interactive and machine-parseable: every ssh/scp uses BatchMode so it
NEVER prompts, and progress is emitted as marker lines for the widget's
HostDeployer to drive its step checklist:

  @@STEP:<connect|python|copy|service|start|verify>   at each stage start
  @@OK version=<hash>                                 on success
  @@FAIL:<short reason>                                on error

Human-readable detail goes on plain surrounding lines. Exit code mirrors the
final marker (0 on @@OK, 1 on @@FAIL). Works identically run by hand.

Usage:
  deploy_remote.py <user@host|ssh-alias>              deploy
  deploy_remote.py <user@host|ssh-alias> --uninstall  stop + remove remote bin/

Runs both from ~/.claude-autoresume/bin/ (payload staged beside it by
install.sh) and from the repo checkout (payload = sibling .py files); the
payload dir is resolved relative to this script's own location.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# --- the .py payload shipped to the remote ---------------------------------
# remote_sync.py MUST be included: autoresume.py imports it unconditionally at
# module top (`import remote_sync`), so omitting it makes the remote daemon
# crash with ModuleNotFoundError before main() ever runs (systemd
# Restart=always then crash-loops every RestartSec). On a remote with no
# config.json its RemoteSync worker just idles harmlessly.
#
# This is the authoritative list (test_remote_sync.py imports it directly);
# deploy_remote.sh carries a duplicate bash array that must match it while
# both files exist — test_deploy_remote.py asserts they agree.
PAYLOAD_FILES = (
    "autoresume.py",
    # platform_compat.py is a TOP-LEVEL import of autoresume.py, usage_collector.py,
    # plan_fit.py and remote_ctl.py — omitting it crash-loops the remote daemon at
    # import, exactly like the remote_sync.py omission this list already guards against.
    "platform_compat.py",
    "cowork_resume.py",
    "usage_collector.py",
    "plan_fit.py",
    "autoresume_config.py",
    "remote_ctl.py",
    "remote_sync.py",
)

SERVICE_TEMPLATE_NAME = "autoresume.service.template"
REMOTE_SERVICE = "claude-autoresume.service"

# Never prompt: identical to the shell script's SSH_OPTS array.
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

# The verify stage waits past one systemd RestartSec window before judging
# liveness. Overridable ONLY so the test-suite doesn't sleep 7s per case.
VERIFY_WAIT_SECONDS = float(os.environ.get("AUTORESUME_DEPLOY_VERIFY_WAIT", "7"))

PROG = "deploy_remote.py"


# ---------------------------------------------------------------------------
# marker helpers  (mirror step()/ok()/fail() in deploy_remote.sh)
# ---------------------------------------------------------------------------

def emit(line: str) -> None:
    """Plain human-readable line (the shell's bare `echo`)."""
    print(line, flush=True)


def step(name: str) -> None:
    print("@@STEP:%s" % name, flush=True)


def ok(version: str):
    print("@@OK version=%s" % version, flush=True)
    raise SystemExit(0)


def fail(reason: str):
    print("@@FAIL:%s" % reason, flush=True)
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# ssh / scp wrappers
# ---------------------------------------------------------------------------

class Remote:
    """`rssh`/`rscp` from the shell script, with the three redirection modes
    the script uses spelled out explicitly:

      quiet       -> `>/dev/null 2>&1` (rc only)
      passthrough -> no local redirection (remote output reaches our stdout)
      capture     -> `2>/dev/null` + command substitution (rc + cleaned stdout)
    """

    def __init__(self, host: str):
        self.host = host

    def _run(self, argv, mode):
        if mode == "passthrough":
            # Our own prints are buffered independently of the child's fds.
            sys.stdout.flush()
            sys.stderr.flush()
            proc = subprocess.run(argv)
            return proc.returncode, ""
        if mode == "quiet":
            proc = subprocess.run(argv, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
            return proc.returncode, ""
        # capture
        proc = subprocess.run(argv, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)
        out = proc.stdout.decode("utf-8", "replace")
        # `| tr -d '\r'` then `$(...)`'s trailing-newline strip.
        out = out.replace("\r", "").rstrip("\n")
        return proc.returncode, out

    def ssh(self, command: str, mode: str = "quiet"):
        return self._run(["ssh"] + SSH_OPTS + [self.host, command], mode)

    def scp(self, local_names, remote_dest: str, cwd) -> int:
        """scp with `cwd` set to the files' directory and BARE FILENAMES as
        the sources. Passing absolute local paths would be wrong on Windows —
        scp parses `C:\\...` as host `C` — and relative names are identical in
        behavior on POSIX, so this is the portable spelling, not a
        Windows-specific branch."""
        sys.stdout.flush()
        proc = subprocess.run(
            ["scp"] + SSH_OPTS + list(local_names) + [remote_dest],
            cwd=str(cwd), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return proc.returncode


# ---------------------------------------------------------------------------
# version hash
# ---------------------------------------------------------------------------

def compute_version(paths) -> str:
    """Order-independent digest of the .py payload we are about to ship.

    Replicates the shell's
        for f; do sha256sum "$f"; done | awk '{print $1}' | sort | sha256sum
    exactly: per-file lowercase hex digests, sorted as text, each newline
    terminated, hashed again, first 12 chars. Done with hashlib rather than
    shelling out (no sha256sum on Windows, and one less external dependency).
    """
    digests = []
    for p in paths:
        h = hashlib.sha256()
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        digests.append(h.hexdigest())
    joined = "".join(d + "\n" for d in sorted(digests))
    return hashlib.sha256(joined.encode("ascii")).hexdigest()[:12]


# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------

USAGE = "usage: %s <user@host|ssh-alias> [--uninstall]" % PROG


def parse_args(argv):
    host = ""
    uninstall = False
    for arg in argv:
        if arg == "--uninstall":
            uninstall = True
        elif arg.startswith("-"):
            print("unknown option: %s" % arg, file=sys.stderr)
            print(USAGE, file=sys.stderr)
            raise SystemExit(2)
        elif not host:
            host = arg
        else:
            print("unexpected extra argument: %s" % arg, file=sys.stderr)
            raise SystemExit(2)
    if not host:
        print(USAGE, file=sys.stderr)
        raise SystemExit(2)
    return host, uninstall


# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------

UNINSTALL_SCRIPT = """
    systemctl --user disable --now claude-autoresume.service >/dev/null 2>&1 || true
    rm -f ~/.config/systemd/user/claude-autoresume.service
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if [ -f ~/.claude-autoresume/daemon.pid ]; then
      kill "$(cat ~/.claude-autoresume/daemon.pid)" 2>/dev/null || true
      rm -f ~/.claude-autoresume/daemon.pid
    fi
    rm -rf ~/.claude-autoresume/bin
  """


def do_uninstall(r: Remote) -> None:
    step("connect")
    emit("Checking ssh to %s ..." % r.host)
    if r.ssh("echo ok", "quiet")[0] != 0:
        fail("connect: cannot ssh to %s (BatchMode; check key-based auth / host)" % r.host)

    step("service")
    emit("Stopping and removing remote daemon on %s (state/transcripts left intact) ..." % r.host)
    # Best-effort teardown of whichever install path is present.
    if r.ssh(UNINSTALL_SCRIPT, "passthrough")[0] != 0:
        fail("service: uninstall commands failed on remote")
    emit("Removed ~/.claude-autoresume/bin and the service/pidfile; "
         "state.json, usage/, and transcripts untouched.")
    ok("uninstalled")


# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------

def do_deploy(r: Remote, script_dir: Path) -> None:
    service_template = script_dir / SERVICE_TEMPLATE_NAME

    # Resolve + validate local payload paths.
    payload_paths = []
    for f in PAYLOAD_FILES:
        p = script_dir / f
        if not p.is_file():
            fail("copy: missing local payload file %s (looked in %s)" % (f, script_dir))
        payload_paths.append(p)
    if not service_template.is_file():
        fail("service: missing %s in %s" % (SERVICE_TEMPLATE_NAME, script_dir))

    try:
        version = compute_version(payload_paths)
    except OSError:
        fail("copy: cannot compute version hash (no sha256sum/shasum)")

    # --- connect -----------------------------------------------------------
    step("connect")
    emit("Checking ssh to %s ..." % r.host)
    if r.ssh("echo ok", "quiet")[0] != 0:
        fail("connect: cannot ssh to %s (BatchMode never prompts — needs working "
             "key-based auth and a known host)" % r.host)
    emit("ssh ok.")

    # --- python preflight --------------------------------------------------
    # NOTE: we resolve the remote interpreter via `command -v python3` and
    # install the daemon under it. The Mac-side remote_sync runtime, however,
    # invokes the interpreter named in each host's config "python" field (see
    # _remote_ctl_command in remote_sync.py). Those diverge only on a
    # hand-edited config; a custom "python" MUST match what deploy installed
    # with here, or remote_ctl runs under a different Python than the daemon.
    step("python")
    _, remote_py = r.ssh("command -v python3 || true", "capture")
    if not remote_py:
        fail("python: python3 not found on remote PATH")
    rc, _ = r.ssh('python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)"',
                  "quiet")
    if rc != 0:
        _, rv = r.ssh('python3 -c "import sys;print(\\"%d.%d\\"%sys.version_info[:2])"',
                      "capture")
        fail("python: remote python3 too old (need >= 3.9, found %s)" % (rv or "unknown"))
    emit("remote python3: %s (>= 3.9)" % remote_py)

    _, remote_home = r.ssh("echo $HOME", "capture")
    if not remote_home:
        fail("python: could not resolve remote $HOME")
    _, claude_remote = r.ssh("command -v claude || true", "capture")
    if not claude_remote:
        emit("warning: 'claude' not found on remote PATH — auto-resume will not be "
             "able to launch sessions there until it is installed.")

    # --- copy --------------------------------------------------------------
    step("copy")
    emit("Creating remote ~/.claude-autoresume/bin and copying payload ...")
    if r.ssh("mkdir -p ~/.claude-autoresume/bin ~/.claude-autoresume/logs",
             "passthrough")[0] != 0:
        fail("copy: mkdir on remote failed")
    if r.scp([p.name for p in payload_paths],
             "%s:.claude-autoresume/bin/" % r.host, script_dir) != 0:
        fail("copy: scp of payload failed")
    r.ssh("chmod +x ~/.claude-autoresume/bin/autoresume.py "
          "~/.claude-autoresume/bin/remote_ctl.py", "quiet")  # `|| true`
    emit("copied: %s" % " ".join(PAYLOAD_FILES))

    # --- service -----------------------------------------------------------
    step("service")
    # Detect a usable `systemctl --user`. A non-login ssh session often lacks
    # XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS, so the plain probe fails even
    # though the user bus is running — retry with them set explicitly before
    # falling back to nohup. systemd_prefix (a literal string; the remote shell
    # expands $(id -u)) is prepended to every subsequent `systemctl --user`
    # call so they hit the same bus the probe succeeded on.
    use_systemd = False
    systemd_prefix = ""
    systemd_path = ""
    explicit_bus = ('XDG_RUNTIME_DIR="/run/user/$(id -u)" '
                    'DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" ')
    if r.ssh("command -v systemctl >/dev/null 2>&1", "passthrough")[0] == 0:
        if r.ssh("systemctl --user show-environment >/dev/null 2>&1",
                 "passthrough")[0] == 0:
            use_systemd = True
            systemd_path = "systemd --user (default session bus)"
        elif r.ssh(explicit_bus + "systemctl --user show-environment >/dev/null 2>&1",
                   "passthrough")[0] == 0:
            use_systemd = True
            systemd_prefix = explicit_bus
            systemd_path = "systemd --user (explicit XDG_RUNTIME_DIR=/run/user/$(id -u))"

    if use_systemd:
        emit("service path: %s" % systemd_path)
        emit("Installing systemd --user unit ...")
        rendered_dir = None
        rendered_name = None
        try:
            try:
                text = service_template.read_text(encoding="utf-8")
                # Same substitutions the shell's sed -e chain performs, applied
                # in the same order.
                text = text.replace("__PYTHON3__", remote_py)
                text = text.replace(
                    "__SCRIPT_PATH__", "%s/.claude-autoresume/bin/autoresume.py" % remote_home)
                text = text.replace("__CLAUDE_BIN__", claude_remote)
                text = text.replace("__STATE_DIR__", "%s/.claude-autoresume" % remote_home)
                tmp_dir = tempfile.mkdtemp(prefix="claude-autoresume-unit-")
                rendered_dir = Path(tmp_dir)
                rendered_name = REMOTE_SERVICE
                (rendered_dir / rendered_name).write_text(text, encoding="utf-8")
            except OSError:
                fail("service: rendering unit template failed")

            if r.ssh("mkdir -p ~/.config/systemd/user", "passthrough")[0] != 0:
                fail("service: mkdir ~/.config/systemd/user failed")
            if r.scp([rendered_name],
                     "%s:.config/systemd/user/%s" % (r.host, REMOTE_SERVICE),
                     rendered_dir) != 0:
                fail("service: scp of unit file failed")
            if r.ssh(systemd_prefix + "systemctl --user daemon-reload",
                     "passthrough")[0] != 0:
                fail("service: systemctl --user daemon-reload failed")
        finally:
            # The shell's `trap 'rm -f "$RENDERED"' EXIT`.
            if rendered_dir is not None:
                try:
                    (rendered_dir / rendered_name).unlink()
                except OSError:
                    pass
                try:
                    rendered_dir.rmdir()
                except OSError:
                    pass
        emit("unit installed at ~/.config/systemd/user/%s" % REMOTE_SERVICE)
        # Linger keeps the user manager (and thus the daemon) alive after logout.
        if r.ssh('loginctl enable-linger "$USER"', "quiet")[0] == 0:
            emit("loginctl linger enabled (daemon survives logout).")
        else:
            emit("warning: could not enable loginctl linger — the remote daemon may "
                 "stop when you log out. Run 'loginctl enable-linger <user>' as an "
                 "admin if you want it to persist.")
    else:
        emit("service path: nohup + pidfile (no usable 'systemctl --user' on remote)")

    # --- start -------------------------------------------------------------
    step("start")
    if use_systemd:
        emit("Enabling and starting the service ...")
        if r.ssh(systemd_prefix + "systemctl --user enable --now claude-autoresume.service",
                 "passthrough")[0] != 0:
            fail("start: systemctl --user enable --now failed")
        emit("service enabled and started.")
    else:
        emit("Starting daemon with nohup ...")
        # Kill any previous instance, then relaunch detached, recording the pid.
        # (Byte-identical to the shell's expanded here-string.)
        start_script = (
            "\n"
            "    if [ -f ~/.claude-autoresume/daemon.pid ]; then\n"
            '      kill "$(cat ~/.claude-autoresume/daemon.pid)" 2>/dev/null || true\n'
            "    fi\n"
            "    AUTORESUME_REMOTE=1 CLAUDE_BIN='%s' nohup '%s' "
            "~/.claude-autoresume/bin/autoresume.py "
            "      </dev/null >> ~/.claude-autoresume/launchd.out.log "
            "2>> ~/.claude-autoresume/launchd.err.log &\n"
            "    echo $! > ~/.claude-autoresume/daemon.pid\n"
            "  " % (claude_remote, remote_py)
        )
        if r.ssh(start_script, "passthrough")[0] != 0:
            fail("start: nohup launch failed")
        emit("daemon started (pid recorded in ~/.claude-autoresume/daemon.pid).")

    # --- verify ------------------------------------------------------------
    step("verify")
    emit("Verifying remote_ctl.py dump ...")
    _, dump = r.ssh("python3 ~/.claude-autoresume/bin/remote_ctl.py dump", "capture")
    if not dump:
        fail("verify: remote_ctl.py dump returned no output")
    # Confirm the contract shape (the shell piped this through a local python3).
    if not _dump_is_valid(dump):
        fail("verify: remote_ctl.py dump did not return parseable {v,now,state}")
    emit("verify ok: remote_ctl.py dump returned a valid state envelope.")

    # The dump above is a STANDALONE remote_ctl.py invocation — it succeeds even
    # if the *daemon* is dead (Type=simple/nohup both report "started" before the
    # process crashes at import or in main()). So separately confirm the daemon
    # is actually staying up: a payload/import failure crash-loops under
    # Restart=always (RestartSec=5), which the dump check alone would never
    # catch. Wait past one RestartSec window before judging so a single restart
    # shows up.
    emit("Confirming the daemon is staying up (waiting past one restart window) ...")
    time.sleep(VERIFY_WAIT_SECONDS)
    if use_systemd:
        # A crash-looping unit is "activating"/"failed", or "active" with
        # NRestarts>0 after our wait — a healthy one is "active" NRestarts=0.
        _, active = r.ssh(systemd_prefix + "systemctl --user is-active claude-autoresume.service",
                          "capture")
        _, nrestarts = r.ssh(
            systemd_prefix + "systemctl --user show claude-autoresume.service -p NRestarts --value",
            "capture")
        if active != "active" or (nrestarts and nrestarts != "0"):
            emit("daemon unhealthy: is-active=%s NRestarts=%s"
                 % (active or "unknown", nrestarts or "unknown"))
            fail("verify: remote daemon is not staying up (crash-loop?) — check remote "
                 "~/.claude-autoresume/daemon.log and launchd.err.log")
        emit("verify ok: daemon active and stable (NRestarts=%s)." % (nrestarts or "0"))
    else:
        # nohup path: confirm the recorded pid is still alive after the wait.
        _, dpid = r.ssh("cat ~/.claude-autoresume/daemon.pid 2>/dev/null", "capture")
        if not dpid or r.ssh("kill -0 %s" % dpid, "quiet")[0] != 0:
            emit("daemon pid %s not alive after start" % (dpid or "unknown"))
            fail("verify: remote daemon exited after launch (crash?) — check remote "
                 "~/.claude-autoresume/daemon.log and launchd.err.log")
        emit("verify ok: daemon pid %s still alive." % dpid)

    ok(version)


def _dump_is_valid(text: str) -> bool:
    try:
        d = json.loads(text)
    except Exception:
        return False
    return (isinstance(d, dict) and d.get("v") == 1
            and isinstance(d.get("state"), dict) and "now" in d)


# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    host, uninstall = parse_args(sys.argv[1:] if argv is None else argv)
    # Payload dir = this script's own directory (symlink-safe, like the shell's
    # BASH_SOURCE walk); resolve() follows symlinks.
    script_dir = Path(__file__).resolve().parent
    r = Remote(host)
    if uninstall:
        do_uninstall(r)
    else:
        do_deploy(r, script_dir)
    return 0  # unreachable: ok()/fail() raise SystemExit


if __name__ == "__main__":
    sys.exit(main())
