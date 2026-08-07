#!/usr/bin/env python3
"""Step 5 of the Windows spike: cross-process locking and the
sharing-violation check. Pure stdlib, Windows-only.

IMPORTANT — copy `claude-autoresume/platform_compat.py` into this folder
before running. If it's present, this script exercises the REAL FileLock and
replace_with_retry the daemon will ship, which is the entire point of the
step. Without it, it falls back to an inline LockFileEx that mirrors the same
call, which proves the OS behaves but NOT that our implementation does.

Usage
-----
  python holder.py hold   C:\\spike\\state.json.lock      # window A: hold 20s
  python holder.py hold   C:\\spike\\state.json.lock      # window B: should BLOCK
  python holder.py hammer C:\\spike\\state.json           # step 5b: 200 replaces

Step 5 PASS  = window B blocks ~20s and acquires only after A prints releasing.
Step 5 FAIL  = window B acquires immediately. The two sides are locking
               different things and the cross-language contract does not
               exist. This is the Windows twin of the flock-per-inode bug that
               once made the Mac's locking illusory while looking correct.
Step 5b      = a NONZERO naive-failure count proves replace_with_retry is
               required. Zero is a WEAKER result, not a pass: it means the
               race is rarer than the loop, not that it is absent.
"""

import os
import sys
import time
from pathlib import Path

try:
    import platform_compat  # the real thing, if copied in beside this script
    HAVE_REAL = True
except ImportError:
    platform_compat = None
    HAVE_REAL = False


def _stamp(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _inline_lock(path):
    """Fallback mirroring platform_compat.FileLock's LockFileEx call."""
    import ctypes
    import ctypes.wintypes as w
    import msvcrt
    LOCKFILE_EXCLUSIVE_LOCK = 0x2
    fh = open(path, "a+b")
    handle = msvcrt.get_osfhandle(fh.fileno())
    overlapped = (ctypes.c_byte * 32)()
    ok = ctypes.windll.kernel32.LockFileEx(
        w.HANDLE(handle), LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0,
        ctypes.byref(overlapped))
    if not ok:
        raise OSError(ctypes.get_last_error(), "LockFileEx failed")
    return fh


def cmd_hold(path, seconds=20):
    which = "platform_compat.FileLock (REAL)" if HAVE_REAL else "inline LockFileEx (fallback)"
    _stamp(f"acquiring via {which} ...")
    if HAVE_REAL:
        with platform_compat.FileLock(Path(path)):
            _stamp("ACQUIRED — holding")
            time.sleep(seconds)
            _stamp("releasing")
    else:
        fh = _inline_lock(path)
        _stamp("ACQUIRED — holding")
        time.sleep(seconds)
        _stamp("releasing")
        fh.close()


def cmd_hammer(path, n=200):
    """Naive tmp+replace vs replace_with_retry, while another process holds
    the target open for reading (run the PowerShell reader loop from
    README.md step 5b in another window first)."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("{}")

    naive_failures = 0
    for i in range(n):
        tmp = target.with_suffix(".tmp")
        tmp.write_text('{"i": %d}' % i)
        try:
            os.replace(tmp, target)
        except PermissionError:
            naive_failures += 1
            try:
                tmp.unlink()
            except OSError:
                pass
    print(f"naive os.replace failures: {naive_failures}/{n}", flush=True)

    if HAVE_REAL:
        retry_failures = 0
        for i in range(n):
            tmp = target.with_suffix(".tmp")
            tmp.write_text('{"i": %d}' % i)
            try:
                platform_compat.replace_with_retry(tmp, target)
            except OSError:
                retry_failures += 1
        print(f"replace_with_retry failures: {retry_failures}/{n}", flush=True)
        print("EXPECT: naive > 0 and retry == 0. If naive == 0 the loop just "
              "missed the race — rerun, don't conclude.", flush=True)
    else:
        print("platform_compat.py not found — copy it in to test the real "
              "replace_with_retry.", flush=True)


if __name__ == "__main__":
    if os.name != "nt":
        sys.exit("This script only means anything on Windows.")
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, target = sys.argv[1], sys.argv[2]
    if cmd == "hold":
        cmd_hold(target)
    elif cmd == "hammer":
        cmd_hammer(target)
    else:
        sys.exit(__doc__)
