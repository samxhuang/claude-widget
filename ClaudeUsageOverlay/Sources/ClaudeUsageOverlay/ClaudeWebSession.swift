import Foundation
import WebKit

/// Owns the single hidden WKWebView that both UsageFetcher and ChatsFetcher
/// run their fetch() calls inside. WKWebView's default (persistent) website
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
final class ClaudeWebSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var didLoadBase = false
    private var pendingWork: [() -> Void] = []

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
        let work = pendingWork
        pendingWork = []
        work.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Ignore; the next refresh() call from either fetcher will retry
        // loadBase() indirectly (didLoadBase is only ever set true on a
        // successful didFinish, so a call arriving before that just re-queues).
    }

    /// Runs an async JS snippet (an `async function` body — use `return` to
    /// produce a value) against the shared, authenticated webview. Callers
    /// invoking this before the initial navigation has finished are queued
    /// and replayed once it does, same as UsageFetcher's original behavior.
    func run(script: String, completion: @escaping (Result<Any, Error>) -> Void) {
        guard didLoadBase else {
            pendingWork.append { [weak self] in self?.run(script: script, completion: completion) }
            return
        }
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            DispatchQueue.main.async { completion(result) }
        }
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
                    self.loadBase()
                    completion()
                }
            }
        }
    }
}
