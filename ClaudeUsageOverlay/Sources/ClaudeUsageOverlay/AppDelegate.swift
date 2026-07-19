import Cocoa
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: NSPanel!
    private let model = UsageModel()
    private let sessionsModel = SessionsModel()
    private let chatsModel = ChatsModel()
    // One hidden, authenticated WKWebView shared by both fetchers — see
    // ClaudeWebSession's header comment for why this isn't two webviews.
    private let webSession = ClaudeWebSession()
    private var fetcher: UsageFetcher!
    private var chatsFetcher: ChatsFetcher!
    private var loginWindowController: LoginWindowController?

    private var dataTimer: Timer?
    private var uiTimer: Timer?
    private var sessionsTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Panel sizing: fixed width, height computed from which of the two
    // collapsible sections (Sessions, Recent chats) are expanded. Anchored
    // to the top-right corner of the screen — resizing only moves the
    // bottom edge, never the top-right one.
    private let panelWidth: CGFloat = 280
    private let collapsedPanelHeight: CGFloat = 214
    private let sessionsExpandedExtra: CGFloat = 290
    private let chatsExpandedExtra: CGFloat = 280
    private var panelTopY: CGFloat = 0
    private var panelRightX: CGFloat = 0

    // How often we hit claude.ai's usage endpoint. Kept conservative on
    // purpose — this is an unofficial, undocumented endpoint and there's no
    // reason to hammer it for a number that only needs to feel "roughly live".
    private let refreshInterval: TimeInterval = 120

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, no app switcher entry

        setupStatusItem()
        setupOverlayPanel()

        fetcher = UsageFetcher(session: webSession, model: model, onLoginNeeded: { [weak self] in
            self?.presentLoginWindow()
        })
        chatsFetcher = ChatsFetcher(session: webSession, model: chatsModel, onLoginNeeded: { [weak self] in
            self?.presentLoginWindow()
        })

        // Give the hidden webview a moment to finish its first navigation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.fetcher.refresh()
            self?.chatsFetcher.refresh()
        }

        dataTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetcher.refresh()
            self?.chatsFetcher.refresh()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.model.tick()
            self?.sessionsModel.tick()
            self?.chatsModel.tick()
        }

        sessionsModel.refresh()
        sessionsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.sessionsModel.refresh()
        }

        sessionsModel.$sessionsExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main) // @Published emits on willSet; hop a beat so the resize runs after the value has actually changed
            .sink { [weak self] expanded in
                self?.updatePanelSize()
                self?.statusItem.menu?.item(withTitle: "Show Sessions")?.state = expanded ? .on : .off
            }
            .store(in: &cancellables)

        chatsModel.$chatsExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                self?.updatePanelSize()
                self?.statusItem.menu?.item(withTitle: "Show Chats")?.state = expanded ? .on : .off
            }
            .store(in: &cancellables)
    }

    // MARK: - Status bar menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Claude Usage")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self

        let toggleItem = NSMenuItem(title: "Show Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)

        let sessionsToggleItem = NSMenuItem(title: "Show Sessions", action: #selector(toggleSessionsSection), keyEquivalent: "")
        sessionsToggleItem.target = self
        sessionsToggleItem.state = sessionsModel.sessionsExpanded ? .on : .off
        menu.addItem(sessionsToggleItem)

        let chatsToggleItem = NSMenuItem(title: "Show Chats", action: #selector(toggleChatsSection), keyEquivalent: "")
        chatsToggleItem.target = self
        chatsToggleItem.state = chatsModel.chatsExpanded ? .on : .off
        menu.addItem(chatsToggleItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Sign In…", action: #selector(presentLoginWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Sign Out", action: #selector(signOut), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
    }

    @objc private func refreshNow() {
        fetcher.refresh()
        chatsFetcher.refresh()
    }

    @objc private func toggleSessionsSection() {
        sessionsModel.sessionsExpanded.toggle()
    }

    @objc private func toggleChatsSection() {
        chatsModel.chatsExpanded.toggle()
    }

    @objc private func toggleOverlay() {
        guard let item = statusItem.menu?.item(withTitle: "Show Overlay") else { return }
        if overlayPanel.isVisible {
            overlayPanel.orderOut(nil)
            item.state = .off
        } else {
            overlayPanel.orderFrontRegardless()
            item.state = .on
        }
    }

    @objc private func presentLoginWindow() {
        if loginWindowController == nil {
            loginWindowController = LoginWindowController()
        }
        loginWindowController?.show()
    }

    @objc private func signOut() {
        fetcher.signOut { [weak self] in
            self?.model.isLoggedOut = true
            self?.model.sessionPercent = nil
            self?.model.weeklyPercent = nil
            self?.chatsModel.isLoggedOut = true
            self?.chatsModel.chats = []
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Overlay panel

    private func setupOverlayPanel() {
        let initialHeight = currentPanelHeight()

        let hosting = NSHostingView(rootView: OverlayView(model: model, sessions: sessionsModel, chats: chatsModel))
        // Without this, NSHostingView installs Auto Layout min/max-size
        // constraints on itself (macOS 13+ default: .standardBounds) that
        // reflect the SwiftUI content's intrinsic size — and since it's the
        // panel's contentView, those constraints drive the *window* frame
        // too. That's what was clamping the panel back to its collapsed
        // height immediately after every expand: resizePanel would grow it,
        // then the layout engine would immediately shrink it back to match
        // the (still-collapsed, at the time) SwiftUI content's fitting size.
        // We own the frame explicitly via resizePanel, so opt out entirely.
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: initialHeight)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: initialHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting

        computeAnchor(width: panelWidth)
        panel.setFrame(frameForCurrentAnchor(height: initialHeight), display: false)

        panel.orderFrontRegardless()
        self.overlayPanel = panel
    }

    /// Records the top-right corner (in screen coordinates) the panel should
    /// stay pinned to, independent of its current height.
    private func computeAnchor(width: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 14
        let visible = screen.visibleFrame
        panelRightX = visible.maxX - margin
        panelTopY = visible.maxY - margin
    }

    private func frameForCurrentAnchor(height: CGFloat) -> NSRect {
        NSRect(x: panelRightX - panelWidth, y: panelTopY - height, width: panelWidth, height: height)
    }

    /// Sessions and Recent chats are independently collapsible, so the
    /// panel's height is the collapsed base plus whichever of the two
    /// sections' extra heights currently apply.
    private func currentPanelHeight() -> CGFloat {
        var height = collapsedPanelHeight
        if sessionsModel.sessionsExpanded { height += sessionsExpandedExtra }
        if chatsModel.chatsExpanded { height += chatsExpandedExtra }
        return height
    }

    private func updatePanelSize() {
        guard let panel = overlayPanel else { return }
        // No animation: keeps this a plain, immediate resize with no
        // in-flight state that could interact oddly with the click that
        // triggered it.
        panel.setFrame(frameForCurrentAnchor(height: currentPanelHeight()), display: true, animate: false)
    }
}
