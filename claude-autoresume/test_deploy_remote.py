#!/usr/bin/env python3
"""
Unit tests for deploy_remote.py — the pure-stdlib port of deploy_remote.sh.

No real host is ever contacted. Every test puts FAKE `ssh`/`scp` executables
first on PATH in a throwaway dir; they record their argv to a log file and
emit scripted (rc, stdout, stderr) responses selected by substring-matching
the composed remote command line. That lets us drive every branch — systemd
vs nohup, each failure stage, the uninstall path — and assert the exact
`@@STEP`/`@@OK`/`@@FAIL` marker sequence the widget's HostDeployer parses.

The headline tests are in MarkerEquivalenceTests: they run the ORIGINAL
deploy_remote.sh against the very same fakes and assert its stdout is
byte-for-byte identical to deploy_remote.py's. That is the real proof the
marker protocol survived the port, not a hand-transcribed expectation.

Run with:
    python3 test_deploy_remote.py      # or: python3 -m unittest test_deploy_remote -v
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import deploy_remote as dr

REPO_DIR = Path(__file__).resolve().parent
PY_SCRIPT = REPO_DIR / "deploy_remote.py"
SH_SCRIPT = REPO_DIR / "deploy_remote.sh"
TARGET = "sam@devbox"

# ---------------------------------------------------------------------------
# Fake ssh / scp
# ---------------------------------------------------------------------------

# Deliberately POSIX sh using only builtins: these run ~20x per deploy, and a
# python fake cost ~0.5s of interpreter startup per scenario. The scenario's
# responses are a generated sh fragment (`respond()`), sourced at startup.
# Calls are appended to the log with RS/GS control-char separators rather than
# newlines, because one composed remote command (the nohup launcher) is itself
# multi-line.
FAKE_SRC = '''#!/bin/sh
case "${0##*/}" in
  ssh) cfg=$FAKE_SSH_CONFIG ;;
  *)   cfg=$FAKE_SCP_CONFIG ;;
esac
. "$cfg"
{ printf '%s' "${0##*/}"
  for a in "$@"; do printf '%s%s' "$RS" "$a"; done
  printf '%s' "$GS"; } >> "$LOGFILE"
respond "$*"
'''

# deploy_remote.py's verify wait is env-overridable (AUTORESUME_DEPLOY_VERIFY_WAIT);
# deploy_remote.sh's is a hardcoded `sleep 7`. Since the fake bin dir is first on
# PATH, a no-op `sleep` gives the shell side the same zero wait — keeping the two
# implementations symmetric AND the suite fast.
FAKE_SLEEP = "#!/bin/sh\nexit 0\n"

RS = "\x1e"   # between argv elements
GS = "\x1d"   # between calls


def _sh_config(log, rules, default_rc=0):
    """Render a scenario as a sourceable sh fragment."""
    out = ["LOGFILE=%s" % shlex.quote(str(log)),
           "RS='%s'" % RS, "GS='%s'" % GS,
           "respond() {", '  case "$1" in']
    for r in rules:
        body = []
        if r.get("stdout"):
            body.append("printf '%%s' %s;" % shlex.quote(r["stdout"]))
        if r.get("stderr"):
            body.append("printf '%%s' %s >&2;" % shlex.quote(r["stderr"]))
        body.append("exit %d ;;" % int(r.get("rc", 0)))
        # Quoted pattern sections match literally — no glob escaping needed.
        out.append("    *%s*) %s" % (shlex.quote(r["match"]), " ".join(body)))
    out += ["  esac", "  exit %d" % int(default_rc), "}"]
    return "\n".join(out) + "\n"

DUMP_OK = '{"v": 1, "now": 1000.0, "state": {}}'

# Ordered most-specific-first: the first rule whose `match` is a substring of
# the composed remote command wins.
BASE_SSH_RULES = [
    # Multi-line composed scripts must be matched before their inner fragments.
    ("nohup", {"rc": 0}),
    ("rm -rf ~/.claude-autoresume/bin", {"rc": 0}),          # uninstall teardown
    ("remote_ctl.py dump", {"stdout": DUMP_OK + "\n"}),
    ("is-active", {"stdout": "active\n"}),
    ("NRestarts", {"stdout": "0\n"}),
    ("show-environment", {"rc": 0}),
    ("daemon-reload", {"rc": 0}),
    ("enable --now", {"rc": 0}),
    ("enable-linger", {"rc": 0}),
    ("command -v systemctl", {"rc": 0}),
    ("command -v python3", {"stdout": "/usr/bin/python3\n"}),
    ("version_info >= (3,9)", {"rc": 0}),
    ("%d.%d", {"stdout": "3.6\n"}),                          # the "too old" probe
    ("echo $HOME", {"stdout": "/home/sam\n"}),
    ("command -v claude", {"stdout": "/usr/local/bin/claude\n"}),
    ("cat ~/.claude-autoresume/daemon.pid", {"stdout": "4242\n"}),
    ("kill -0", {"rc": 0}),
    ("echo ok", {"rc": 0}),
    ("mkdir -p", {"rc": 0}),
    ("chmod +x", {"rc": 0}),
]


def ssh_rules(**overrides):
    """BASE_SSH_RULES with `match -> patch` overrides applied in place (key is
    the match string with spaces/specials replaced by `_`, see MATCH_KEYS)."""
    out = []
    for match, spec in BASE_SSH_RULES:
        key = MATCH_KEYS[match]
        merged = dict(spec)
        if key in overrides:
            merged.update(overrides[key])
        out.append(dict(merged, match=match))
    return out


MATCH_KEYS = {
    "nohup": "nohup",
    "rm -rf ~/.claude-autoresume/bin": "uninstall",
    "remote_ctl.py dump": "dump",
    "is-active": "is_active",
    "NRestarts": "nrestarts",
    "show-environment": "show_environment",
    "daemon-reload": "daemon_reload",
    "enable --now": "enable_now",
    "enable-linger": "linger",
    "command -v systemctl": "have_systemctl",
    "command -v python3": "which_python",
    "version_info >= (3,9)": "python_version_ok",
    "%d.%d": "python_version_probe",
    "echo $HOME": "home",
    "command -v claude": "which_claude",
    "cat ~/.claude-autoresume/daemon.pid": "read_pid",
    "kill -0": "kill0",
    "echo ok": "connect",
    "mkdir -p": "mkdir",
    "chmod +x": "chmod",
}


class FakeHostMixin:
    """Builds a temp dir holding fake ssh/scp + their JSON configs, and runs
    either implementation against them."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "fakebin"
        self.bin.mkdir()
        for name, src in (("ssh", FAKE_SRC), ("scp", FAKE_SRC), ("sleep", FAKE_SLEEP)):
            p = self.bin / name
            p.write_text(src)
            p.chmod(p.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.log = self.tmp / "calls.log"
        self.configure()

    def tearDown(self):
        self._tmp.cleanup()

    def configure(self, ssh_overrides=None, scp_rc=0, ssh_rules_override=None):
        rules = ssh_rules_override or ssh_rules(**(ssh_overrides or {}))
        (self.tmp / "ssh.sh").write_text(_sh_config(self.log, rules))
        (self.tmp / "scp.sh").write_text(_sh_config(self.log, [], default_rc=scp_rc))

    def _env(self):
        env = dict(os.environ)
        env["PATH"] = str(self.bin) + os.pathsep + env.get("PATH", "")
        env["FAKE_SSH_CONFIG"] = str(self.tmp / "ssh.sh")
        env["FAKE_SCP_CONFIG"] = str(self.tmp / "scp.sh")
        env["AUTORESUME_DEPLOY_VERIFY_WAIT"] = "0"   # python side only
        return env

    def run_py(self, *args):
        return subprocess.run([sys.executable, str(PY_SCRIPT), *args],
                              env=self._env(), capture_output=True, text=True,
                              timeout=120)

    def run_sh(self, *args):
        return subprocess.run(["/bin/bash", str(SH_SCRIPT), *args],
                              env=self._env(), capture_output=True, text=True,
                              timeout=120)

    def calls(self):
        """[[prog, arg, ...], ...] — one record per fake ssh/scp invocation."""
        if not self.log.exists():
            return []
        raw = self.log.read_text()
        return [rec.split(RS) for rec in raw.split(GS) if rec]

    def ssh_commands(self):
        """The composed remote command line of every fake-ssh invocation."""
        return [c[-1] for c in self.calls() if c[0] == "ssh"]


def markers(text):
    return [l for l in text.splitlines() if l.startswith("@@")]


FULL_STEPS = ["@@STEP:connect", "@@STEP:python", "@@STEP:copy",
              "@@STEP:service", "@@STEP:start", "@@STEP:verify"]

VERSION_RE = re.compile(r"^@@OK version=[0-9a-f]{12}$")


# ---------------------------------------------------------------------------
# Happy paths
# ---------------------------------------------------------------------------

class HappyPathTests(FakeHostMixin, unittest.TestCase):
    def test_systemd_happy_path_markers(self):
        proc = self.run_py(TARGET)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        m = markers(proc.stdout)
        self.assertEqual(m[:6], FULL_STEPS)
        self.assertEqual(len(m), 7)
        self.assertRegex(m[6], VERSION_RE)
        self.assertIn("service path: systemd --user (default session bus)", proc.stdout)
        self.assertIn("verify ok: daemon active and stable (NRestarts=0).", proc.stdout)

    def test_version_is_the_payload_digest(self):
        proc = self.run_py(TARGET)
        expected = dr.compute_version([REPO_DIR / f for f in dr.PAYLOAD_FILES])
        self.assertEqual(markers(proc.stdout)[-1], "@@OK version=%s" % expected)

    def test_copied_line_lists_the_payload(self):
        proc = self.run_py(TARGET)
        self.assertIn("copied: " + " ".join(dr.PAYLOAD_FILES), proc.stdout)

    def test_explicit_bus_fallback_prefixes_later_systemctl_calls(self):
        # Plain probe fails, explicit XDG_RUNTIME_DIR probe succeeds.
        self.configure(ssh_rules_override=_rules_with_bus_probe())
        proc = self.run_py(TARGET)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("service path: systemd --user (explicit XDG_RUNTIME_DIR=/run/user/$(id -u))",
                      proc.stdout)
        enable = [c for c in self.ssh_commands() if "enable --now" in c]
        self.assertTrue(enable and enable[0].startswith('XDG_RUNTIME_DIR="/run/user/$(id -u)"'),
                        "the bus prefix must ride on every later systemctl call")

    def test_nohup_fallback(self):
        self.configure(ssh_overrides={"have_systemctl": {"rc": 1}})
        proc = self.run_py(TARGET)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(markers(proc.stdout)[:6], FULL_STEPS)
        self.assertRegex(markers(proc.stdout)[6], VERSION_RE)
        self.assertIn("service path: nohup + pidfile (no usable 'systemctl --user' on remote)",
                      proc.stdout)
        self.assertIn("verify ok: daemon pid 4242 still alive.", proc.stdout)
        start = [c for c in self.ssh_commands() if "nohup" in c]
        self.assertEqual(len(start), 1)
        self.assertIn("AUTORESUME_REMOTE=1 CLAUDE_BIN='/usr/local/bin/claude' "
                      "nohup '/usr/bin/python3' ~/.claude-autoresume/bin/autoresume.py",
                      start[0])
        self.assertIn("echo $! > ~/.claude-autoresume/daemon.pid", start[0])
        # ...and the liveness check is a real one, on the recorded pid.
        self.assertTrue(any(c.startswith("kill -0 4242") for c in self.ssh_commands()))

    def test_missing_remote_claude_warns_but_succeeds(self):
        self.configure(ssh_overrides={"which_claude": {"stdout": ""}})
        proc = self.run_py(TARGET)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("warning: 'claude' not found on remote PATH", proc.stdout)
        self.assertRegex(markers(proc.stdout)[-1], VERSION_RE)

    def test_every_ssh_uses_batchmode(self):
        self.run_py(TARGET)
        for call in self.calls():
            self.assertIn("BatchMode=yes", call, "ssh/scp must never be able to prompt")
            self.assertIn("ConnectTimeout=5", call)


def _rules_with_bus_probe():
    """Rules where the PLAIN `systemctl --user show-environment` probe fails but
    the one carrying an explicit XDG_RUNTIME_DIR succeeds."""
    out = []
    for match, spec in BASE_SSH_RULES:
        if match == "show-environment":
            out.append({"match": "XDG_RUNTIME_DIR", "rc": 0})
            out.append({"match": "show-environment", "rc": 1})
            continue
        out.append(dict(spec, match=match))
    return out


# ---------------------------------------------------------------------------
# Failure stages
# ---------------------------------------------------------------------------

class FailureStageTests(FakeHostMixin, unittest.TestCase):
    def assertFails(self, proc, expected_markers):
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertEqual(markers(proc.stdout), expected_markers)

    def test_ssh_unreachable(self):
        self.configure(ssh_overrides={"connect": {"rc": 255, "stderr": "Permission denied (publickey).\n"}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, [
            "@@STEP:connect",
            "@@FAIL:connect: cannot ssh to sam@devbox (BatchMode never prompts — "
            "needs working key-based auth and a known host)",
        ])
        self.assertEqual(len(self.ssh_commands()), 1, "must not keep going after connect fails")

    def test_remote_python3_missing(self):
        self.configure(ssh_overrides={"which_python": {"stdout": ""}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, ["@@STEP:connect", "@@STEP:python",
                                "@@FAIL:python: python3 not found on remote PATH"])

    def test_remote_python3_too_old(self):
        self.configure(ssh_overrides={"python_version_ok": {"rc": 1}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, [
            "@@STEP:connect", "@@STEP:python",
            "@@FAIL:python: remote python3 too old (need >= 3.9, found 3.6)",
        ])

    def test_remote_python3_too_old_unknown_version(self):
        self.configure(ssh_overrides={"python_version_ok": {"rc": 1},
                                      "python_version_probe": {"rc": 1, "stdout": ""}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, [
            "@@STEP:connect", "@@STEP:python",
            "@@FAIL:python: remote python3 too old (need >= 3.9, found unknown)",
        ])

    def test_remote_home_unresolvable(self):
        self.configure(ssh_overrides={"home": {"stdout": ""}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, ["@@STEP:connect", "@@STEP:python",
                                "@@FAIL:python: could not resolve remote $HOME"])

    def test_remote_mkdir_failure(self):
        self.configure(ssh_overrides={"mkdir": {"rc": 1}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, ["@@STEP:connect", "@@STEP:python", "@@STEP:copy",
                                "@@FAIL:copy: mkdir on remote failed"])

    def test_scp_failure(self):
        self.configure(scp_rc=1)
        proc = self.run_py(TARGET)
        self.assertFails(proc, ["@@STEP:connect", "@@STEP:python", "@@STEP:copy",
                                "@@FAIL:copy: scp of payload failed"])

    def test_daemon_reload_failure(self):
        self.configure(ssh_overrides={"daemon_reload": {"rc": 1}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, ["@@STEP:connect", "@@STEP:python", "@@STEP:copy",
                                "@@STEP:service",
                                "@@FAIL:service: systemctl --user daemon-reload failed"])

    def test_enable_now_failure(self):
        self.configure(ssh_overrides={"enable_now": {"rc": 1}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, FULL_STEPS[:5] +
                         ["@@FAIL:start: systemctl --user enable --now failed"])

    def test_verify_dump_empty(self):
        self.configure(ssh_overrides={"dump": {"stdout": ""}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, FULL_STEPS +
                         ["@@FAIL:verify: remote_ctl.py dump returned no output"])

    def test_verify_dump_wrong_shape(self):
        self.configure(ssh_overrides={"dump": {"stdout": '{"v": 2, "state": {}}\n'}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, FULL_STEPS +
                         ["@@FAIL:verify: remote_ctl.py dump did not return parseable {v,now,state}"])

    def test_verify_daemon_crash_looping_under_systemd(self):
        # The trap CLAUDE.md calls out: remote_ctl.py answers fine while the
        # daemon itself crash-loops. NRestarts>0 must still fail the deploy.
        self.configure(ssh_overrides={"nrestarts": {"stdout": "3\n"}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, FULL_STEPS + [
            "@@FAIL:verify: remote daemon is not staying up (crash-loop?) — check "
            "remote ~/.claude-autoresume/daemon.log and launchd.err.log"])
        self.assertIn("daemon unhealthy: is-active=active NRestarts=3", proc.stdout)

    def test_verify_unit_not_active(self):
        self.configure(ssh_overrides={"is_active": {"stdout": "failed\n", "rc": 3}})
        proc = self.run_py(TARGET)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("daemon unhealthy: is-active=failed NRestarts=0", proc.stdout)

    def test_verify_nohup_pid_dead(self):
        self.configure(ssh_overrides={"have_systemctl": {"rc": 1}, "kill0": {"rc": 1}})
        proc = self.run_py(TARGET)
        self.assertFails(proc, FULL_STEPS + [
            "@@FAIL:verify: remote daemon exited after launch (crash?) — check "
            "remote ~/.claude-autoresume/daemon.log and launchd.err.log"])
        self.assertIn("daemon pid 4242 not alive after start", proc.stdout)

    def test_verify_nohup_pidfile_missing(self):
        self.configure(ssh_overrides={"have_systemctl": {"rc": 1},
                                      "read_pid": {"stdout": ""}})
        proc = self.run_py(TARGET)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("daemon pid unknown not alive after start", proc.stdout)

    def test_missing_local_payload_file_fails_before_any_ssh(self):
        # Run a copy of the script from a dir with no payload beside it.
        alt = (self.tmp / "alt").resolve()
        alt.mkdir()
        shutil.copy(PY_SCRIPT, alt / "deploy_remote.py")
        proc = subprocess.run([sys.executable, str(alt / "deploy_remote.py"), TARGET],
                              env=self._env(), capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(markers(proc.stdout),
                         ["@@FAIL:copy: missing local payload file autoresume.py "
                          "(looked in %s)" % alt])
        self.assertEqual(self.calls(), [], "nothing should reach the network")

    def test_missing_service_template_fails(self):
        alt = (self.tmp / "alt2").resolve()
        alt.mkdir()
        shutil.copy(PY_SCRIPT, alt / "deploy_remote.py")
        for f in dr.PAYLOAD_FILES:
            shutil.copy(REPO_DIR / f, alt / f)
        proc = subprocess.run([sys.executable, str(alt / "deploy_remote.py"), TARGET],
                              env=self._env(), capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(markers(proc.stdout),
                         ["@@FAIL:service: missing autoresume.service.template in %s" % alt])


# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

class UninstallTests(FakeHostMixin, unittest.TestCase):
    def test_uninstall_markers(self):
        proc = self.run_py(TARGET, "--uninstall")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(markers(proc.stdout),
                         ["@@STEP:connect", "@@STEP:service", "@@OK version=uninstalled"])
        cmds = self.ssh_commands()
        self.assertEqual(len(cmds), 2)
        self.assertIn("systemctl --user disable --now claude-autoresume.service", cmds[1])
        self.assertIn("rm -rf ~/.claude-autoresume/bin", cmds[1])
        self.assertNotIn("rm -rf ~/.claude-autoresume/state.json", cmds[1])
        self.assertIn("state.json, usage/, and transcripts untouched.", proc.stdout)

    def test_uninstall_connect_failure_uses_its_own_reason(self):
        self.configure(ssh_overrides={"connect": {"rc": 255}})
        proc = self.run_py(TARGET, "--uninstall")
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(markers(proc.stdout), [
            "@@STEP:connect",
            "@@FAIL:connect: cannot ssh to sam@devbox (BatchMode; check key-based auth / host)",
        ])

    def test_uninstall_teardown_failure(self):
        self.configure(ssh_overrides={"uninstall": {"rc": 1}})
        proc = self.run_py(TARGET, "--uninstall")
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(markers(proc.stdout),
                         ["@@STEP:connect", "@@STEP:service",
                          "@@FAIL:service: uninstall commands failed on remote"])


# ---------------------------------------------------------------------------
# CLI surface
# ---------------------------------------------------------------------------

class CliSurfaceTests(FakeHostMixin, unittest.TestCase):
    def test_no_args_is_usage_error(self):
        proc = self.run_py()
        self.assertEqual(proc.returncode, 2)
        self.assertIn("usage: deploy_remote.py <user@host|ssh-alias> [--uninstall]", proc.stderr)
        self.assertEqual(markers(proc.stdout), [])

    def test_unknown_option(self):
        proc = self.run_py(TARGET, "--nope")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("unknown option: --nope", proc.stderr)

    def test_extra_argument(self):
        proc = self.run_py(TARGET, "other")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("unexpected extra argument: other", proc.stderr)

    def test_uninstall_flag_before_host(self):
        proc = self.run_py("--uninstall", TARGET)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(markers(proc.stdout)[-1], "@@OK version=uninstalled")


# ---------------------------------------------------------------------------
# Byte-for-byte equivalence with the shell script
# ---------------------------------------------------------------------------

@unittest.skipUnless(os.path.exists("/bin/bash") and SH_SCRIPT.exists(),
                     "needs bash + deploy_remote.sh")
class MarkerEquivalenceTests(FakeHostMixin, unittest.TestCase):
    """Run BOTH implementations against identical fakes and diff their stdout.

    This is the marker-protocol proof: any drift in a @@STEP name, a @@FAIL
    reason, the @@OK version digest, or even the surrounding human-readable
    lines shows up here. Scenarios that reach the verify stage make the shell
    script sleep its hardcoded 7s (it has no test hook), so only two of them
    do; the rest short-circuit earlier and are free."""

    def assertSameOutput(self, *args):
        py = self.run_py(*args)
        # Fresh log so the shell run's argv doesn't append onto the python run's.
        if self.log.exists():
            self.log.unlink()
        sh = self.run_sh(*args)
        self.assertEqual(py.stdout, sh.stdout,
                         "stdout diverged:\n--- python ---\n%s\n--- shell ---\n%s"
                         % (py.stdout, sh.stdout))
        self.assertEqual(py.returncode, sh.returncode)
        return py, sh

    def test_equivalent_systemd_happy_path(self):
        py, _ = self.assertSameOutput(TARGET)
        self.assertEqual(markers(py.stdout)[:6], FULL_STEPS)
        self.assertRegex(markers(py.stdout)[6], VERSION_RE)

    def test_equivalent_nohup_path(self):
        self.configure(ssh_overrides={"have_systemctl": {"rc": 1}})
        self.assertSameOutput(TARGET)

    def test_equivalent_connect_failure(self):
        self.configure(ssh_overrides={"connect": {"rc": 255}})
        self.assertSameOutput(TARGET)

    def test_equivalent_python_too_old(self):
        self.configure(ssh_overrides={"python_version_ok": {"rc": 1}})
        self.assertSameOutput(TARGET)

    def test_equivalent_python_missing(self):
        self.configure(ssh_overrides={"which_python": {"stdout": ""}})
        self.assertSameOutput(TARGET)

    def test_equivalent_scp_failure(self):
        self.configure(scp_rc=1)
        self.assertSameOutput(TARGET)

    def test_equivalent_service_failure(self):
        self.configure(ssh_overrides={"daemon_reload": {"rc": 1}})
        self.assertSameOutput(TARGET)

    def test_equivalent_uninstall(self):
        self.assertSameOutput(TARGET, "--uninstall")

    def test_equivalent_uninstall_connect_failure(self):
        self.configure(ssh_overrides={"connect": {"rc": 255}})
        self.assertSameOutput(TARGET, "--uninstall")

    def test_equivalent_remote_command_lines(self):
        """Beyond stdout: the actual remote command strings each ssh receives
        must match too (scp is excluded — the python side deliberately passes
        bare filenames with cwd set, because `C:\\...` would parse as a host)."""
        self.run_py(TARGET)
        py_cmds = self.ssh_commands()
        self.log.unlink()
        self.run_sh(TARGET)
        sh_cmds = self.ssh_commands()
        self.assertEqual(py_cmds, sh_cmds)


# ---------------------------------------------------------------------------
# Payload constant + version hash semantics
# ---------------------------------------------------------------------------

class PayloadConstantTests(unittest.TestCase):
    def test_payload_matches_shell_array(self):
        """Both files ship until the owner cuts HostDeployer over — they must
        agree on the payload or a redeploy from one path silently differs."""
        text = SH_SCRIPT.read_text()
        m = re.search(r"^PAYLOAD_FILES=\(([^)]*)\)", text, re.MULTILINE)
        self.assertIsNotNone(m, "could not find PAYLOAD_FILES=(...) in deploy_remote.sh")
        self.assertEqual(m.group(1).split(), list(dr.PAYLOAD_FILES))

    def test_payload_includes_remote_sync(self):
        self.assertIn("remote_sync.py", dr.PAYLOAD_FILES,
                      "autoresume.py imports remote_sync at module top")

    def test_payload_files_all_exist(self):
        for f in dr.PAYLOAD_FILES:
            self.assertTrue((REPO_DIR / f).is_file(), f)


class ComputeVersionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _files(self, *contents):
        paths = []
        for i, c in enumerate(contents):
            p = self.tmp / ("f%d.py" % i)
            p.write_text(c)
            paths.append(p)
        return paths

    def test_order_independent(self):
        paths = self._files("a", "b", "c")
        self.assertEqual(dr.compute_version(paths),
                         dr.compute_version(list(reversed(paths))))

    def test_content_sensitive(self):
        a = self._files("a", "b")
        v1 = dr.compute_version(a)
        a[0].write_text("a-changed")
        self.assertNotEqual(v1, dr.compute_version(a))

    def test_twelve_hex_chars(self):
        self.assertRegex(dr.compute_version(self._files("x")), r"^[0-9a-f]{12}$")

    @unittest.skipUnless(shutil.which("shasum") or shutil.which("sha256sum"),
                         "needs shasum/sha256sum")
    def test_matches_shell_pipeline(self):
        """hashlib must reproduce the shell's
        `sha256sum each | awk | sort | sha256sum | awk | cut -c1-12`."""
        paths = self._files("alpha\n", "beta\n", "gamma\n")
        if shutil.which("sha256sum"):
            pipeline = ('for f in "$@"; do sha256sum "$f"; done | awk \'{print $1}\' '
                        '| sort | sha256sum | awk \'{print $1}\'')
        else:
            pipeline = ('for f in "$@"; do shasum -a 256 "$f"; done | awk \'{print $1}\' '
                        '| sort | shasum -a 256 | awk \'{print $1}\'')
        out = subprocess.run(["/bin/bash", "-c", pipeline, "x", *[str(p) for p in paths]],
                             capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(dr.compute_version(paths), out[:12])


if __name__ == "__main__":
    unittest.main()
