import Foundation

/// The typed contract between this module and the rest of the app. These
/// types (plus ClaudeAPIClient and ClaudeWebURLs) are the ONLY things the
/// app may import from ClaudeAPI. If claude.ai's internal API changes, the
/// fix re-establishes these types' semantics without the app noticing —
/// see CONTRACT.md for the endpoint shapes they're currently decoded from.

/// Errors surfaced by every ClaudeAPIClient call.
///
/// `.loggedOut` is the single re-auth signal: any 401/403 anywhere in a
/// call maps here, and callers respond by showing the login window — never
/// by treating it as a shape/transport failure.
public enum ClaudeAPIError: Error, LocalizedError {
    case loggedOut
    /// Transport not ready and its pre-navigation queue is full (see
    /// WebSession's backlog cap — R2-1: newest call is rejected, queued
    /// closures are never evicted).
    case backlogFull
    /// WKWebView/JS-bridge failure (offline, webview crash, JS exception).
    case transport(String)
    /// An endpoint answered with a non-OK, non-auth HTTP status.
    case http(endpoint: String, status: Int)
    /// The response decoded, but not into a shape this module recognizes.
    /// `detail` is a terse module-generated code — it NEVER contains
    /// response bodies or account data (release-hygiene rule).
    case unexpectedShape(endpoint: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .loggedOut: return "logged out"
        case .backlogFull: return "claude.ai not reachable yet; request backlog full"
        case .transport(let detail): return detail
        case .http(let endpoint, let status): return "\(endpoint)_http_\(status)"
        case .unexpectedShape(_, let detail): return detail
        }
    }
}

/// One usage window (session/weekly) from the usage endpoint.
public struct UsageWindow {
    /// Normalized utilization percent (0–100+), nil if absent.
    public let percent: Int?
    public let resetsAt: Date?
    /// Raw values as the API returned them, exposed ONLY so SnapshotLogger
    /// can keep snapshots.jsonl byte-compatible with its historical format.
    /// No other consumer may touch these.
    public let utilizationRaw: NSNumber?
    public let resetsAtRaw: String?
}

/// One per-model (model-scoped) usage cap from the usage endpoint's
/// `limits[]` array — e.g. the weekly Fable cap. Distinct from the
/// account-wide session/weekly windows: each of these gates a SINGLE model,
/// and its `resetsAt` is the ONLY place the app can learn when a
/// model-limited session becomes usable again. A CLI transcript that hit a
/// per-model cap records a plain 429 with NO reset time of its own, so the
/// daemon relies on this being relayed to it (see the widget's
/// ScopedLimitLogger → the daemon's scoped_limits.json).
public struct ScopedLimit {
    /// Human-readable model name as the API labels it ("Fable", "Opus", …).
    /// The scope's model `id` has been observed null, so this is the
    /// join key the daemon matches transcript models against.
    public let modelDisplayName: String
    /// Model id when the API provides one (often null today) — the preferred
    /// join key when present.
    public let modelID: String?
    public let resetsAt: Date?
    public let percent: Int?
    /// API severity string ("normal"/"critical"/…). Diagnostics only.
    public let severity: String?
    /// True when the API flags this cap as currently in effect. Only active
    /// caps are worth relaying (an inactive one has nothing to wait on).
    public let isActive: Bool
    /// Raw reset string as the API returned it, for the widget's own on-disk
    /// relay format — same rationale as UsageWindow.resetsAtRaw.
    public let resetsAtRaw: String?
}

public struct UsageReport {
    public let session: UsageWindow   // API's 5-hour window
    public let weekly: UsageWindow    // API's 7-day window
    /// Active per-model caps parsed from the usage `limits[]` array (empty
    /// when none apply). See ScopedLimit.
    public let scopedLimits: [ScopedLimit]
    /// The full raw usage response, opaque. Exists ONLY for SnapshotLogger's
    /// `"raw"` field (historical snapshot format keeps the whole object for
    /// future analytics). Nothing may parse this outside the ClaudeAPI
    /// module — any field the app needs must be promoted to a typed
    /// property instead.
    public let rawJSON: [String: Any]
}

/// One recent claude.ai web conversation.
public struct ChatConversation {
    public let id: String
    /// May be empty (conversations can exist without a title); the app
    /// owns the "Untitled" display fallback.
    public let title: String
    public let updatedAt: Date?
}

/// Module-owned interpretation of a cloud session's activity. The app maps
/// this onto its own display enum; the raw API vocabulary never leaves the
/// module.
public enum CloudWorkState {
    case running
    case needsInput
    case idle
    /// The API reported a vocabulary this module doesn't recognize (likely
    /// an API change). Callers must treat this as "not demanding
    /// attention" — never guess `running`/`needsInput` — and the validator
    /// flags it.
    case unknown
}

/// One cloud-side Code/Cowork session from the recents endpoint.
public struct CloudSessionRecord {
    /// Opaque token (`cse_…` today). Never assume a URL can be derived
    /// from it — see the probe findings in CONTRACT.md.
    public let id: String
    public let title: String
    public let updatedAt: Date?
    /// The dedupe join key against local transcripts (cloud record is
    /// created within ~1s of the local file) — keep populated.
    public let createdAt: Date?
    /// API `status == "archived"`. NOTE: verified 2026-07-19 that this can
    /// coexist with a running worker (Desktop auto-archive), so archived
    /// alone does not mean dead — callers combine it with `workState`.
    public let isArchived: Bool
    public let workState: CloudWorkState
    /// Raw API strings, for diagnostics logging only (the observed-combos
    /// NSLog that lets us tune the mapping against real data). Never used
    /// for display or logic outside this module.
    public let statusRaw: String?
    public let workerStatusRaw: String?
}
