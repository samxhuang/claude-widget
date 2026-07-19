#!/bin/bash
# Boundary check for the ClaudeAPI module (see docs/claude-api-module-plan.md
# §4): claude.ai internal-API knowledge must not leak into app code outside
# ClaudeUsageOverlay/Sources/ClaudeAPI/.
#
# Rules:
# - Forbidden anywhere outside the module (in CODE; comment lines are
#   allowed so docs/history can still reference the API):
#     claude.ai   /api/organizations   chat_conversations   worker_status
#     api/organizations-style paths, and the recents endpoint path
# - five_hour / seven_day are additionally allowed in SnapshotLogger.swift,
#   GraphModel.swift, and PlanFitModel.swift ONLY: the first two own the
#   widget's snapshots.jsonl on-disk format, and PlanFitModel reads the
#   Python daemon's plan-fit cache — both are widget-owned formats whose
#   field names historically mirror the API's but are frozen independently
#   of it.
#
# Exit 0 = clean, 1 = leak found (offending lines printed).

set -u
cd "$(dirname "$0")/.." || exit 1

APP_SRC="ClaudeUsageOverlay/Sources/ClaudeUsageOverlay"
FAIL=0

# Strip comment-only lines (// or ///) before matching, so doc comments may
# mention the API. Inline trailing comments are NOT stripped — a URL in real
# code can't hide behind one.
scan() {
    local pattern="$1"; shift
    local out
    out=$(grep -rn -E "$pattern" "$APP_SRC" --include='*.swift' "$@" | grep -vE '^[^:]+:[0-9]+:\s*//')
    if [ -n "$out" ]; then
        echo "LEAK: pattern '$pattern' in app code (belongs in Sources/ClaudeAPI/):"
        echo "$out"
        echo
        FAIL=1
    fi
}

scan 'claude\.ai'
scan '/api/organizations'
scan 'chat_conversations'
scan 'worker_status'
scan '"/recents"|/recents\?|organizations/.*/recents'

# On-disk snapshot format names: allowed only in their two format-owner files.
scan 'five_hour|seven_day' --exclude=SnapshotLogger.swift --exclude=GraphModel.swift --exclude=PlanFitModel.swift

if [ "$FAIL" -eq 0 ]; then
    echo "API boundary clean: no internal-API knowledge outside Sources/ClaudeAPI/."
fi
exit $FAIL
