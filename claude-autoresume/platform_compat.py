#!/usr/bin/env python3
"""platform_compat.py — the daemon's single OS-abstraction seam.

Every OS-specific operation in claude-autoresume goes through this module:
file locking, well-known paths, the process table, detached process spawn,
atomic replace, and the "is a Bash tool child actually executing" command-line
markers. Nothing else in the daemon may call `fcntl`, `ps`, `os.replace`, or
hardcode a `~/Library/...` path.

Design rules (see docs/windows-port-plan.md §1.1):

1. **Pure stdlib, forever.** `ctypes` is fine; pip is not. This module is
   imported by `autoresume.py` at daemon runtime under the system python3
   (launchd on the Mac, systemd/nohup on remote Linux hosts) and is part of
   `deploy_remote.sh`'s PAYLOAD_FILES.
2. **The macOS implementation is the existing code, verbatim.** Each POSIX
   branch below is a byte-for-byte lift of what its caller used to do inline.
   The Mac path must not regress; that is the acceptance bar for this module.
3. **Unknown Windows facts are named constants, not guesses.** Anything the
   plan's Phase 0 recon has not yet answered on a real Windows box is marked
   `# RECON-UNVERIFIED (Rn)` and hoisted into a single module-level constant
   so correcting it later is a one-line edit. Do not silently guess.

Public surface:

    IS_WINDOWS / IS_MACOS / IS_POSIX
    FileLock(path)                     -- blocking exclusive lock, cross-process
    projects_dir() / sessions_dir() / cowork_sessions_dir() / state_dir()
    process_snapshot() -> [(pid, ppid, cmdline)]
    CMDLINE_IS_EXE_NAME_ONLY           -- see process_snapshot()'s docstring
    spawn_detached(argv, cwd, log_fh) -> subprocess.Popen
    replace_with_retry(tmp, dst)
    tool_child_markers() / normalize_cmdline(text)
"""

from __future__ import annotations  # keeps `X | None` hints safe on python3.9 (macOS system python3)

import os
import subprocess
import sys
import time
from pathlib import Path

IS_WINDOWS = os.name == "nt"
IS_MACOS = sys.platform == "darwin"
IS_POSIX = not IS_WINDOWS

if IS_WINDOWS:  # pragma: no cover - exercised only on Windows
    import ctypes
    import msvcrt
    import shutil
    from ctypes import wintypes
else:
    import fcntl


# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
#
# The cross-language protocol with the Swift widget is "take an exclusive,
# indefinitely-blocking lock on byte 0 of a dedicated .lock file"
# (state.json.lock, config.json.lock, usage/snapshots.lock). Both sides must
# implement the same primitive on the same path.
#
# CRITICAL — never recreate or replace the lock file on acquisition. On POSIX
# flock() is per-INODE, so any create/unlink/replace of the lock path hands
# two processes locks on two different inodes and the mutual exclusion becomes
# illusory. That exact bug shipped once on the Swift side (CLAUDE.md hardening
# item #1: `FileManager.createFile` replaced the inode on every acquisition).
# `open(path, "w")` is safe — O_CREAT|O_TRUNC keeps the existing inode — and is
# precisely what every call site did before this module existed.
#
# Windows locks are handle-and-range based rather than inode based, so the
# mechanism does not carry over, but the *intent* (one stable lock object
# shared between processes) does.

# Windows LockFileEx flags. We deliberately pass LOCKFILE_EXCLUSIVE_LOCK
# WITHOUT LOCKFILE_FAIL_IMMEDIATELY: that combination is a true indefinite
# blocking exclusive lock, the only faithful analogue of flock(LOCK_EX).
# msvcrt.locking(LK_LOCK) is NOT an acceptable substitute — it retries 10x over
# 10s and then raises, which silently turns "wait your turn" into "lose the
# update".
_LOCKFILE_FAIL_IMMEDIATELY = 0x00000001
_LOCKFILE_EXCLUSIVE_LOCK = 0x00000002
# Lock byte 0 only. One byte is enough for a pure mutex and keeps the range
# identical no matter how large the (always empty) lock file grows.
_LOCK_BYTES = 1


