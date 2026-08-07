import Foundation

/// The transport seam under `ClaudeAPIClient` (docs/swift-windows-audit.md
/// §1.10).
///
/// Every claude.ai call this module makes is an *async JavaScript function
/// body* evaluated inside an already-authenticated claude.ai page — not an
/// HTTP request. So the contract a transport has to satisfy is "run this
/// script where the session cookie lives, and hand back whatever it
/// returned", plus the two cookie-lifecycle operations the app exposes
/// (manual session-key sign-in, sign-out).
///
/// On macOS the implementation is `ClaudeWebSession` (a hidden WKWebView).
/// The protocol exists so that (a) `ClaudeAPIClient` is unit-testable
/// without a live webview — a fake runner returning canned JSON drives every
/// decode and error path — and (b) a non-WebKit host can supply its own
/// implementation. Nothing else about that possibility is implemented here.
///
/// Threading: implementations must invoke completions on the main queue,
/// which is what `ClaudeAPIClient` documents to its own callers.
public protocol ClaudeScriptRunner: AnyObject {
    /// Evaluates `script` (an `async function` body — it `return`s its
    /// result) against an authenticated claude.ai page. Success carries the
    /// returned value already decoded into Foundation types
    /// (`[String: Any]`, `[Any]`, `String`, numbers). Failure carries a
    /// transport-level error; use `ClaudeTransportError` for conditions this
    /// module maps specially.
    func run(script: String, completion: @escaping (Result<Any, Error>) -> Void)

    /// Installs a claude.ai session cookie captured from a real browser (the
    /// SSO escape hatch). `false` means the pasted text yielded no usable
    /// value; `true` means only that the cookie was stored, never that it
    /// authenticates.
    func installSessionKey(_ pasted: String, completion: @escaping (Bool) -> Void)

    /// Drops all claude.ai cookies/site data and restarts the session's
    /// lifecycle ("Sign Out").
    func resetSession(completion: @escaping () -> Void)
}

/// Transport-level conditions `ClaudeAPIClient` maps to a specific
/// `ClaudeAPIError` rather than to the generic `.transport(_)` bucket.
///
/// This is deliberately transport-NEUTRAL: the client used to type-match
/// `ClaudeWebSessionError.backlogFull`, a WebKit-session-owned error, which
/// meant only that one implementation could ever produce the mapping. Any
/// runner can now signal the same condition.
public enum ClaudeTransportError: Error, LocalizedError, Equatable {
    /// The transport is not ready to run scripts yet (no authenticated page
    /// loaded) and its pre-navigation work queue is at its cap, so this call
    /// is rejected outright instead of being queued. Queued work is never
    /// evicted — see `ClaudeWebSession.maxPendingWork` (R2-1).
    case backlogFull

    public var errorDescription: String? {
        switch self {
        case .backlogFull:
            return "claude.ai not reachable yet; request backlog full"
        }
    }
}
