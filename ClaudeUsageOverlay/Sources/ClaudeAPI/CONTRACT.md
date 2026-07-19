# ClaudeAPI module contract

This module is the only code in the repo allowed to know claude.ai
internal-API details. Everything here is empirically derived — none of it
is a public/documented Anthropic API, and it can change without notice.
When it does, fix this module only, re-verify with
`ClaudeUsageOverlay.app/Contents/MacOS/ClaudeUsageOverlay --validate-api`,
and update the observations below with the date (the way the existing
entries do). The public Swift surface (Models.swift, Client.swift,
DeepLinks.swift, Validate.swift) is the contract with the rest of the app;
its semantics must survive any API fix.

Transport: a single hidden WKWebView (WebSession.swift) whose persistent
default website data store shares the claude.ai login cookie with the
visible login window. All calls are `fetch(..., { credentials: 'include' })`
from page context. 401/403 on ANY endpoint ⇒ `.loggedOut`.

## Endpoints (observed 2026-07-18/19)

### GET https://claude.ai/api/organizations
`[{ uuid, capabilities?, ... }]`. Org selection: prefer an org whose
`capabilities` array contains one of `chat`/`claude_pro`/`raven`, else
`orgs[0]` (S9; `capabilities` may be absent entirely).

### GET https://claude.ai/api/organizations/{uuid}/usage
`{ five_hour: { utilization, resets_at }, seven_day: { ... }, ... }`
- `utilization`: number (percent).
- `resets_at`: ISO8601, with or without fractional seconds.
- Maps to `UsageReport` (session=five_hour, weekly=seven_day). The whole
  raw object rides along as `rawJSON` for snapshot persistence — the
  snapshots.jsonl on-disk format (which historically mirrors these field
  names) is owned by SnapshotLogger/GraphModel/usage_collector.py, NOT by
  this module; do not "fix" those names when the API renames fields.

### GET https://claude.ai/api/organizations/{uuid}/chat_conversations?limit=30
Plain JSON array (confirmed HTTP 200 + valid JSON; wrong paths 404).
Populated-item field names only partially verified (test account had zero
web chats) — best evidence is /recents' item shape, so decoding normalizes
`uuid|id`, `name|title|summary`, `updated_at|updatedAt`. Empty array is a
real account state, not an error.

### GET https://claude.ai/api/organizations/{uuid}/recents
Aggregates the chat/code/cowork surfaces; response is a bare array or
wrapped under `data`/`items`/`recents`. Session items have
`type: "code_session" | "cowork_session"` (both kept — filtering to
code_session only hid live Cowork sessions, root-caused 2026-07-18).
Observed item keys (live dump 2026-07-19): bound_device_uuid,
chat_project_id, created_at, id, is_agent_owned, model, pending_action,
permission_mode, preview, project_uuid, scheduled_task_id, status, title,
type, unread, updated_at, worker_status.
- `id`: opaque `cse_…` token; every linking field null on echoes of local
  sessions; per-session detail endpoint 404s. `created_at` is the only
  joinable signal (cloud record created within ~1s of the local
  transcript).
- Returns newest-first, but that's undocumented — callers must sort.

#### status/worker_status vocabulary (drives CloudWorkState)
Observed live (2026-07-19, 13 items × 2 refresh cycles):
  status=active   worker_status=idle          → .idle
  status=archived worker_status=idle          → .idle
  status=archived worker_status=running       → .running  (archived ≠ dead!)
  worker_status=requires_action               → .needsInput (confirmed on a
                                                pending permission prompt)
`worker_status` takes priority over `status`. The `.contains`-based
needs-input matches (wait/input/pending/blocked/paused) are unverified
conservative guesses. Fields present but unrecognized → `.unknown`
(validator failure; app displays as idle). Both fields absent/empty →
`.idle` (stale/finished item, historical behavior).

## Deep links (DeepLinks.swift)
- `https://claude.ai/chat/{uuid}` — verified for chat conversation uuids.
- Cloud session items: NO verifiable per-session URL exists. Probed
  2026-07-19: `/code/{id}` and `/session/{id}` return the generic SPA
  shell (200) for real AND bogus ids — routing is client-side, so a 200
  proves nothing. Cloud rows open `ClaudeWebURLs.home`.
- `claude://resume?session={id}` (Desktop deep link) is deliberately NOT
  used: it always creates a duplicate imported session server-side (see
  CLAUDE.md "Click-to-open duplicate tabs").

## Rate/politeness constraints (enforced by callers, documented here)
Usage + chat_conversations poll at 120s, recents at 30s (AppDelegate
timers). 30s is the agreed floor for recents — faster risks rate-limiting/
abuse flags on the user's session cookie. The validator makes ~4 requests
once per run; keep it that way.