if IS_WINDOWS:  # pragma: no cover - exercised only on Windows

    class _OVERLAPPED(ctypes.Structure):
        _fields_ = [
            ("Internal", ctypes.c_void_p),
            ("InternalHigh", ctypes.c_void_p),
            ("Offset", wintypes.DWORD),
            ("OffsetHigh", wintypes.DWORD),
            ("hEvent", wintypes.HANDLE),
        ]

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernel32.LockFileEx.argtypes = [
        wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD,
        wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(_OVERLAPPED),
    ]
    _kernel32.LockFileEx.restype = wintypes.BOOL
    _kernel32.UnlockFileEx.argtypes = [
        wintypes.HANDLE, wintypes.DWORD,
        wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(_OVERLAPPED),
    ]
    _kernel32.UnlockFileEx.restype = wintypes.BOOL

    def _acquire(fh) -> None:
        handle = msvcrt.get_osfhandle(fh.fileno())
        overlapped = _OVERLAPPED()
        ok = _kernel32.LockFileEx(
            handle, _LOCKFILE_EXCLUSIVE_LOCK, 0, _LOCK_BYTES, 0,
            ctypes.byref(overlapped),
        )
        if not ok:
            raise OSError(ctypes.get_last_error(), "LockFileEx failed")

    def _release(fh) -> None:
        handle = msvcrt.get_osfhandle(fh.fileno())
        overlapped = _OVERLAPPED()
        ok = _kernel32.UnlockFileEx(
            handle, 0, _LOCK_BYTES, 0, ctypes.byref(overlapped),
        )
        if not ok:
            raise OSError(ctypes.get_last_error(), "UnlockFileEx failed")

else:

    def _acquire(fh) -> None:
        fcntl.flock(fh, fcntl.LOCK_EX)

    def _release(fh) -> None:
        fcntl.flock(fh, fcntl.LOCK_UN)


def _open_lock_file(path: Path):
    """Open (never replace) the lock file and return the handle.

    POSIX uses mode "w" — exactly what StateLock/_CollectLock/_SnapshotsLock
    did inline before this module existed. O_TRUNC on an existing file keeps
    the inode, which is what flock's per-inode semantics require.

    Windows uses "a+b": CreateFile with TRUNCATE_EXISTING can fail on a file
    another process holds a byte-range lock on, and truncation buys us nothing
    (the lock file is always empty). Append-mode create-if-missing gives the
    same "a stable file exists at this path" guarantee without that hazard.
    """
    if IS_WINDOWS:  # pragma: no cover - exercised only on Windows
        return open(path, "a+b")
    return open(path, "w")


class FileLock:
    """Blocking exclusive lock on byte 0 of `path`, shared across processes
    and across languages (the widget takes the same lock on the same file).

    Usage mirrors the classes it replaces::

        with FileLock(state_dir / "state.json.lock"):
            ...

    The caller is responsible for making sure the containing directory exists
    (every existing call site already does its own mkdir first, and this class
    deliberately does not, so it can't mask a bad path).
    """

    def __init__(self, path):
        self._path = Path(path)
        self._fh = None

    def __enter__(self):
        self._fh = _open_lock_file(self._path)
        try:
            _acquire(self._fh)
        except BaseException:
            self._fh.close()
            self._fh = None
            raise
        return self

    def __exit__(self, *exc):
        if self._fh is None:
            return
        try:
            _release(self._fh)
        finally:
            self._fh.close()
            self._fh = None


# ---------------------------------------------------------------------------
# Well-known paths
# ---------------------------------------------------------------------------
#
# `Path.home()` already resolves to %USERPROFILE% on Windows, so the
# dot-directory layout needs no per-OS branch. Only Cowork's location is
# genuinely OS-specific.

# RECON-UNVERIFIED (R5): where Claude Desktop keeps `local-agent-mode-sessions`
# on Windows — or whether Cowork ships on Windows at all. Until a real Windows
# box answers this (`dir /s /b %APPDATA%\Claude %LOCALAPPDATA%\Claude`), the
# honest answer is "unknown", and cowork_sessions_dir() returns None rather
# than pointing at a phantom path. Every caller must treat None as "skip the
# Cowork scan entirely". When R5 lands, set this to the relative path under
# Path.home() (or an absolute Path) and nothing else needs to change.
WINDOWS_COWORK_SESSIONS_SUBPATH: tuple[str, ...] | None = None

# macOS location, unchanged from autoresume.py / usage_collector.py.
_MACOS_COWORK_SESSIONS_SUBPATH = (
    "Library", "Application Support", "Claude", "local-agent-mode-sessions",
)


