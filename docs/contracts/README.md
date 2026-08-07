# On-disk contracts

Five files under `~/.claude-autoresume/` are written in one language and read
in another. Until now their schemas existed only as prose in `CLAUDE.md` plus
matching hand-written Python writers and Swift readers, so nothing detected
drift — you found out when a field silently read as `nil` in the UI.

This directory is the machine-checkable version of that prose. It is the same
pattern `ClaudeAPI/CONTRACT.md` + `Validate.swift` already apply to the
*outward* claude.ai API, applied inward.

| Contract | File | Written by | Read by |
| --- | --- | --- | --- |
| [`state.schema.json`](state.schema.json) | `state.json` | `autoresume.py`, `remote_sync.py`, `remote_ctl.py apply-toggles`, widget `SessionsModel` (toggles only) | widget `SessionsModel`, `autoresume.py`, `remote_sync.py` |
| [`config.schema.json`](config.schema.json) | `config.json` | widget `ConfigStore` **only** (plus `remote_ctl.py apply-config` on remotes) | `autoresume_config.py`, widget `ConfigStore` |
| [`plan_fit.schema.json`](plan_fit.schema.json) | `usage/plan_fit.json` | `plan_fit.py` | widget `PlanFitModel`, `GraphModel` |
| [`snapshots.schema.json`](snapshots.schema.json) | `usage/snapshots.jsonl`, `usage/snapshots_15m.jsonl`, `usage/snapshots_1h.jsonl` | widget `SnapshotLogger` (raw rows), `usage_collector.py` (bucket rows) | widget `GraphModel`, `plan_fit.py`, `usage_collector.py` |
| [`scoped_limits.schema.json`](scoped_limits.schema.json) | `usage/scoped_limits.json` | widget `ScopedLimitLogger` | `autoresume.py` |

Each schema is JSON Schema draft 2020-12 with an `$id`, an
`x-contract-version`, per-field `description`s sourced from the code comments
that explain **why** the field exists, and explicit `required` vs optional. The
`x-owner`, `x-writers`, `x-readers` and `x-reader` annotations record who is
allowed to write what — for `state.json` in particular that ownership split is
the most important thing in the document.

