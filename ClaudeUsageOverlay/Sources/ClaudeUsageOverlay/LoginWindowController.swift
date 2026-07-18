import Cocoa
import WebKit

/// A plain, visible window with an embedded WKWebView pointed at claude.ai's
/// login page. You sign in here exactly like a normal browser tab, once.
/// Because it shares the same (persistent, default) WKWebsiteDataStore as
/// UsageFetcher's hidden webview, the session cookie set here is immediately
/// usable by the background fetcher too.
final class LoginWindowController: NSWindowController {

    convenience init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let frame = NSRect(x: 0, y: 0, width: 480, height: 720)
        let webView = WKWebView(frame: frame, configuration: config)
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

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
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
