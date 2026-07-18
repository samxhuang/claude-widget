import Foundation
import WebKit

/// Fetches usage numbers by running fetch() calls inside a WKWebView that is
/// never shown on screen. This is intentional: WKWebView's default (persistent)
/// website data store is the same store the real claude.ai login uses, so once
/// you've signed in once (in the LoginWindowController), this webview carries
/// the same session cookie and can call claude.ai's own endpoints exactly like
/// the web app does — no token handling, no scraping pixels.
///
/// Endpoints used (discovered by inspecting claude.ai's own network traffic on
/// Settings -> Usage; these are NOT public/documented Anthropic APIs and could
/// change or break at any time):
///   GET https://claude.ai/api/organizations                      -> [{ uuid, ... }]
///   GET https://claude.ai/api/organizations/{uuid}/usage          -> { five_hour, seven_day, ... }
final class UsageFetcher: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let model: UsageModel
    private let onLoginNeeded: () -> Void
    private var didLoadBase = false
    private var pendingRefreshAfterLoad = false

    init(model: UsageModel, onLoginNeeded: @escaping () -> Void) {
        self.model = model
        self.onLoginNeeded = onLoginNeeded

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
        if pendingRefreshAfterLoad {
            pendingRefreshAfterLoad = false
            refresh()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Ignore; next timer tick will retry loadBase() indirectly via refresh().
    }

    /// Call periodically (e.g. every 2 minutes) from AppDelegate's timer.
    func refresh() {
        guard didLoadBase else {
            pendingRefreshAfterLoad = true
            return
        }

        let script = """
        try {
          const orgsRes = await fetch('https://claude.ai/api/organizations', { credentials: 'include' });
          if (orgsRes.status === 401 || orgsRes.status === 403) { return { loggedOut: true }; }
          if (!orgsRes.ok) { return { error: 'orgs_http_' + orgsRes.status }; }
          const orgs = await orgsRes.json();
          if (!orgs || orgs.length === 0) { return { error: 'no_orgs' }; }
          const orgId = orgs[0].uuid;
          const usageRes = await fetch('https://claude.ai/api/organizations/' + orgId + '/usage', { credentials: 'include' });
          if (usageRes.status === 401 || usageRes.status === 403) { return { loggedOut: true }; }
          if (!usageRes.ok) { return { error: 'usage_http_' + usageRes.status }; }
          const usage = await usageRes.json();
          return { ok: true, usage: usage };
        } catch (e) {
          return { error: String(e) };
        }
        """

        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.handle(result: result)
            }
        }
    }

    private func handle(result: Result<Any, Error>) {
        switch result {
        case .failure(let error):
            model.lastError = error.localizedDescription

        case .success(let value):
            guard let dict = value as? [String: Any] else {
                model.lastError = "Unexpected response shape"
                return
            }
            if let loggedOut = dict["loggedOut"] as? Bool, loggedOut {
                model.isLoggedOut = true
                onLoginNeeded()
                return
            }
            if let err = dict["error"] as? String {
                model.lastError = err
                return
            }
            if let ok = dict["ok"] as? Bool, ok, let usage = dict["usage"] as? [String: Any] {
                model.isLoggedOut = false
                model.lastError = nil
                model.apply(usage: usage)
            }
        }
    }

    /// Forces a full cookie/session reset (used by "Sign Out" in the menu).
    func signOut(completion: @escaping () -> Void) {
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
