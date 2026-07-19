# Validate (and if needed, fix) the claude.ai internal-API integration

You are operating on the claude-widget repo. All knowledge of claude.ai's
internal HTTP API is supposed to live in the `ClaudeAPI` SwiftPM target
(`ClaudeUsageOverlay/Sources/ClaudeAPI/`), whose contract with the rest of
the app is defined in `docs/claude-api-module-plan.md` (§3) and
`Sources/ClaudeAPI/CONTRACT.md`. Your job: prove the live API still matches
what the module expects; if it doesn't, fix **only the module**, then prove
it works.

**Bootstrap guard:** if `Sources/ClaudeAPI/` or the `--validate-api` flag
doesn't exist yet, stop and implement `docs/claude-api-module-plan.md`
first (that is the prerequisite for this command), then continue here.

## Step 1 — Build and run the validator

```
cd ClaudeUsageOverlay && swift build -c release
./build_and_run.command   # packages + relaunches the widget; needed so the .app binary is current
"ClaudeUsageOverlay.app/Contents/MacOS/ClaudeUsageOverlay" --validate-api --json
```

The validator must run from the packaged .app binary (cookie-store
bundle-id keying), not `swift run`. It exits 0 (pass), 2 (logged out), or
1 (contract failure) and prints a JSON report.

## Step 2 — Interpret

- **Exit 0:** report "API contract verified" with the per-check list. Also
  run `scripts/check_api_boundary.sh` and confirm the widget itself is
  healthy (usage bars populated: check the running widget or
  `log stream`/NSLog output for a successful fetch). Done — do not change
  any code.
- **Exit 2 (logged out):** not a code problem. Tell the user to open the
  widget's login window and sign in to claude.ai, then re-run this
  command. Stop — do not attempt a code fix, and never handle credentials
  yourself.
- **Exit 1:** one or more contract checks failed. Go to Step 3.

## Step 3 — Diagnose the drift

1. Re-run with a raw dump into the session scratchpad (never the repo):
   `… --validate-api --json --dump-raw <scratchpad>/api-dump`
2. Read the dumped bodies and the failing check's `detail`. Determine what
   changed: endpoint path (404s), response envelope, field renames, new
   status/worker_status vocabulary, org-selection shape, auth convention.
3. Privacy rules while diagnosing: the dumps are the user's account data.
   Don't paste titles/content into your summary, don't commit the dumps,
   delete the dump dir when finished.

## Step 4 — Fix (module only)

- Edit only files under `Sources/ClaudeAPI/`. The public DTOs and their
  semantics (plan §3) are the contract: prefer fixes that keep them
  unchanged. If the API removed a concept outright and a DTO field can no
  longer be populated, keep the field, populate it as nil/`.unknown`, and
  flag the degradation prominently in your final summary — changing the
  public interface requires updating consumers and calling it out
  explicitly.
- Hard constraints that survive any API change:
  - `snapshots.jsonl` on-disk format is frozen (Python compactor +
    GraphModel parse it). SnapshotLogger's output must stay identical.
  - `.loggedOut` remains the single re-auth signal; 401/403 must never be
    misread as a shape failure.
  - Unknown `worker_status` values map to `.unknown`, never crash.
  - No response bodies or account data in logs or error details.
  - Do not change polling cadences or add retries beyond what exists.
- Update `Sources/ClaudeAPI/CONTRACT.md` to describe the newly observed
  shapes, with today's date, the way the existing empirical comments do.

## Step 5 — Verify the fix

1. `swift build -c release` clean.
2. `scripts/check_api_boundary.sh` passes (the fix leaked nothing
   outside the module).
3. Re-run the validator: must exit 0.
4. `python3 claude-autoresume/test_usage_collector.py` (snapshot-format
   guard) and any Swift tests that exist.
5. `./build_and_run.command`, then confirm in the live widget: usage
   percentages render, Sessions list shows cloud sessions (if any exist),
   no error text in the panel.
6. Delete the raw-dump dir.

## Step 6 — Report

Summarize: what the API changed, exactly which module files were edited,
confirmation that the public interface did or did not change (and if it
did, which consumers were touched), validator before/after results, and
the live-widget verification. Do not commit unless the user asked;
if asked, keep dumps and scratch files out of the commit.
