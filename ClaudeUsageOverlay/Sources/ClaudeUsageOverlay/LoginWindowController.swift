import Cocoa
import WebKit
import ClaudeAPI

/// A plain, visible window with an embedded WKWebView pointed at claude.ai's
/// login page. You sign in here exactly like a normal browser tab, once.
/// Because it shares the same (persistent, default) WKWebsiteDataStore as
/// UsageFetcher's hidden webview, the session cookie set here is immediately
/// usable by the background fetcher too.
///
/// SSO note: enterprise "Sign in with Google / Microsoft / Okta" flows — and
/// even a plain personal Google sign-in — break a *bare* WKWebView in two ways:
///   (a) the identity-provider step is handed to a `window.open()` popup, which
///       a WKWebView with no `WKUIDelegate` silently swallows (new windows are
///       dropped), so the SSO button appears to do nothing; and
///   (b) Google/Microsoft refuse the page with "this browser or app may not be
///       secure" because the default WKWebView User-Agent lacks a real browser
///       token — it ends at "AppleWebKit/605.1.15 (KHTML, like Gecko)" with no
///       "Version/x Safari/605.1.15" suffix, and those IdPs treat that absence
///       as an embedded webview to block (anti-phishing `disallowed_useragent`).
/// This controller fixes both: it appends a Safari UA token so the IdP accepts
/// the page, and implements `WKUIDelegate` so the SSO popup opens as a real
/// child window *inside the app*, sharing the same cookie store — so whatever
/// session that popup establishes is exactly the one the widget ends up using.
final class LoginWindowController: NSWindowController, WKUIDelegate {

    /// Popup windows spawned by an SSO flow (`window.open`). Retained so each
    /// stays alive until the IdP page closes itself (`webViewDidClose`).
    private var popupWindows: [NSWindow] = []

    convenience init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // (b) Present as a real Safari to SSO identity providers. This value is
        // *appended* to the system WebKit UA, so only the browser token is
        // synthesized; the rest stays honest. Without it Google/Microsoft block
        // the embedded webview outright.
        config.applicationNameForUserAgent = "Version/18.3 Safari/605.1.15"

        let frame = NSRect(x: 0, y: 0, width: 480, height: 720)
        let webView = WKWebView(frame: frame, configuration: config)
        webView.load(URLRequest(url: ClaudeWebURLs.login))

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.contentView = webView
        window.center()

        self.init(window: window)
        // (a) Route `window.open()` / JS dialogs through this controller.
        webView.uiDelegate = self
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - WKUIDelegate (SSO popup support)

    /// (a) An SSO page called `window.open(...)` (e.g. to show the Google /
    /// Microsoft / Okta login). Open it as a real child window using the SAME
    /// `configuration` WebKit handed us — that keeps the popup in the same
    /// process pool and cookie store, so whatever session it establishes is the
    /// one our shared data store carries back to the hidden fetcher.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let rect = NSRect(x: 0, y: 0, width: 520, height: 660)
        let popup = WKWebView(frame: rect, configuration: configuration)
        popup.uiDelegate = self // nested popups (rare, but some IdPs chain them)

        let popupWindow = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWindow.title = "Sign in"
        popupWindow.contentView = popup
        popupWindow.center()
        popupWindow.makeKeyAndOrderFront(nil)
        popupWindows.append(popupWindow)
        return popup
    }

    /// The IdP page finished and called `window.close()`. Tear its window down.
    func webViewDidClose(_ webView: WKWebView) {
        guard let idx = popupWindows.firstIndex(where: {
            ($0.contentView as? WKWebView) === webView
        }) else { return }
        let closed = popupWindows.remove(at: idx)
        closed.orderOut(nil)
    }

    // MARK: - WKUIDelegate (JS dialogs)
    // A bare WKWebView shows none of these by default, so an IdP script that
    // uses alert/confirm/prompt would otherwise hang the flow silently.

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: webView.window ?? window ?? NSApp.keyWindow ?? NSWindow()) { _ in
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: webView.window ?? window ?? NSApp.keyWindow ?? NSWindow()) { resp in
            completionHandler(resp == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.beginSheetModal(for: webView.window ?? window ?? NSApp.keyWindow ?? NSWindow()) { resp in
            completionHandler(resp == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }
}
