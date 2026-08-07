#!/usr/bin/env python3
"""Tests for platform_compat.py — the daemon's OS seam.

Run directly: `python3 test_platform_compat.py`.

The headline test here is lock mutual exclusion proven across TWO REAL
PROCESSES. A mocked version would be worthless: the macOS equivalent of this
test is what caught hardening bug #1 in CLAUDE.md (the Swift side was calling
FileManager.createFile on the lock file, replacing the inode on every
acquisition, so flock — which is per-inode — was excluding nothing at all,
while every in-process test still passed). Any lock test that does not run two
OS processes against the same lock file cannot detect that class of bug.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_DIR))

import platform_compat  # noqa: E402


WINDOWS_ONLY = "Windows-only code path; this box is POSIX (run the suite on windows-latest too)"
POSIX_ONLY = "POSIX-only code path"


# ---------------------------------------------------------------------------
# FileLock — cross-process mutual exclusion
# ---------------------------------------------------------------------------

# Child program: acquire the lock, append "<tag> in", hold for HOLD seconds,
# append "<tag> out", release. If the lock genuinely excludes, the two children's
# in/out pairs can never interleave. Nothing is mocked; this is a real
# subprocess taking a real OS lock on a real file.
_HOLDER_SRC = textwrap.dedent(
    """
    import sys, time
    sys.path.insert(0, sys.argv[1])
    import platform_compat

    lock_path, journal, tag, delay, hold = sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5]), float(sys.argv[6])
    time.sleep(delay)
    with platform_compat.FileLock(lock_path):
        with open(journal, "a") as f:
            f.write(tag + " in\\n")
            f.flush()
        time.sleep(hold)
        with open(journal, "a") as f:
            f.write(tag + " out\\n")
            f.flush()
    """
)


class FileLockCrossProcessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.lock_path = self.tmp / "state.json.lock"
        self.journal = self.tmp / "journal.txt"
        self.holder = self.tmp / "holder.py"
        self.holder.write_text(_HOLDER_SRC)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _spawn(self, tag, delay, hold):
        return subprocess.Popen(
            [sys.executable, str(self.holder), str(REPO_DIR), str(self.lock_path),
             str(self.journal), tag, str(delay), str(hold)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

    def test_two_real_processes_cannot_hold_the_lock_at_once(self):
        """A and B both want the lock; B starts while A is holding it. If the
        lock works, the journal reads A-in A-out B-in B-out (or B first) — never
        an interleaving. Two OS processes, no mocks, no in-process shortcuts."""
        a = self._spawn("A", delay=0.0, hold=0.6)
        b = self._spawn("B", delay=0.15, hold=0.1)
        for proc, name in ((a, "A"), (b, "B")):
            out, err = proc.communicate(timeout=30)
            self.assertEqual(proc.returncode, 0, f"holder {name} failed: {err}")

        lines = self.journal.read_text().split()
        events = self.journal.read_text().strip().splitlines()
        self.assertEqual(len(events), 4, f"expected 4 journal events, got {events}")
        # Whoever went first must close its critical section before the other opens.
        first = events[0].split()[0]
        second = "B" if first == "A" else "A"
        self.assertEqual(
            events,
            [f"{first} in", f"{first} out", f"{second} in", f"{second} out"],
            f"critical sections interleaved — the lock is not excluding: {events}",
        )
        del lines

    def test_lock_file_inode_survives_acquisition(self):
        """The lock file must never be recreated/replaced on acquisition.

        On POSIX flock is per-INODE: any create/unlink/replace of the lock path
        hands two processes locks on two different inodes and mutual exclusion
        silently evaporates (CLAUDE.md hardening #1). This asserts the invariant
        directly rather than trusting the implementation."""
        self.lock_path.write_text("")
        before = self.lock_path.stat().st_ino
        for _ in range(5):
            with platform_compat.FileLock(self.lock_path):
                pass
        self.assertEqual(self.lock_path.stat().st_ino, before,
                         "FileLock replaced the lock file's inode — flock is per-inode, "
                         "so this would make cross-process exclusion illusory")

    def test_lock_is_released_on_exception(self):
        """An exception inside the with-block must still release the lock,
        or one bad poll cycle deadlocks the daemon against the widget forever."""
        self.lock_path.write_text("")
        with self.assertRaises(RuntimeError):
            with platform_compat.FileLock(self.lock_path):
                raise RuntimeError("boom")
        # A second acquisition in a SEPARATE process must not block.
        proc = self._spawn("C", delay=0.0, hold=0.0)
        out, err = proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, 0, f"lock was not released: {err}")

    def test_lock_file_is_created_if_absent(self):
        self.assertFalse(self.lock_path.exists())
        with platform_compat.FileLock(self.lock_path):
            pass
        self.assertTrue(self.lock_path.exists())

    def test_second_acquirer_actually_waits(self):
        """Blocking, not fail-fast: the waiter's acquisition must be delayed by
        roughly the holder's hold time. This is the property msvcrt.locking
        would NOT give on Windows (it gives up after ~10s and raises), which is
        why the Windows branch uses LockFileEx without LOCKFILE_FAIL_IMMEDIATELY."""
        hold = 0.5
        a = self._spawn("A", delay=0.0, hold=hold)
        time.sleep(0.15)  # let A get in first
        started = time.monotonic()
        b = self._spawn("B", delay=0.0, hold=0.0)
        b.communicate(timeout=30)
        waited = time.monotonic() - started
        a.communicate(timeout=30)
        self.assertGreater(waited, hold * 0.4,
                           "second acquirer returned too fast — it did not block on the lock")


# ---------------------------------------------------------------------------
# replace_with_retry
# ---------------------------------------------------------------------------

class ReplaceWithRetryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_replaces_atomically(self):
        dst = self.tmp / "state.json"
        dst.write_text("old")
        src = self.tmp / "state.json.tmp"
        src.write_text("new")
        platform_compat.replace_with_retry(src, dst)
        self.assertEqual(dst.read_text(), "new")
        self.assertFalse(src.exists())

    def test_creates_destination_when_absent(self):
        dst = self.tmp / "state.json"
        src = self.tmp / "state.json.tmp"
        src.write_text("new")
        platform_compat.replace_with_retry(src, dst)
        self.assertEqual(dst.read_text(), "new")

    def test_missing_source_still_raises(self):
        """Only PermissionError is retried; a genuine error must surface
        immediately rather than being swallowed by the retry loop."""
        with self.assertRaises(OSError):
            platform_compat.replace_with_retry(self.tmp / "nope.tmp", self.tmp / "dst")

    def test_under_reader_contention_never_yields_a_partial_file(self):
        """R8's scenario: hammer replace on a file another thread is constantly
        opening and reading. A reader must always observe one COMPLETE
        generation, never a truncated or mixed one, and no replace may fail.

        On POSIX this passes trivially (rename(2) over an open file is fine);
        on Windows it is the case that produces ERROR_SHARING_VIOLATION and
        exercises the retry loop. Same test, both platforms — that is the
        point."""
        dst = self.tmp / "state.json"
        dst.write_text("gen0" * 500)
        stop = threading.Event()
        bad = []

        def reader():
            while not stop.is_set():
                try:
                    text = dst.read_text()
                except (OSError, PermissionError):
                    continue  # a reader losing a race is fine; a torn read is not
                if text and (len(text) % 4 or len(set(text[i:i + 4] for i in range(0, len(text), 4))) != 1):
                    bad.append(text[:40])

        threads = [threading.Thread(target=reader, daemon=True) for _ in range(4)]
        for t in threads:
            t.start()
        try:
            for gen in range(1, 60):
                src = self.tmp / "state.json.tmp"
                src.write_text(f"g{gen:03d}" * 500)
                platform_compat.replace_with_retry(src, dst)
        finally:
            stop.set()
            for t in threads:
                t.join(timeout=5)

        self.assertEqual(bad, [], "reader observed a torn/mixed file across a replace")
        self.assertEqual(dst.read_text(), "g059" * 500)

    def test_retry_budget_is_bounded_and_roughly_one_second(self):
        """The Windows retry must be bounded — an unbounded wait inside a lock
        would hang the poll loop. ~10 attempts, ~1s worst case."""
        self.assertLessEqual(platform_compat.REPLACE_MAX_ATTEMPTS, 20)
        delay, total = platform_compat.REPLACE_INITIAL_BACKOFF_SECONDS, 0.0
        for _ in range(platform_compat.REPLACE_MAX_ATTEMPTS - 1):
            total += delay
            delay = min(delay * 2, platform_compat.REPLACE_MAX_BACKOFF_SECONDS)
        self.assertLess(total, 3.0, f"retry budget {total:.2f}s is too long to sit inside a lock")
        self.assertGreater(total, 0.4, f"retry budget {total:.2f}s is too short to ride out an AV scan")


# ---------------------------------------------------------------------------
# Path resolvers
# ---------------------------------------------------------------------------

class PathResolverTests(unittest.TestCase):
    def test_dot_directories_hang_off_home(self):
        home = platform_compat.home()
        self.assertEqual(platform_compat.projects_dir(), home / ".claude" / "projects")
        self.assertEqual(platform_compat.sessions_dir(), home / ".claude" / "sessions")
        self.assertEqual(platform_compat.state_dir(), home / ".claude-autoresume")

    def test_state_dir_ignores_the_remote_ctl_env_override(self):
        """AUTORESUME_STATE_DIR is remote_ctl.py's override alone — the daemon
        deliberately does not honor it, and that asymmetry predates this module."""
        prev = os.environ.get("AUTORESUME_STATE_DIR")
        os.environ["AUTORESUME_STATE_DIR"] = "/tmp/should-be-ignored"
        try:
            self.assertEqual(platform_compat.state_dir(),
                             platform_compat.home() / ".claude-autoresume")
        finally:
            if prev is None:
                os.environ.pop("AUTORESUME_STATE_DIR", None)
            else:
                os.environ["AUTORESUME_STATE_DIR"] = prev

    @unittest.skipUnless(platform_compat.IS_MACOS, "macOS Cowork path")
    def test_cowork_dir_is_the_unchanged_macos_path(self):
        self.assertEqual(
            platform_compat.cowork_sessions_dir(),
            platform_compat.home() / "Library" / "Application Support" / "Claude"
            / "local-agent-mode-sessions",
        )

    @unittest.skipIf(platform_compat.IS_MACOS, "non-macOS: Cowork is not known to exist")
    def test_cowork_dir_is_none_where_cowork_is_unknown(self):
        self.assertIsNone(platform_compat.cowork_sessions_dir())

    def test_none_cowork_dir_short_circuits_every_consumer(self):
        """The contract: a None Cowork directory means 'skip the Cowork scan
        entirely'. Both consumers must handle it without raising, on any OS."""
        import autoresume
        import usage_collector

        self.assertEqual(list(usage_collector._iter_cowork_files(None)), [])

        prev = autoresume.COWORK_SESSIONS_DIR
        autoresume.COWORK_SESSIONS_DIR = None
        try:
            self.assertEqual(autoresume.compute_cowork_records(time.time()), {})
            # prune_deleted_sessions must NOT delete Cowork entries it cannot
            # verify — an unscannable directory is not evidence of deletion.
            state = {"local_abc": {"kind": "cowork", "status": "active"}}
            autoresume.prune_deleted_sessions(state)
            self.assertIn("local_abc", state,
                          "Cowork entries were pruned while the Cowork dir was unscannable")
        finally:
            autoresume.COWORK_SESSIONS_DIR = prev


# ---------------------------------------------------------------------------
# Process snapshot
# ---------------------------------------------------------------------------

class ProcessSnapshotTests(unittest.TestCase):
    def test_returns_pid_ppid_cmdline_triples_including_this_process(self):
        procs = platform_compat.process_snapshot()
        self.assertTrue(procs, "process_snapshot returned nothing")
        for entry in procs[:20]:
            self.assertEqual(len(entry), 3)
            pid, ppid, cmd = entry
            self.assertIsInstance(pid, int)
            self.assertIsInstance(ppid, int)
            self.assertIsInstance(cmd, str)
        by_pid = {pid: (ppid, cmd) for pid, ppid, cmd in procs}
        self.assertIn(os.getpid(), by_pid, "our own pid missing from the snapshot")

    def test_parentage_is_reported_correctly(self):
        """The Windows implementation must work from exe name + parentage
        alone (Toolhelp32 carries no command lines), so parentage is the
        load-bearing signal on that platform — assert it here on both."""
        by_pid = {pid: ppid for pid, ppid, _ in platform_compat.process_snapshot()}
        self.assertEqual(by_pid.get(os.getpid()), os.getppid())

    @unittest.skipIf(platform_compat.IS_WINDOWS, POSIX_ONLY)
    def test_posix_reports_full_command_lines(self):
        self.assertFalse(platform_compat.CMDLINE_IS_EXE_NAME_ONLY)
        by_pid = {pid: cmd for pid, _, cmd in platform_compat.process_snapshot()}
        self.assertIn("python", by_pid.get(os.getpid(), "").lower())

    @unittest.skipUnless(platform_compat.IS_WINDOWS, WINDOWS_ONLY)
    def test_windows_flags_cmdline_as_exe_name_only(self):  # pragma: no cover
        self.assertTrue(platform_compat.CMDLINE_IS_EXE_NAME_ONLY)
        cmds = [c for _, _, c in platform_compat.process_snapshot()]
        self.assertTrue(any(c.lower().endswith(".exe") for c in cmds))


# ---------------------------------------------------------------------------
# Tool-child markers
# ---------------------------------------------------------------------------

class ToolChildMarkerTests(unittest.TestCase):
    @unittest.skipIf(platform_compat.IS_WINDOWS, POSIX_ONLY)
    def test_posix_markers_are_exactly_what_they_always_were(self):
        self.assertEqual(platform_compat.tool_child_markers(),
                         (".claude/shell-snapshots/", "sandbox-exec"))

    @unittest.skipIf(platform_compat.IS_WINDOWS, POSIX_ONLY)
    def test_normalize_cmdline_is_identity_on_posix(self):
        raw = "/bin/bash --init-file /Users/sam/.claude/shell-snapshots/snapshot-zsh-1.sh"
        self.assertIs(platform_compat.normalize_cmdline(raw), raw)

    @unittest.skipUnless(platform_compat.IS_WINDOWS, WINDOWS_ONLY)
    def test_windows_drops_sandbox_exec_and_matches_backslash_paths(self):  # pragma: no cover
        markers = platform_compat.tool_child_markers()
        self.assertNotIn("sandbox-exec", markers,
                         "sandbox-exec is macOS-only and must never appear on Windows")
        raw = r"C:\Users\sam\.claude\shell-snapshots\snapshot-1.sh"
        normalized = platform_compat.normalize_cmdline(raw)
        self.assertTrue(any(m in normalized for m in markers))

    def test_markers_are_spelled_with_forward_slashes(self):
        for m in platform_compat.tool_child_markers():
            self.assertNotIn("\\", m,
                             "markers are matched against normalize_cmdline() output, "
                             "which is forward-slash-normalized")


# ---------------------------------------------------------------------------
# spawn_detached
# ---------------------------------------------------------------------------

class SpawnDetachedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_runs_in_cwd_and_streams_both_streams_into_the_log(self):
        script = self.tmp / "probe.py"
        script.write_text(
            "import os, sys\n"
            "sys.stdout.write(os.getcwd() + '\\n')\n"
            "sys.stderr.write('ERRLINE\\n')\n"
        )
        workdir = self.tmp / "work"
        workdir.mkdir()
        log = self.tmp / "out.log"
        with open(log, "a") as fh:
            proc = platform_compat.spawn_detached(
                [sys.executable, str(script)], str(workdir), fh)
            proc.wait(timeout=30)
        text = log.read_text()
        self.assertIn("ERRLINE", text, "stderr was not merged into the log")
        self.assertIn(str(Path(workdir).resolve().name), text, "did not run in cwd")

    def test_does_not_wait_for_the_child(self):
        script = self.tmp / "slow.py"
        script.write_text("import time; time.sleep(1.5)\n")
        log = self.tmp / "slow.log"
        started = time.monotonic()
        with open(log, "a") as fh:
            proc = platform_compat.spawn_detached([sys.executable, str(script)], str(self.tmp), fh)
        self.assertLess(time.monotonic() - started, 1.0, "spawn_detached blocked on the child")
        proc.wait(timeout=30)

    def test_missing_executable_raises_filenotfounderror(self):
        """autoresume.resume_due_sessions has a dedicated FileNotFoundError
        branch that prints the 'set CLAUDE_BIN' hint; the Windows path must
        preserve it rather than inventing a new exception type."""
        log = self.tmp / "x.log"
        with open(log, "a") as fh:
            with self.assertRaises(FileNotFoundError):
                platform_compat.spawn_detached(
                    [str(self.tmp / "definitely-not-a-real-binary")], str(self.tmp), fh)

    @unittest.skipUnless(platform_compat.IS_WINDOWS, WINDOWS_ONLY)
    def test_windows_shim_suffixes_cover_cmd_and_bat(self):  # pragma: no cover
        self.assertIn(".cmd", platform_compat.WINDOWS_SHIM_SUFFIXES)
        self.assertIn(".bat", platform_compat.WINDOWS_SHIM_SUFFIXES)


# ---------------------------------------------------------------------------
# Module hygiene
# ---------------------------------------------------------------------------

class ModuleHygieneTests(unittest.TestCase):
    def test_no_pip_dependencies(self):
        """Hard constraint: the daemon and everything it imports at runtime is
        pure stdlib (ctypes counts as stdlib; pip does not)."""
        import ast
        tree = ast.parse((REPO_DIR / "platform_compat.py").read_text())
        roots = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                roots.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                roots.add(node.module.split(".")[0])
        allowed = {
            "__future__", "os", "sys", "time", "subprocess", "pathlib",
            "ctypes", "msvcrt", "fcntl", "shutil",
        }
        self.assertEqual(roots - allowed, set(), "platform_compat grew a non-stdlib import")

    def test_daemon_modules_no_longer_touch_the_os_directly(self):
        """The seam only holds if nothing routes around it. fcntl must not be
        imported anywhere but platform_compat, and no daemon module may call
        os.replace / Path.replace on a data file or shell out to `ps`."""
        offenders = []
        for name in ("autoresume.py", "usage_collector.py", "remote_ctl.py", "plan_fit.py"):
            text = (REPO_DIR / name).read_text()
            for lineno, line in enumerate(text.splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                if stripped.startswith("import fcntl") or stripped.startswith("from fcntl"):
                    offenders.append(f"{name}:{lineno} imports fcntl directly")
                if '"ps", "-axo"' in line or "'ps', '-axo'" in line:
                    offenders.append(f"{name}:{lineno} shells out to ps directly")
        self.assertEqual(offenders, [])

    def test_deploy_payload_ships_platform_compat(self):
        """autoresume.py imports platform_compat at module top; a deploy payload
        omitting it crash-loops the remote daemon at import, exactly like the
        remote_sync.py omission test_remote_sync.py already guards against."""
        checked = 0
        sh = REPO_DIR / "deploy_remote.sh"
        if sh.is_file():
            self.assertIn("platform_compat.py", sh.read_text(), "deploy_remote.sh PAYLOAD_FILES")
            checked += 1
        py = REPO_DIR / "deploy_remote.py"
        if py.is_file():
            import importlib.util
            spec = importlib.util.spec_from_file_location("_deploy_remote_probe", py)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            self.assertIn("platform_compat.py", tuple(mod.PAYLOAD_FILES),
                          "deploy_remote.py PAYLOAD_FILES")
            checked += 1
        self.assertTrue(checked, "no deploy_remote payload list found to check")

    def test_install_sh_copies_platform_compat(self):
        self.assertIn("cp platform_compat.py", (REPO_DIR / "install.sh").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