**These schemas describe what exists TODAY.** Several things they document are
wrong-ish (see [Findings](#findings)). Nothing here changes an on-disk format.

## Ownership and writer rules

These are load-bearing constraints, not conventions. Violating one is how the
project has previously lost user toggles or silently dropped data.

- **`state.json` has three owners, per field.**
  - *Daemon-owned*: `status`, `work_status`, `kind`, `resets_at`,
    `project_dir`, `project_name`, `session_title`, `prompt_preview`,
    `last_activity_at`, `last_seen`, `detected_at`, `handled`, `handled_at`,
    `scoped_model`, `pending_tool`, `needs_attention`.
  - *Widget-owned*: `enabled`, `force_resume`, `resume_armed`. The daemon's
    merge functions preserve these **verbatim** across every cycle and across
    an `active` → `waiting` transition. Nothing in the daemon ever sets
    `enabled` true — that is the project's opt-in hard constraint.
  - *Sync-owned* (`remote_sync.py` only): `host`, `remote_id`, `remote_stale`,
    `remote_last_sync`.
- **Every `state.json` read-modify-write takes the `state.json.lock` flock**,
  on both sides. `flock` is per-inode: never `createFile` / recreate that lock
  file, or the two processes lock different inodes and exclude nothing.
- **`config.json` has exactly one writer on the Mac** — the widget's Settings
  window, via `ConfigStore` (flock on `config.json.lock`, tmp + rename,
  **unknown keys preserved**). The Python side only reads, is fully defensive,
  and treats a missing or malformed file as the defaults. A remote host's
  `config.json` may additionally be written by `remote_ctl.py apply-config`,
  solely as a relay of `sessions.idle_retention_minutes`. The daemon itself
  never writes `config.json` on any host.
- **The widget never truncates `snapshots.jsonl`.** It only appends
  (`O_APPEND`, one `write()` of one complete line). The Python compactor owns
  all pruning. Both sides hold `usage/snapshots.lock` — the widget around each
  append, the compactor across its whole stage-1 read → rename — because an
  append landing inside that window would otherwise be silently dropped.
- **`scoped_limits.json` and `plan_fit.json` are single-writer**, written with
  an atomic replace, and take no lock. Adding a second writer to either would
  require adding one.

## Validating

```
# One file against one contract
python3 claude-autoresume/contracts.py state       ~/.claude-autoresume/state.json
python3 claude-autoresume/contracts.py config      ~/.claude-autoresume/config.json
python3 claude-autoresume/contracts.py plan_fit    ~/.claude-autoresume/usage/plan_fit.json
python3 claude-autoresume/contracts.py scoped_limits ~/.claude-autoresume/usage/scoped_limits.json
python3 claude-autoresume/contracts.py snapshots.raw    ~/.claude-autoresume/usage/snapshots.jsonl
python3 claude-autoresume/contracts.py snapshots.bucket ~/.claude-autoresume/usage/snapshots_15m.jsonl

python3 claude-autoresume/contracts.py --list      # every registered name
```

From Python:

```python
import contracts
errors = contracts.validate("state", json.loads(text))       # [] == valid
errors = contracts.validate_jsonl("snapshots.raw", text)     # per-line, with line numbers
```

`contracts.py` is a **pure-stdlib** validator implementing the subset of JSON
Schema these schemas use — the daemon is hard-constrained to system `python3`
(launchd on the Mac, and remote SSH boxes that have nothing else), so
`jsonschema` is not an option. `contracts.SUPPORTED_KEYWORDS` lists what it
enforces, and `test_contracts.py` asserts no schema has quietly started using a
keyword it would silently ignore.

Deliberate non-goals:

- **Not wired into the daemon's poll loop.** Validating a 2 MB
  `plan_fit.json` every hour buys nothing at runtime. Tests and manual
  diagnosis only.
- **Not in the deploy payload.** `install.sh` and `deploy_remote.sh` copy an
  explicit file list; `contracts.py` is not on it, and it resolves
  `docs/contracts/` relative to the repo, so it is a repo-only tool.

## Tests

```
cd claude-autoresume && python3 test_contracts.py
```

Three layers, in increasing order of usefulness:

1. **Validator self-tests** — the hand-rolled subset really does handle type
   unions, `bool` not counting as a number, `oneOf` exclusivity,
   `additionalProperties: false`, `dependentRequired`, and local `$ref`s.
2. **Fixture tests** — each schema accepts a synthesized good instance and
   rejects targeted bad ones, so a schema cannot quietly degrade into
   "accepts anything".
3. **Round-trip tests** — the **real writers** are run against synthetic
   inputs and their output is asserted to validate:
   `plan_fit.compute()` / `write_plan_fit()`, `compute_cli_records` →
   `merge_cli_records`, `compute_cowork_records` → `merge_cowork_records`,
   `reconcile_scoped_limit_resets`, `resume_due_sessions`, `save_state`,
   `remote_sync._merge_host`, and `usage_collector.compact()` (including a
   second pass that merges into existing buckets). Plus two cross-writer
   round-trips: the compactor's output being consumed by `plan_fit`, and a
   schema-valid `config.json` / `scoped_limits.json` being consumed by the
   real Python readers.

That third layer is what actually catches drift. Add a field to a writer
without adding it to the schema and those tests fail, because every object
schema is `additionalProperties: false` (except `config.json`'s root and
per-host objects, where unknown-key preservation is a stated design rule).

All fixture data is synthesized. No real session id, project path, session
title or token count appears in the schemas or the tests.

## Versioning policy

Only `config.json` carries an in-band `version`. The other four have **no**
version field at all — a real gap, recorded as finding F0-1 — so their only
versioning signal is `x-contract-version` in the schema document. Until that
changes, the practical policy is:

**Adding a field (the normal case, backward-compatible):**

1. Add it to the writer.
2. Add it to the schema with a `description` explaining *why it exists*, and
   put it in `required` **only if every writer path emits it unconditionally**.
   Otherwise leave it optional and add an `x-optional-because` note.
3. Make the reader on the other side treat it as optional, with a documented
   degradation for "the other component predates this field". Every existing
   optional-but-always-written field in these schemas has such a fallback in
   the Swift reader (`kind`, `work_status`, `last_activity_at`,
   `capped_hours_*` …), and that is exactly what makes the two components
   independently deployable — which they are: `CLAUDE.md`'s deploy notes
   repeatedly record the widget being rebuilt while the daemon has not been
   reinstalled yet.
4. Note the reader-side default in the field's `x-reader` annotation. A
   fail-open default (Swift's `viable ?? true`, `status ?? "active"`) is worth
   flagging loudly — see F1-3 and F3-2.
5. Bump `x-contract-version` on the schema document.

**Removing or retyping a field (breaking):** don't, if the older reader would
misread rather than ignore it. If it must happen, the safe sequence is
write-both → migrate the reader → stop writing the old field, across at least
one release of each component. `throttle_days_*_per_month` is the worked
example: its *meaning* changed from "days on which a cap was touched" to
"days' worth of lockout time", and the name was deliberately kept so older
widget builds keep rendering the column — which also means an old widget
silently shows a differently-defined number. That is the cost of the
no-version design.

**Adding a value to an enum** (a new plan tier, a new `work_status`) is
breaking in practice, because the Swift readers iterate hardcoded key lists
(`["pro", "max_5x", "max_20x"]`, `["1d", "7d", "30d", "90d"]`) and would
simply not render the new one. The schemas' `required`/`enum` sets are
deliberately strict here so the tests fail loudly rather than the UI silently
omitting a row.

---

## Findings

Every disagreement found between the Python writers and the Swift readers
while deriving these schemas. **Nothing below has been fixed** — this pass was
documentation and validation only. Ordered roughly by how likely each is to
bite.

### Cross-cutting

**F0-1 — Four of the five formats have no version field.** Only `config.json`
has one, and *nothing reads it* (see F2-6). `state.json`, `plan_fit.json`, both
snapshot row shapes and `scoped_limits.json` carry no in-band version at all,
so a reader has no way to distinguish "written by an older component" from
"malformed". Every reader compensates with per-field optionality and silent
defaults, which works but makes a genuinely-breaking change indistinguishable
from a benign one. This is the root cause of most findings below.

**F0-2 — Tier and window lists are duplicated in four places.** The canonical
plan keys live in `plan_fit.TIER_MULTIPLIERS`, are re-declared in
`autoresume_config.VALID_PLANS` (deliberately, with a comment — that module
must not import `plan_fit`), and are hardcoded *again* in
`PlanFitModel.planDisplayNames` and in the `for key in ["pro", "max_5x",
"max_20x"]` loop of `PlanFitModel.parse`. `moving_averages` has the same
problem: `plan_fit.MA_WINDOWS_DAYS` vs. a hardcoded `["1d","7d","30d","90d"]`
in Swift. Adding a tier or a window on the Python side produces output the
widget silently drops on the floor.

### `state.json`

**F1-1 — `resume_armed` is not universal, but three writers disagree about
that.** The daemon writes it only when *creating* a Cowork entry; local CLI
entries never get it. But `remote_sync._merge_host` stamps it on **every**
remote entry regardless of kind (it is in `WIDGET_OWNED_FIELDS`), and
`SessionsModel.setResumeArmed` can add it to any entry the widget asks about.
Swift's `SessionEntry` declares it non-optional with a `?? false` default, so
nothing breaks today — but the field's presence carries no meaning, which is
why the schema has to mark it optional and explain three separate reasons.

**F1-2 — `needs_attention` has the same shape problem**, minus the remote
stamping: written only on Cowork entry creation, defaulted to `false` by the
reader everywhere else.

**F1-3 — The Swift reader fails OPEN on `status`.** `dict["status"] as? String
?? "active"` means an entry whose status key is missing, null, or a non-string
renders as a **live active session**. `project_dir` is the only field the
reader treats as mandatory (a missing one skips the entry). A truncated or
partially-written entry therefore shows up in the Sessions list rather than
being suppressed.

**F1-4 — Five daemon-written fields are read by nobody:** `detected_at`,
`handled_at`, `scoped_model`, `pending_tool`, `remote_last_sync`. All are used
internally by the daemon (prune timing, scoped-limit reconciliation,
sync bookkeeping), so they are not dead — but the widget never sees them, and
`remote_last_sync` in particular is stamped for a staleness display that does
not exist.

**F1-5 — Two clock bases coexist inside one entry, unmarked.** For a remote
session `remote_sync` skew-adjusts `last_activity_at`, `detected_at` and
`handled_at` onto the Mac clock, but deliberately does **not** adjust
`resets_at` (it is server wall-clock, correct on both machines). Nothing in the
entry records which fields were shifted, so a future consumer comparing
`resets_at` against `last_activity_at` on a skewed host would be comparing two
different clocks.

**F1-6 — `status` has four values; the Swift type comments say two.**
`SessionEntry.status` is documented `// "active" | "waiting"` but the daemon
also writes `resumed` and `failed`. Harmless *today* only because both always
coincide with `handled = true`, which the widget filters out before
constructing entries — an invariant nothing enforces.

**F1-7 — Three fields exist purely as "old daemon build" fallbacks that can no
longer trigger.** Swift treats `kind`, `work_status` and `last_activity_at` as
optional with documented degradations (`projectName == "Cowork"` heuristic;
legacy blue/orange dot; `"active now"` text). The current daemon always writes
all three. The fallbacks are correct defensive practice given F0-1, but they
are untestable dead paths against any daemon in this repo.

**F1-8 — The two writers use different JSON formatting for the same file.**
The daemon writes `json.dumps(state, indent=2)`; the widget rewrites the whole
file with `JSONSerialization(.prettyPrinted)`. No semantic difference, but
every widget toggle produces a whole-file diff, and any future attempt to
diff or version this file will be noisy.

### `config.json`

**F2-1 — Host `enabled` defaults differently on the two sides.** This is the
most actionable finding here. `autoresume_config._clean_host` does
`bool(raw.get("enabled", True))` — **default true**. `ConfigStore.decode` does
`h["enabled"] as? Bool ?? false` — **default false**. A `remote_hosts` entry
without an `enabled` key (a hand-edit, or any writer other than the widget)
is therefore **synced by the daemon while the widget's Settings window shows
it switched off**. The widget's own writer always emits the key, so this only
surfaces via hand-editing — which `CLAUDE.md` explicitly says must keep
working.

**F2-2 — Swift does not validate `account.type` or `account.plan` against
their enums; Python does.** `ConfigStore.decode` copies any string through.
`autoresume_config` falls back to `max` / `max_20x` for anything
non-canonical — and, for `plan`, also sets `plan_from_file = False` so
`plan_fit` does not record the glitch as a real plan change. So a hand-edited
`"plan": "max_10x"` shows as `max_10x` in the widget while every projection is
computed against `max_20x`. Same for `"type": "enterprise"`, which would leave
the widget in an undefined third state while the daemon treats it as `max`.

**F2-3 — Python drops malformed hosts; Swift keeps them.** `_clean_host`
returns `None` (dropping the entry) for a non-dict, a blank name, a name
containing `:`, a duplicate name, or a blank `ssh`. `ConfigStore.decode` keeps
anything with a `name` and an `ssh` string. So the widget can list — and let
you toggle — hosts the daemon is silently ignoring. The `:` case is the
dangerous one: it would corrupt the `<host>::<sid>` state key.

**F2-4 — `poll_seconds` is normalised only on the Python side.** Python
coerces to `int` and replaces anything below `MIN_HOST_POLL_SECONDS` (10) with
the default 30. Swift takes the value verbatim. A hand-edited `poll_seconds: 2`
displays as 2 and runs as 30.

**F2-5 — `budget.timezone` is read by both sides and written by neither.**
`ConfigStore` has an explicit comment that the UI never edits it, and no code
path in the repo writes it; `_budget_block` and `AppConfig.timezone` both
consume it. It can only reach the file via a hand-edit or a historical build.
(It *is* present in the live config on this machine, so a past build wrote it.)
Effectively a functioning knob with no way to turn it.

**F2-6 — `version` is written but never gated on.** `ConfigStore.mutate`
stamps `version = 1` on every write, `decode` reads it into `AppConfig.version`
and nothing uses it; Python never reads it at all. The one format that *has* a
version does not use it.

**F2-7 — The two sides normalise budgets differently.** Swift rounds to cents
on both write and read (deliberately: so the displayed text round-trips to the
stored value and the Apply button does not stick enabled). Python accepts any
positive finite number. Not a conflict, but "what is stored" and "what is
enforced" have two different definitions.

### `plan_fit.json`

**F3-1 — The widget reads about a third of this file.** Written and never
read: `generated_at`, `tier_projection` (the whole block),
`throttle_projection` (the whole block — the widget uses the flattened copies
in `verdict.plans`), `totals`, `pricing_meta`, `assumptions`, `warnings`,
`longest_lockout_{5h,7d,any}_hours`, `utilization_observed.*.peak_at`,
`utilization_observed.*.avg_pct`, and `cost_peaks.*.at`. Most is defensible
(the CLI report renders it), but two cases are not:

**F3-2 — `viable` fails open in the Swift decoder.** `p["viable"] as? Bool ??
true`. A truncated, malformed or partially-written verdict renders **every
tier as viable and unflagged** — i.e. the failure mode of the plan-fit
feature is "tells you the cheapest plan is fine", which is the wrong direction
to fail in. Compounding it, `TierVerdict.isFlagged` explicitly trusts the
backend verdict whenever any throttle field is present, so the local
peak > 100% safety net is disabled in exactly the case where `viable` is
being defaulted.

**F3-3 — `warnings` is never surfaced anywhere in the UI.** `compute()`
records unreadable store files, plan-change history truncation and pricing
problems into this array, and the widget parses none of it. The daemon's own
report of "this number may be wrong" is visible only by running `plan_fit.py`
from a terminal.

**F3-4 — Sibling series use different key formats.** `cost_series.hourly` keys
are full ISO timestamps with offset; `cost_series.daily` keys are
`YYYY-MM-DD`. `GraphModel` needs a dedicated `dailyKeyDate` helper plus a
locale-pinned formatter (there is an `R2-6` comment about a locale bug this
already caused) to reconcile them.

**F3-5 — `null` and `0` are meaningfully different in the lockout blocks, and
only just barely documented.** `_empty_lockout_stats()` returns
`capped_hours: 0.0` but `capped_hours_per_month: None` — "no observed coverage
for this dimension" versus "observed, and no lockout". Swift's
`lockoutText(nil)` renders `"—"` and `lockoutText(0)` renders `"0"`, so the
distinction does survive to the UI; nothing else in the codebase states the
rule. `pricing_meta.cache_stale` has the same tri-state (`null` = no cache to
judge).

**F3-6 — `throttle_days_*_per_month` is a name that now lies.** Kept
deliberately (older widget builds read it) but its meaning changed on
2026-07-26 from "days on which a cap was touched" to "days' *worth* of lockout
time". An old widget binary reading a new `plan_fit.json` renders a
differently-defined number under the same column header, with no signal that
anything changed. Worked example of F0-1's cost.

### `usage/snapshots*.jsonl`

**F4-1 — The `raw` blob is ~95% of `snapshots.jsonl` and is read by nobody.**
Every raw row carries the entire opaque usage-endpoint response "for future
analytics". Measured on the live store: 1452 KB across 724 rows, of which
133 KB (9%) is everything except `raw` — so the unread blob is ~91% of the
file. No consumer touches it — `GraphModel`, `plan_fit` and the
compactor all read only `five_hour/seven_day.utilization`. It also re-embeds
raw claude.ai API field names inside a format `CLAUDE.md` declares frozen
*independently* of that API, which is precisely the coupling the `ClaudeAPI`
module boundary exists to prevent. (`scripts/check_api_boundary.sh` has an
explicit carve-out for `SnapshotLogger` for this reason.)

**F4-2 — Raw rows' `resets_at` is write-only and is silently dropped by
compaction.** Both windows carry it; nothing reads it; the 15m/1h bucket rows
do not have the field at all. Documented in the compactor's docstring, not
enforced anywhere.

**F4-3 — The two row shapes are distinguished only by which timestamp key they
carry**, and the two keys use different lexical forms of the same thing:
Swift's `ISO8601DateFormatter([.withInternetDateTime])` for `ts` versus
Python's `strftime("%Y-%m-%dT%H:%M:%SZ")` for `ts_start`. Both readers parse
both forms defensively, so this is cosmetic — but it means the files are not
self-describing, and a row with both keys (or neither) has no defined meaning.

**F4-4 — Two different things are both called `n`.** The row-level `n` counts
source rows folded into the bucket; the `_n` inside each window dict counts
**non-null values for that dimension**. They diverge whenever the API omits one
window's utilization. `plan_fit` weights its average by the row-level `n` while
`avg` was computed from `_n` — consistent in practice only because the two are
almost always equal.

**F4-5 — The underscore-prefixed fields are a private format that is
nonetheless part of the contract.** `_sum`, `_n` and `_last_ts` are persisted
(not transient) because a bucket can receive contributions across more than one
`compact()` run. The docstring says "consumers that only care about
min/max/avg/last can simply ignore the rest" — which is true for readers, but
any *second* writer of these files would have to reproduce the merge semantics
exactly. There is only one writer today.

### `usage/scoped_limits.json`

**F5-1 — `percent` and `severity` are write-only.** `load_scoped_limits` reads
only `model_display_name`, `model_id` and `resets_at`.

**F5-2 — The "active only" invariant is not representable in the file.** The
widget filters on `isActive` before writing, so the daemon deliberately does no
filtering. Correct, and documented in both files' comments — but if either side
changed, the daemon would start arming auto-resumes against caps that are not
in force, and nothing would detect it. (The schema rejects an `is_active` field
specifically so reintroducing one fails a test.)

**F5-3 — `updated_at` is written and never read, so there is no staleness check
on a relayed reset.** If the widget stops running (or loses its session), the
last `scoped_limits.json` stays on disk indefinitely and
`reconcile_scoped_limit_resets` keeps applying its reset time to matching
waiting sessions — including a reset time whose window has long since rolled.
The blast radius is bounded by the opt-in constraint (`enabled` defaults false,
so nothing resumes unless the user armed it), but an armed session would fire
against a stale reset. A staleness check has all the data it needs already.

---

## Things that struck me as fragile

Beyond the reader/writer disagreements:

- **`additionalProperties: false` is doing real work here.** Four of the five
  schemas enumerate every field exhaustively, which is what makes the
  round-trip tests catch a new writer field. That strictness is only
  sustainable because the round-trip tests exist — otherwise the schemas rot
  the first time someone adds a field and doesn't run them. Keep them in the
  loop.
- **Every reader defaults silently, and several default in the unsafe
  direction.** `viable ?? true`, `status ?? "active"`, host `enabled` defaulting
  opposite ways. Defensive decoding is right given F0-1, but "the file was
  garbage" and "the file was written by an older build" produce identical
  behaviour, and in two cases that behaviour is the optimistic one.
- **`ClaudeAPI`'s carve-out list is a slow leak.** `SnapshotLogger`,
  `GraphModel` and `PlanFitModel` are exempt from the API-boundary grep because
  their on-disk field names "historically mirror the API's but are frozen
  independently". The `raw` blob (F4-1) means `snapshots.jsonl` does not merely
  mirror the API's names — it stores the API's entire response verbatim. The
  freeze is real for the fields the schema names; it is not real for `raw`.
- **`plan_fit.json` is a 17 KB single-blob rewrite of which the widget reads a
  third**, hourly. Not a correctness problem, but the format has grown by
  accretion (three generations of viability metric now coexist in
  `verdict.plans`, two of them legacy aliases) and nothing has ever been
  removed, because removal is unsafe without a version field.

## Note on test runs

The full suite was run as `cd claude-autoresume && for t in test_*.py; do
python3 $t; done`:

```
test_autoresume.py        63 tests   OK
test_contracts.py         74 tests   OK   (new)
test_deploy_remote.py     48 tests   OK
test_plan_fit.py          88 tests   OK
test_platform_compat.py   31 tests   OK (4 skipped)
test_remote_sync.py       54 tests   OK
test_usage_collector.py   26 tests   OK
```

All five schemas were also validated against the live
`~/.claude-autoresume/` store on this machine (read-only, values never
copied anywhere): all six files pass.