def home() -> Path:
    return Path.home()


def projects_dir() -> Path:
    """Claude Code CLI transcripts: ~/.claude/projects/**/*.jsonl.

    RECON-UNVERIFIED (R1/R2): that Claude Code on Windows writes the same
    layout under %USERPROFILE%\\.claude\\projects, and how a Windows cwd
    (C:\\Users\\sam\\git\\x) is encoded into the project folder name (which is
    what `guess_project_dir_from_folder` in autoresume.py decodes). The path
    itself is the same expression on both OSes; only the folder-name encoding
    is in doubt, and that decoding lives in autoresume.py, not here.
    """
    return home() / ".claude" / "projects"


def sessions_dir() -> Path:
    """~/.claude/sessions/<pid>.json — the pid->sessionId map that anchors the
    process-liveness half of classify_work_status().

    RECON-UNVERIFIED (R3): that this directory exists on Windows and that the
    `pid` it records is a real Win32 pid usable against process_snapshot().
    """
    return home() / ".claude" / "sessions"


def cowork_sessions_dir() -> Path | None:
    """Claude Desktop's Cowork session metadata directory, or None on any
    platform where Cowork is not known to exist.

    None is a first-class return value: callers MUST skip the Cowork scan
    entirely rather than substituting a fallback path. A phantom path that
    never exists would work by accident on Linux but would be a silent lie on
    Windows, where the real location may well exist somewhere else (R5).
    """
    if IS_MACOS:
        return home().joinpath(*_MACOS_COWORK_SESSIONS_SUBPATH)
    if IS_WINDOWS:  # pragma: no cover - exercised only on Windows
        # RECON-UNVERIFIED (R5) — see WINDOWS_COWORK_SESSIONS_SUBPATH.
        if WINDOWS_COWORK_SESSIONS_SUBPATH is None:
            return None
        return home().joinpath(*WINDOWS_COWORK_SESSIONS_SUBPATH)
    # Linux (remote Shape-C hosts): Claude Desktop does not ship there, so
    # there is no Cowork directory to scan. Previously these hosts computed
    # the macOS path and relied on it never existing; None says the same thing
    # honestly and costs one branch at each call site.
    return None


def state_dir() -> Path:
    """~/.claude-autoresume — the daemon's own state directory.

    Note: this is the plain default. `remote_ctl.py` layers an
    AUTORESUME_STATE_DIR environment override on top of it; the daemon
    deliberately does not honor that variable, and that asymmetry is
    preserved exactly as it was.
    """
    return home() / ".claude-autoresume"


# ---------------------------------------------------------------------------
# Process table
# ---------------------------------------------------------------------------

# True when process_snapshot()'s third tuple element is only an executable
# name (e.g. "bash.exe") rather than a full command line. Windows'
# Toolhelp32 snapshot API does not expose command lines at all, and the
# alternatives (NtQueryInformationProcess + PEB read, or a PowerShell
# Get-CimInstance per 10s poll) are respectively fragile and expensive. A
# caller that needs to identify a process MUST be able to work from exe name
# plus parentage when this flag is True.
CMDLINE_IS_EXE_NAME_ONLY = IS_WINDOWS

# Windows Toolhelp32 constants.
_TH32CS_SNAPPROCESS = 0x00000002
# INVALID_HANDLE_VALUE is (HANDLE)-1; through a HANDLE-typed restype ctypes
# hands it back as the unsigned pointer-sized value, so check both spellings.
_INVALID_HANDLE_VALUES = (-1, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF)
_MAX_PATH = 260


if IS_WINDOWS:  # pragma: no cover - exercised only on Windows

    class _PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD),
            ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD),
            ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
            ("th32ModuleID", wintypes.DWORD),
            ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD),
            ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", wintypes.DWORD),
            ("szExeFile", wintypes.WCHAR * _MAX_PATH),
        ]

    _kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    _kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    _kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
    _kernel32.Process32FirstW.restype = wintypes.BOOL
    _kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
    _kernel32.Process32NextW.restype = wintypes.BOOL
    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    _kernel32.CloseHandle.restype = wintypes.BOOL

    def _process_snapshot_windows() -> list:
        snap = _kernel32.CreateToolhelp32Snapshot(_TH32CS_SNAPPROCESS, 0)
        # CreateToolhelp32Snapshot returns INVALID_HANDLE_VALUE (-1) on
        # failure; as a HANDLE-typed restype that arrives as the unsigned
        # pointer-sized equivalent, so compare against both spellings.
        if snap is None or snap in _INVALID_HANDLE_VALUES:
            return []
        procs = []
        try:
            entry = _PROCESSENTRY32W()
            entry.dwSize = ctypes.sizeof(_PROCESSENTRY32W)
            ok = _kernel32.Process32FirstW(snap, ctypes.byref(entry))
            while ok:
                procs.append((
                    int(entry.th32ProcessID),
                    int(entry.th32ParentProcessID),
                    entry.szExeFile,   # exe name ONLY — see CMDLINE_IS_EXE_NAME_ONLY
                ))
                ok = _kernel32.Process32NextW(snap, ctypes.byref(entry))
        finally:
            _kernel32.CloseHandle(snap)
        return procs


