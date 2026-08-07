import Foundation
import WebKit

// R2-1's `ClaudeWebSessionError.backlogFull` — errors surfaced to `run()`
// callers before/without a usable navigation — is now the transport-neutral
// `ClaudeTransportError.backlogFull` (Transport.swift), so the client's
// mapping isn't tied to this WebKit implementation. Behavior is unchanged:
// `.backlogFull` is returned synchronously (via the caller's own completion)
// when the pre-navigation work queue is already at its cap — see
// `ClaudeWebSession.run`.

/// Owns the single hidden WKWebView that ClaudeAPIClient runs all its
/// fetch() calls inside. WKWebView's default (persistent) website
/// data store is the same store the real claude.ai login uses, so once
/// you've signed in once (in the LoginWindowController), this webview
/// carries the same session cookie and can call claude.ai's own endpoints
/// exactly like the web app does — no token handling, no scraping pixels.
///
/// Extracted out of UsageFetcher (which originally owned this webview
/// directly) so that adding a second feature — recent chats — didn't mean
/// spinning up a second hidden WKWebView/WebContent process just to reuse
/// the same cookie jar. One hidden webview, one navigation lifecycle, N
/// callers (each caller supplies its own fetch script via `run`).
final class ClaudeWebSession: NSObject, WKNavigationDelegate, ClaudeScriptRunner {
    let webView: WKWebView
    private var didLoadBase = false
    private var pendingWork: [() -> Void] = []

