import Cocoa
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: NSPanel!
    private let model = UsageModel()
    private let sessionsModel = SessionsModel()
    private let chatsModel = ChatsModel()
    private let planFitModel = PlanFitModel()
    private let graphModel = GraphModel()
    // One hidden, authenticated WKWebView shared by both fetchers — see
    // ClaudeWebSession's header comment for why this isn't two webviews.
    private let webSession = ClaudeWebSession()
    private var fetcher: UsageFetcher!
    private var chatsFetcher: ChatsFetcher!
    private var loginWindowController: LoginWindowController?
    private var graphWindowController: GraphWindowController?

    private var dataTimer: Timer?
    private var uiTimer: Timer?
    private var sessionsTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Panel sizing: fixed width, height computed from which of the three
    // collapsible sections (Sessions, Recent chats, Plan fit) are expanded.
    // Anchored to the top-right corner of the screen — resizing only moves
    // the bottom edge, never the top-right one.
    private let panelWidth: CGFloat = 280
    // Item 1 audit: every constant below was calibrated against SwiftUI's
    // own ground-truth fitting size (NSHostingView.intrinsicContentSize for
    // OverlayView at panelWidth), captured via a temporary probe during
    // development rather than eyeballed — see the commit that introduced
    // this comment for the raw log output. The collapsed Main tab's real
    // content height is 255pt (header row + the tab switch row added later
    // + 2 usage rows + last-updated line + 3 dividers + 3 section headers,
    // at 8pt VStack spacing + 20pt outer padding); the previous constant of
    // 217 predated the tab switch row and was never bumped for it, which is
    // exactly why the collapsed "Plan fit" header was clipped at the
    // panel's bottom edge. +3pt breathing room below that, same rationale
    // as before (pairs with planFitSection's .padding(.bottom, 3)).
    private let collapsedPanelHeight: CGFloat = 258
    // Both sections are wrapped in a ScrollView, so these only need to cover
    // a handful of visible rows — the ScrollView absorbs any overflow rather
    // than the panel growing to fit every entry. Halved from their original
    // values, which left roughly 2x the space actually needed on screen.
    // Audited (item 1): with a couple of live rows each, real extra height
    // measured 80pt (sessions) / 19pt (chats) — both comfortably under
    // these, confirming the ScrollView-absorbs-overflow design is working
    // as intended rather than silently under-covering. Left unchanged.
    private let sessionsExpandedExtra: CGFloat = 145
    private let chatsExpandedExtra: CGFloat = 140
    // Plan fit isn't wrapped in a ScrollView (unlike Sessions/Chats) since
    // its content is a fixed handful of lines, so this needs to cover the
    // full expanded height: up to 4 moving-average lines, the API-equivalent
    // line, the two-row peaks grid (item 6), and up to 3 tier rows (item 4's
    // Grid). Audited (item 1) against real (worst-case, all-fields-present)
    // data: expanded content measured 156pt beyond the collapsed base, down
    // from the old 260pt now that items 4/5/6 replaced the maturity +
    // recommendation prose (removed entirely) and the loose tier HStacks
    // with a tighter column-aligned Grid. +4pt buffer.
    private let planFitExpandedExtra: CGFloat = 160
    // The Graph tab replaces the collapsible-sections layout entirely with a
    // period picker plus two stacked mini-charts, so it gets its own fixed
    // height rather than participating in the collapsed/expanded-extras math
    // above. Audited (item 1): real content measured 295pt with no coverage
    // note, ~314pt worst-case with one (the "collecting since …" line that
    // appears for periods still filling up) — the old 400 constant left
    // ~100pt of dead space at the bottom. Item 2's y-axis label gutters sit
    // inside the charts' existing frame(height:) and don't add any height.
    private let graphPanelHeight: CGFloat = 316
    private var panelTopY: CGFloat = 0
    private var panelRightX: CGFloat = 0

    private static let panelLockedDefaultsKey = "panelPositionLocked"
    /// Persisted; defaults to unlocked so existing drag-to-move behavior is
    /// unchanged until the user opts in from the menu.
    private var panelPositionLocked: Bool = UserDefaults.standard.bool(forKey: AppDelegate.panelLockedDefaultsKey) {
        didSet {
            UserDefaults.standard.set(panelPositionLocked, forKey: Self.panelLockedDefaultsKey)
            applyPanelLockState()
        }
    }

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

        // Plan fit and the graph data both read local files (no webview
        // dependency), so they can refresh immediately rather than waiting
        // on the webview navigation.
        planFitModel.refresh()
        graphModel.refresh()

        dataTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetcher.refresh()
            self?.chatsFetcher.refresh()
            self?.planFitModel.refresh()
            self?.graphModel.refresh()
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

        planFitModel.$planFitExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                self?.updatePanelSize()
                self?.statusItem.menu?.item(withTitle: "Show Plan Fit")?.state = expanded ? .on : .off
            }
            .store(in: &cancellables)

        // The Graph tab uses a fixed panel height distinct from the
        // collapsed/expanded-extras math the Main tab uses, so switching
        // tabs needs the same resize-on-change treatment as the collapsible
        // sections above.
        graphModel.$selectedTab
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePanelSize()
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

        let planFitToggleItem = NSMenuItem(title: "Show Plan Fit", action: #selector(togglePlanFitSection), keyEquivalent: "")
        planFitToggleItem.target = self
        planFitToggleItem.state = planFitModel.planFitExpanded ? .on : .off
        menu.addItem(planFitToggleItem)

        menu.addItem(.separator())

        let lockPositionItem = NSMenuItem(title: "Lock Position", action: #selector(toggleLockPosition), keyEquivalent: "")
        lockPositionItem.target = self
        lockPositionItem.state = panelPositionLocked ? .on : .off
        menu.addItem(lockPositionItem)

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

    @objc private func togglePlanFitSection() {
        planFitModel.planFitExpanded.toggle()
    }

    @objc private func toggleLockPosition() {
        panelPositionLocked.toggle()
        statusItem.menu?.item(withTitle: "Lock Position")?.state = panelPositionLocked ? .on : .off
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

    /// Item 3: opens (or re-shows) the larger, resizable graph window from
    /// the Graph tab's expand button. One shared instance, same pattern as
    /// presentLoginWindow/LoginWindowController above.
    private func presentGraphWindow() {
        if graphWindowController == nil {
            graphWindowController = GraphWindowController(graphModel: graphModel)
        }
        graphWindowController?.show()
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

        let hosting = NSHostingView(rootView: OverlayView(model: model, sessions: sessionsModel, chats: chatsModel, planFit: planFitModel, graph: graphModel, onExpandGraph: { [weak self] in
            self?.presentGraphWindow()
        }))
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
        applyPanelLockState()
    }

    /// Reflects `panelPositionLocked` onto the live panel. Both `isMovable`
    /// (blocks programmatic/title-bar-style moves) and
    /// `isMovableByWindowBackground` (blocks the click-drag-anywhere
    /// behavior this borderless panel relies on day to day) are set
    /// together since either alone wouldn't fully prevent an accidental
    /// drag. Defaults to unlocked, so out of the box nothing changes.
    private func applyPanelLockState() {
        guard let panel = overlayPanel else { return }
        panel.isMovable = !panelPositionLocked
        panel.isMovableByWindowBackground = !panelPositionLocked
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

    /// On the Main tab, Sessions, Recent chats, and Plan fit are
    /// independently collapsible, so the panel's height is the collapsed
    /// base plus whichever of the three sections' extra heights currently
    /// apply. The Graph tab replaces all of that with its own fixed height.
    private func currentPanelHeight() -> CGFloat {
        if graphModel.selectedTab == .graph {
            return graphPanelHeight
        }
        var height = collapsedPanelHeight
        if sessionsModel.sessionsExpanded { height += sessionsExpandedExtra }
        if chatsModel.chatsExpanded { height += chatsExpandedExtra }
        if planFitModel.planFitExpanded { height += planFitExpandedExtra }
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