def _process_snapshot_posix() -> list:
    """Verbatim lift of collect_runtime_snapshot()'s inline `ps` parse."""
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,command="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    procs = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        procs.append((pid, ppid, parts[2] if len(parts) > 2 else ""))
    return procs


def process_snapshot() -> list:
    """The whole process table as [(pid, ppid, cmdline), ...].

    Runs once per 10s poll cycle, so it must stay cheap: one `ps` fork on
    POSIX, one snapshot handle + an enumeration loop on Windows (no process
    spawn, and explicitly NOT a PowerShell invocation).

    On Windows the third element is the executable NAME, not a command line
    (`CMDLINE_IS_EXE_NAME_ONLY` is True there) — Toolhelp32 simply does not
    carry command lines. Callers must be written to work from exe name plus
    parentage on that platform.

    An empty list means "no process table available" and callers already treat
    it that way (`have_ps` in collect_runtime_snapshot); it never raises.
    """
    if IS_WINDOWS:  # pragma: no cover - exercised only on Windows
        try:
            return _process_snapshot_windows()
        except OSError:
            return []
    return _process_snapshot_posix()


# ---------------------------------------------------------------------------
# Tool-child command-line markers
# ---------------------------------------------------------------------------
#
# These identify a Bash-tool child process that is genuinely executing under a
# session's pid. Getting this wrong reproduces the false-`needs_input` bug from
# CLAUDE.md hardening item #4 in a new form, so the Windows answer must come
# from recon, not intuition.

# macOS/Linux markers, unchanged: the Bash tool's shell sources a
# shell-snapshot on startup, and the sandboxed variant wraps the same thing.
_POSIX_TOOL_CHILD_MARKERS = (".claude/shell-snapshots/", "sandbox-exec")

# RECON-UNVERIFIED (R4): whether Claude Code on Windows writes
# %USERPROFILE%\.claude\shell-snapshots\ at all, and whether the Git Bash (or
# other) child's command line contains that path. Note also that
# CMDLINE_IS_EXE_NAME_ONLY is True on Windows, so a command-line substring
# match may be structurally impossible there and the signal may have to come
# from exe name + parentage instead (plan §1.2 B2 option 1). `sandbox-exec` is
# macOS-only and must never appear in this tuple on Windows. Correct this one
# constant when R4 lands.
WINDOWS_TOOL_CHILD_MARKERS: tuple[str, ...] = (".claude/shell-snapshots/",)


def tool_child_markers() -> tuple:
    """Substrings that identify an actively-executing Bash-tool child.

    Matched against normalize_cmdline(cmdline), so markers are always written
    with forward slashes.
    """
    if IS_WINDOWS:  # pragma: no cover - exercised only on Windows
        return WINDOWS_TOOL_CHILD_MARKERS
    return _POSIX_TOOL_CHILD_MARKERS


def normalize_cmdline(text: str) -> str:
    """Normalize a command line for marker matching.

    Identity on POSIX (so the Mac's matching is bit-for-bit what it was); on
    Windows it folds backslashes to forward slashes so a single
    forward-slash-spelled marker matches `C:\\Users\\sam\\.claude\\
    shell-snapshots\\...`.
    """
    if IS_WINDOWS:  # pragma: no cover - exercised only on Windows
        return text.replace("\\", "/")
    return text


# ---------------------------------------------------------------------------
# Detached spawn
# ---------------------------------------------------------------------------