    /// S3: retry-with-backoff state for a failed initial (or post-reset)
    /// navigation. Before this, a failure at launch (e.g. offline) left
    /// `didLoadBase` false forever, `didFail` did nothing, and `pendingWork`
    /// grew ~3 closures per refresh cycle with nothing ever retrying
    /// `loadBase()`. Now a failure schedules a `loadBase()` retry with
    /// exponential backoff (10s, doubling, capped ~5 min), reset to the floor
    /// on the first success. `retryScheduled` guards against overlapping
    /// retries (multiple failure callbacks in flight).
    private var retryDelay: TimeInterval = 10
    private static let minRetryDelay: TimeInterval = 10
    private static let maxRetryDelay: TimeInterval = 5 * 60
    private var retryScheduled = false
    /// S3: hard cap on queued pre-navigation work. A persistent navigation
    /// failure would otherwise let this grow unboundedly.
    ///
    /// R2-1: the cap now REJECTS the newest call (fails its completion
    /// immediately) rather than silently dropping the OLDEST queued closure.
    /// The drop-oldest approach deadlocked callers that key off their own
    /// completion firing: ChatsFetcher.refreshRecentsOnly enqueues exactly one
    /// closure and sets `recentsInFlight = true`, only resetting it in that
    /// closure's completion — if the cap evicted that closure, the completion
    /// never fired, `recentsInFlight` stayed true forever, and cloud sessions
    /// stopped refreshing even after connectivity returned. Rejecting the new
    /// call instead guarantees every enqueued closure eventually runs, and
    /// every caller already handles `.failure` (logs / clears its in-flight
    /// guard on any result).
    private static let maxPendingWork = 20

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent, shared with LoginWindowController
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        loadBase()
    }

    private func loadBase() {
        guard let url = URL(string: "https://claude.ai/new") else { return }
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didLoadBase = true
        retryDelay = Self.minRetryDelay // S3: reset backoff on success
        retryScheduled = false
        let work = pendingWork
        pendingWork = []
        work.forEach { $0() }
    }

    /// S3: fires for failures AFTER a provisional response committed. Both
    /// this and `didFailProvisionalNavigation` below schedule a retry — the
    /// old comment here claiming a later refresh() would retry `loadBase()`
    /// "indirectly" was wrong: run() only re-queues closures, nothing ever
    /// called `loadBase()` again, so a launch-time failure never recovered.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scheduleLoadBaseRetry(reason: "didFail", errorDescription: error.localizedDescription)
    }

    /// S3: the callback that actually fires for connection-level failures
    /// (offline at launch, DNS, TLS) — it wasn't implemented at all before,
    /// so those failures went completely unhandled.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        scheduleLoadBaseRetry(reason: "didFailProvisionalNavigation", errorDescription: error.localizedDescription)
    }

    /// R2-2: the WebContent process crashed (memory pressure, WebKit bug). The
    /// webview is now blank and every subsequent `callAsyncJavaScript` would
    /// fail or hang with nothing reloading the base page. Treat it like a fresh
    /// navigation failure: clear `didLoadBase` so `run()` re-queues work, and
    /// schedule a backed-off `loadBase()` retry through the same machinery as
    /// the navigation-failure path (identical backoff semantics).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        didLoadBase = false
        scheduleLoadBaseRetry(reason: "webContentProcessDidTerminate", errorDescription: "WebContent process terminated")
    }

    /// S3: schedules one backed-off `loadBase()` retry. No-op once a base load
    /// has succeeded (`didLoadBase`) — a later per-navigation failure on an
    /// already-usable session isn't fatal — and no-op while a retry is already
    /// pending, so concurrent failure callbacks don't stack retries. R2-2: the
    /// content-process-termination path clears `didLoadBase` before calling in,
    /// so this still schedules a reload for that case. Takes a plain reason +
    /// error-description string (rather than an `Error`) so callers without a
    /// concrete `Error` — like the process-termination handler — can reuse it.
    private func scheduleLoadBaseRetry(reason: String, errorDescription: String) {
        guard !didLoadBase, !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        NSLog("[ClaudeWebSession] %@: %@ — retrying loadBase in %.0fs", reason, errorDescription, delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.retryScheduled = false
            guard !self.didLoadBase else { return }
            self.retryDelay = min(self.retryDelay * 2, Self.maxRetryDelay)
            self.loadBase()
        }
    }

    /// Runs an async JS snippet (an `async function` body — use `return` to
    /// produce a value) against the shared, authenticated webview. Callers
    /// invoking this before the initial navigation has finished are queued
    /// and replayed once it does, same as UsageFetcher's original behavior.
    func run(script: String, completion: @escaping (Result<Any, Error>) -> Void) {
        guard didLoadBase else {
            // R2-1: bound the backlog by rejecting the NEWEST call when full,
            // never by dropping an already-queued closure (which would strand
            // its caller's completion — see `maxPendingWork`). Fail on the main
            // queue, matching the normal completion hop below.
            guard pendingWork.count < Self.maxPendingWork else {
                DispatchQueue.main.async { completion(.failure(ClaudeTransportError.backlogFull)) }
                return
            }
            pendingWork.append { [weak self] in self?.run(script: script, completion: completion) }
            return
        }
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Manual sign-in for environments where the interactive login window
    /// can't complete the auth ceremony — e.g. an org SSO that requires a
    /// passkey/YubiKey in managed Chrome, which this ad-hoc-signed app's
    /// WKWebView (no browser entitlement, not the managed browser) cannot
    /// satisfy. The user signs in with their real browser, copies the
    /// claude.ai session cookie, and hands its value here; we install it into
    /// the shared cookie store so every `fetch()` authenticates exactly as if
    /// the login window had set it, then restart the navigation lifecycle so
    /// queued/future work runs against the freshly-authenticated jar.
    ///
    /// Accepts either a bare cookie value or a `sessionKey=…[; …]` fragment
    /// (extracts the value). `completion(false)` means the input yielded no
    /// usable value — it does NOT verify the cookie actually authenticates;
    /// the caller confirms that with a real fetch.
    func installSessionKey(_ pasted: String, completion: @escaping (Bool) -> Void) {
        guard let value = Self.extractSessionKey(from: pasted) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let props: [HTTPCookiePropertyKey: Any] = [
            .domain: "." + ClaudeWebURLs.host,
            .path: "/",
            .name: ClaudeWebURLs.sessionCookieName,
            .value: value,
            .secure: "TRUE",
            // Persist ~1y; the real cookie rotates sooner and the user re-pastes.
            .expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)
        ]
        guard let cookie = HTTPCookie(properties: props) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { completion(true); return }
                // Restart navigation so pending + future fetches see the cookie.
                self.didLoadBase = false
                self.retryDelay = Self.minRetryDelay
                self.retryScheduled = false
                self.loadBase()
                completion(true)
            }
        }
    }

    /// Pulls the session-cookie value out of pasted text. Handles a bare value
    /// or a `sessionKey=<value>[; other=…]` cookie fragment (what you get if
    /// you copy a whole Cookie header instead of just the one value).
    static func extractSessionKey(from pasted: String) -> String? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let marker = ClaudeWebURLs.sessionCookieName + "="
        if let r = trimmed.range(of: marker) {
            let value = trimmed[r.upperBound...].prefix { $0 != ";" && !$0.isWhitespace }
            return value.isEmpty ? nil : String(value)
        }
        return trimmed
    }

    /// Forces a full cookie/session reset (used by "Sign Out" in the menu).
    /// Affects every caller of this shared session, which is the desired
    /// behavior — there's one claude.ai login, not one per feature.
    func resetSession(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let claudeRecords = records.filter { $0.displayName.contains("claude.ai") || $0.displayName.contains("anthropic") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: claudeRecords) {
                DispatchQueue.main.async {
                    self.didLoadBase = false
                    // S3: a reset restarts the navigation lifecycle, so reset
                    // the retry backoff too — a subsequent failure should back
                    // off from the floor, not wherever a prior run left it.
                    self.retryDelay = Self.minRetryDelay
                    self.retryScheduled = false
                    self.loadBase()
                    completion()
                }
            }
        }
    }

    // S9's shared org-selection snippet moved to ClaudeAPIClient
    // (orgPreambleJS) when the fetch scripts were consolidated there — one
    // copy of the org-selection knowledge, next to the scripts that use it.
}
