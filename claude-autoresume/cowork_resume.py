#!/usr/bin/env python3
"""
cowork_resume.py
=================

Track 1 scaffolding: Cowork session auto-resume via OS-level UI automation
of Claude Desktop's own "Resume" space (internal enum spotted during
reverse-engineering: Code / Design / Resume / Cowork / LocalSessions — see
HANDOFF.md). This module owns the *orchestration* around that automation —
control flow, session matching, fail-safe logic, and logging — called from
autoresume.py's poll loop for every Cowork session the widget has armed via
`resume_armed` in state.json.

THIS MODULE DOES NOT CLICK ANYTHING. See the DRY_RUN gate directly below.

Design constraints carried over from the rest of this project (see
HANDOFF.md's "Constraints to keep in mind" and autoresume.py's module
docstring): nothing resumes without an explicit per-session opt-in. Here
that opt-in is two-layered — `resume_armed` (set by the user in the widget)
AND the module-level DRY_RUN gate (flipped only after a human reviews the
recon in diagnostics/cowork_resume_recon.md and the click-target plan, and
says so explicitly). Both must be satisfied before any live action would
even be attempted; today DRY_RUN alone is enough to guarantee nothing
happens.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable

# ---------------------------------------------------------------------------
# HARD SAFETY GATE
# ---------------------------------------------------------------------------
# Hardcoded True. This is the only thing standing between "log what we'd do"
# and "actually move the mouse and click in the user's running Claude
# Desktop app". Do NOT flip this to False as part of routine development,
# refactoring, or "just testing it once" — flipping it requires:
#   1. Verified, current recon of the Resume space's actual layout (see
#      diagnostics/cowork_resume_recon.md — screenshots + planned
#      click-target *descriptions*, not hardcoded coordinates, since layout
#      can shift between app versions/window sizes).
#   2. Explicit, in-the-moment sign-off from the user (Sam) after reviewing
#      that recon and this module's control flow — not a standing
#      preference, a specific "yes, go live" for this change.
#   3. A record of who signed off and when, added right here in this
#      comment, at the time DRY_RUN is flipped.
# Until all of that has happened, this stays True.
DRY_RUN = True


APP_NAME = "Claude"  # Claude Desktop's app/process name, for bringing it forward


class Space:
    """Claude Desktop's internal space/tab enum (confirmed to exist via
    app.asar reverse-engineering; on-screen label and navigation path for
    RESUME not yet confirmed live against the running app — see the recon
    doc)."""
    CODE = "Code"
    DESIGN = "Design"
    RESUME = "Resume"
    COWORK = "Cowork"
    LOCAL_SESSIONS = "LocalSessions"


class ResumeOutcome:
    RESUMED = "resumed"
    SKIPPED_NOT_FOUND = "skipped_not_found"
    ABORTED_AMBIGUOUS = "aborted_ambiguous"
    ABORTED_APP_NOT_FOUND = "aborted_app_not_found"
    ABORTED_SPACE_NOT_FOUND = "aborted_space_not_found"
    ABORTED_VERIFY_FAILED = "aborted_verify_failed"


@dataclass
class SessionMatch:
    """A candidate row spotted in the Resume space matching a target
    session, as the (future) screen-reading layer would report it."""
    session_id: str
    title: str
    note: str = ""


# ---------------------------------------------------------------------------
# Session selection
# ---------------------------------------------------------------------------

def is_cowork_entry(entry: dict) -> bool:
    return entry.get("project_name") == "Cowork"


def eligible_sessions(state: dict) -> list[tuple[str, dict]]:
    """Armed + rate-limited Cowork sessions that haven't been handled yet.

    Note: as of this build, scan_cowork_sessions() in autoresume.py only
    ever marks Cowork sessions "active" (Cowork has no rate-limit/resume
    concept exposed today — see that function's docstring), so `status ==
    "waiting"` never actually fires for a Cowork entry yet. This filter is
    written against the target end state (Cowork sessions reaching
    "waiting" once that detection lands) rather than today's reality, so
    the orchestration below is exercised by tests/dry-run reasoning but
    won't fire in the live daemon until that follow-up work is done. That's
    intentional for Track 1 (plumbing + dry-run scaffolding only).
    """
    out = []
    for session_id, entry in state.items():
        if not is_cowork_entry(entry):
            continue
        if entry.get("handled"):
            continue
        if not entry.get("resume_armed"):
            continue
        if entry.get("status") != "waiting":
            continue
        out.append((session_id, entry))
    return out


# ---------------------------------------------------------------------------
# Stubbed UI-action layer
# ---------------------------------------------------------------------------
# Every function below is a no-op / log-only stub while DRY_RUN is True.
# They exist so the control-flow functions further down have a stable
# interface to call — filling these in with real accessibility-API/UI
# automation calls is explicitly OUT of scope for Track 1 and gated behind
# DRY_RUN as described above.

def _bring_app_forward(log: Callable[[str], None]) -> bool:
    if DRY_RUN:
        log(f"[dry-run] would bring '{APP_NAME}' to the foreground")
        return True
    raise NotImplementedError(
        "Live UI automation is not implemented. DRY_RUN must stay True until "
        "explicit sign-off — see the module docstring."
    )


def _navigate_to_resume_space(log: Callable[[str], None]) -> bool:
    if DRY_RUN:
        log(f"[dry-run] would navigate to the '{Space.RESUME}' space")
        return True
    raise NotImplementedError(
        "Live UI automation is not implemented. DRY_RUN must stay True until "
        "explicit sign-off — see the module docstring."
    )


def _take_screenshot(log: Callable[[str], None], label: str) -> str:
    if DRY_RUN:
        log(f"[dry-run] would take a '{label}' screenshot")
        return f"dry-run-no-screenshot:{label}"
    raise NotImplementedError(
        "Live UI automation is not implemented. DRY_RUN must stay True until "
        "explicit sign-off — see the module docstring."
    )


def _find_session_on_screen(
    session_id: str, title: str, log: Callable[[str], None]
) -> list[SessionMatch]:
    if DRY_RUN:
        log(
            f"[dry-run] would search the Resume space's session list for "
            f"title={title!r} id={session_id} (dry-run assumes a single match "
            f"for logging purposes only — no real screen was read)"
        )
        return [SessionMatch(session_id=session_id, title=title, note="dry-run assumed match")]
    raise NotImplementedError(
        "Live UI automation is not implemented. DRY_RUN must stay True until "
        "explicit sign-off — see the module docstring."
    )


def _click_resume(match: SessionMatch, log: Callable[[str], None]) -> bool:
    if DRY_RUN:
        log(f"[dry-run] would click Resume on: title={match.title!r} id={match.session_id}")
        return True
    raise NotImplementedError(
        "Live UI automation is not implemented. DRY_RUN must stay True until "
        "explicit sign-off — see the module docstring."
    )


def _verify_resume(before_screenshot: str, log: Callable[[str], None]) -> bool:
    if DRY_RUN:
        log(
            f"[dry-run] would take an after-screenshot and compare against "
            f"'{before_screenshot}' to verify the session actually resumed "
            f"(not just that a click happened)"
        )
        return True
    raise NotImplementedError(
        "Live UI automation is not implemented. DRY_RUN must stay True until "
        "explicit sign-off — see the module docstring."
    )


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

def process_session(session_id: str, entry: dict, log: Callable[[str], None]) -> str:
    """Runs the full resume flow for one armed + rate-limited Cowork
    session: bring the app forward, navigate to Resume, match by
    title/id, click Resume, verify via before/after screenshot.

    Fail-safe by design, never raises for expected failure modes:
      - app or Resume space not reachable -> abort, flag needs_attention
      - session not found in the Resume list -> skip just this one
      - multiple ambiguous matches -> resume none, flag needs_attention
      - click or verification fails -> flag needs_attention

    Returns a ResumeOutcome string; does not mutate `entry` itself — the
    caller (process_armed_sessions) applies the resulting state change so
    all state.json mutation stays in one place for auditability.
    """
    title = entry.get("session_title") or "(untitled)"
    log(f"cowork_resume: checking armed session {session_id} ({title!r})")

    if not _bring_app_forward(log):
        log(f"cowork_resume: {session_id} — could not bring {APP_NAME} forward; aborting, flagging needs_attention")
        return ResumeOutcome.ABORTED_APP_NOT_FOUND

    if not _navigate_to_resume_space(log):
        log(f"cowork_resume: {session_id} — could not find/navigate to the '{Space.RESUME}' space; aborting, flagging needs_attention")
        return ResumeOutcome.ABORTED_SPACE_NOT_FOUND

    before = _take_screenshot(log, "before")

    matches = _find_session_on_screen(session_id, title, log)
    if len(matches) == 0:
        log(f"cowork_resume: {session_id} — not found in the Resume space's list; skipping this session, continuing others")
        return ResumeOutcome.SKIPPED_NOT_FOUND
    if len(matches) > 1:
        log(f"cowork_resume: {session_id} — {len(matches)} ambiguous matches for title={title!r}; resuming none, flagging needs_attention")
        return ResumeOutcome.ABORTED_AMBIGUOUS

    match = matches[0]
    if not _click_resume(match, log):
        log(f"cowork_resume: {session_id} — Resume click did not succeed; flagging needs_attention")
        return ResumeOutcome.ABORTED_VERIFY_FAILED

    _take_screenshot(log, "after")
    if not _verify_resume(before, log):
        log(f"cowork_resume: {session_id} — could not verify the resume via before/after screenshot; flagging needs_attention")
        return ResumeOutcome.ABORTED_VERIFY_FAILED

    verb = "would mark" if DRY_RUN else "marking"
    log(f"cowork_resume: {session_id} — resume verified, {verb} handled")
    return ResumeOutcome.RESUMED


def process_armed_sessions(state: dict, log: Callable[[str], None]) -> None:
    """Entry point called from autoresume.py's poll loop, inside the same
    StateLock the rest of the daemon already holds for that cycle. Mutates
    `state` in place (needs_attention, and — only once DRY_RUN is False —
    handled/status/resume_armed on an actual successful resume); the caller
    is responsible for persisting it via save_state(), same as every other
    state-mutating step in that loop.

    In dry-run mode (the only mode today) this never marks anything
    handled or disarms anything — it only logs intent and clears/sets
    needs_attention so the widget reflects what a live run *would* have
    flagged, without ever pretending a resume actually happened.
    """
    candidates = eligible_sessions(state)
    if not candidates:
        return

    mode = "DRY-RUN" if DRY_RUN else "LIVE"
    log(f"cowork_resume: {mode} — {len(candidates)} armed Cowork session(s) eligible this cycle")

    for session_id, entry in candidates:
        outcome = process_session(session_id, entry, log)

        if outcome == ResumeOutcome.RESUMED:
            entry["needs_attention"] = False
            if not DRY_RUN:
                entry["handled"] = True
                entry["handled_at"] = time.time()
                entry["status"] = "resumed"
                entry["resume_armed"] = False
        elif outcome == ResumeOutcome.SKIPPED_NOT_FOUND:
            # Not an error condition — leave armed, try again next cycle.
            pass
        else:
            # ABORTED_AMBIGUOUS / ABORTED_APP_NOT_FOUND /
            # ABORTED_SPACE_NOT_FOUND / ABORTED_VERIFY_FAILED
            entry["needs_attention"] = True