# CREATE_NO_WINDOW | DETACHED_PROCESS. A background daemon must never flash a
# console window on the user's desktop when it auto-resumes a session.
# (MSDN notes CREATE_NO_WINDOW is ignored when DETACHED_PROCESS is also set;
# both are passed deliberately so the intent survives either being honored.)
_CREATE_NO_WINDOW = 0x08000000
_DETACHED_PROCESS = 0x00000008

# RECON-UNVERIFIED (R7): what `claude` actually is on a Windows PATH — a
# `claude.cmd` shim, a `claude.exe`, or something else. `subprocess.Popen` on a
# .cmd/.bat WITHOUT shell=True raises [WinError 193], so a shim has to be run
# through the command interpreter. This tuple is the set of extensions treated
# as "needs %COMSPEC% /c"; correct it if R7 turns up another shim form.
WINDOWS_SHIM_SUFFIXES = (".cmd", ".bat")


def spawn_detached(argv, cwd, log_fh):
    """Launch `argv` in `cwd`, streaming stdout+stderr into `log_fh`, without
    waiting for it and without ever showing a console window.

    POSIX is exactly what autoresume.resume_due_sessions did inline:
    `subprocess.Popen(argv, cwd=cwd, stdout=log_fh, stderr=STDOUT)`.

    Returns the Popen object. Raises FileNotFoundError / OSError exactly as
    Popen does, because the caller distinguishes those (a missing CLAUDE_BIN is
    reported differently from a generic launch failure).
    """
    if not IS_WINDOWS:
        return subprocess.Popen(argv, cwd=cwd, stdout=log_fh, stderr=subprocess.STDOUT)

    # pragma: no cover - exercised only on Windows
    argv = list(argv)
    resolved = shutil.which(argv[0])
    if resolved is None:
        # Preserve the caller's FileNotFoundError branch (it prints the
        # "set CLAUDE_BIN" hint) rather than inventing a new failure mode.
        raise FileNotFoundError(2, "No such file or directory", argv[0])
    if os.path.splitext(resolved)[1].lower() in WINDOWS_SHIM_SUFFIXES:
        comspec = os.environ.get("COMSPEC", "cmd.exe")
        argv = [comspec, "/c", resolved] + argv[1:]
    else:
        argv = [resolved] + argv[1:]
    return subprocess.Popen(
        argv, cwd=cwd, stdout=log_fh, stderr=subprocess.STDOUT,
        creationflags=_CREATE_NO_WINDOW | _DETACHED_PROCESS,
        close_fds=False,  # the log handle must survive into the child
    )


# ---------------------------------------------------------------------------
# Atomic replace
# ---------------------------------------------------------------------------
#
# The daemon writes every shared file as tmp-write + atomic rename. On POSIX
# rename(2) over a path another process holds open is fine — readers keep their
# inode. On Windows os.replace() onto a path another process has open fails
# with PermissionError (ERROR_SHARING_VIOLATION) unless every opener passed
# FILE_SHARE_DELETE, which Python's open() does not. Defender and the search
# indexer open files opportunistically, so this fails INTERMITTENTLY — the
# worst possible failure mode, and per the plan the single highest-frequency
# source of Windows bugs in this port.

# ~10 attempts over ~1s total: 10ms, 20ms, 40ms, ... capped, then raise.
REPLACE_MAX_ATTEMPTS = 10
REPLACE_INITIAL_BACKOFF_SECONDS = 0.01
REPLACE_MAX_BACKOFF_SECONDS = 0.25


def replace_with_retry(tmp, dst) -> None:
    """Atomically move `tmp` onto `dst`.

    POSIX: a plain os.replace, identical to the `tmp.replace(dst)` calls this
    replaced — no retry, no added latency, no new failure mode.

    Windows: the same call under bounded exponential retry on PermissionError
    (ERROR_SHARING_VIOLATION), re-raising the last one if it never succeeds.
    Only PermissionError is retried; a genuine error (missing tmp, bad path)
    still surfaces immediately.
    """
    if not IS_WINDOWS:
        os.replace(tmp, dst)
        return

    # pragma: no cover - exercised only on Windows
    delay = REPLACE_INITIAL_BACKOFF_SECONDS
    for attempt in range(REPLACE_MAX_ATTEMPTS):
        try:
            os.replace(tmp, dst)
            return
        except PermissionError:
            if attempt == REPLACE_MAX_ATTEMPTS - 1:
                raise
            time.sleep(delay)
            delay = min(delay * 2, REPLACE_MAX_BACKOFF_SECONDS)
