import Cocoa
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: NSPanel!
    private let model = UsageModel()
    private let sessionsModel = SessionsModel()
    private let chatsModel = ChatsModel()
    // Item 4: cloud-only Cowork/Code sessions (fetched via ChatsFetcher,
    // see its header comment) — separate from sessionsModel, which is
    // file-backed (state.json) and refreshes on its own 5s timer, whereas
    // this refreshes on the same 120s API cadence as chatsModel/planFit/graph.
    private let cloudSessionsModel = CloudSessionsModel()
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
    // Anchored to the panel's own top-right corner — resizing only moves the
    // bottom edge, never the top-right one. Item 1 fix: this used to be a
    // screen-relative anchor computed once at launch (panelTopY/panelRightX)
    // and never updated, so a resize would silently snap the panel back to
    // its launch position instead of preserving wherever it currently was
    // (e.g. after a manual drag) — see updatePanelSize's doc comment for the
    // full diagnosis. It's now derived from the panel's live frame on every
    // resize instead of a cached value.
    private let panelWidth: CGFloat = 280
    // Item 1 audit: every constant below was calibrated against SwiftUI's
    // own ground-truth fitting size (NSHostingView.intrinsicContentSize for
    // OverlayView at panelWidth), captured via a temporary probe during
    // development rather than eyeballed — see the commit that introduced
    // this comment for the raw log output.
    //
    // Compactness redesign audit: re-measured after (a) folding the
    // Main/Graph/Plan fit tab pills onto the title row instead of their own
    // row, (b) folding the "updated Xm" caption onto the Weekly row's reset
    // line instead of its own line, and (c) removing the Plan fit section
    // (header + divider) from the Main tab entirely — it's a tab now, not a
    // collapsible section. Collapsed Main tab content (header/tab row + 2
    // usage rows + 2 dividers + 2 section headers, at 8pt VStack spacing +
    // 20pt outer padding) measured 181pt via the temporary probe
    // (NSHostingView.intrinsicContentSize({280, 181})), down from the
    // previous 255pt real-content figure now that the tab-switch row and the
    // standalone "updated" line are both gone and Plan fit's header/divider
    // no longer live on this tab. +3pt breathing room below that, same
    // rationale as before.
    private let collapsedPanelHeight: CGFloat = 184
    // Both sections are wrapped in a ScrollView, so these only need to cover
    // a handful of visible rows — the ScrollView absorbs any overflow rather
    // than the panel growing to fit every entry. Halved from their original
    // values, which left roughly 2x the space actually needed on screen.
    // Audited (item 1): with a couple of live rows each, real extra height
    // measured 80pt (sessions) / 19pt (chats) — both comfortably under
    // these, confirming the ScrollView-absorbs-overflow design is working
    // as intended rather than silently under-covering. Left unchanged.
    //
    // Item 4 fix: derived from OverlayView.SectionLayout (the single source
    // of truth also used by the `.frame(height:)` on each section's actual
    // ScrollView) rather than restated as separate literals, so this sum can
    // never silently drift out of sync with what OverlayView actually
    // renders. `siblingSpacing` accounts for the VStack(spacing: 8) gap
    // OverlayView.body inserts between the section's header row and its
    // expanded content block. Evaluates to the same 145 / 140 as before.
    private let sessionsExpandedExtra: CGFloat = SectionLayout.sessionsContentHeight + SectionLayout.siblingSpacing
    private let chatsExpandedExtra: CGFloat = SectionLayout.chatsContentHeight + SectionLayout.siblingSpacing
    // Plan fit item 3: no longer a Main-tab collapsible section — it's its
    // own tab now, with a fixed panel height (same pattern as
    // graphPanelHeight below) rather than a collapsed-base-plus-extra. Full
    // content (current-plan badge, all 4 moving-average lines, the
    // API-equivalent line, the two-row peaks grid, and all 3 tier rows)
    // measured 238pt via the temporary probe
    // (NSHostingView.intrinsicContentSize({280, 238})) against real,
    // fully-populated plan_fit.json data (all moving-average windows, both
    // cost peaks, both utilization peaks, and all three tiers present —
    // genuinely the worst case, not a synthetic one). +4pt buffer.
    private let planFitPanelHeight: CGFloat = 242
    // The Graph tab replaces the collapsible-sections layout entirely with a
    // period picker plus two stacked mini-charts, so it gets its own fixed
    // height rather than participating in the collapsed/expanded-extras math
    // above. Audited (item 1): real content measured 295pt with no coverage
    // note, ~314pt worst-case with one (the "collecting since …" line that
    // appears for periods still filling up) — the old 400 constant left
    // ~100pt of dead space at the bottom. Item 2's y-axis label gutters sit
    // inside the charts' existing frame(height:) and don't add any height.
    private let graphPanelHeight: CGFloat = 316

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
        chatsFetcher = ChatsFetcher(session: webSession, model: chatsModel, cloudSessions: cloudSessionsModel, localSessionIds: { [weak self] in
            Set(self?.sessionsModel.sessions.map { $0.id } ?? [])
        }, localSessionTitles: { [weak self] in
            Set((self?.sessionsModel.sessions ?? []).map { $0.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        }, onLoginNeeded: { [weak self] in
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
            self?.cloudSessionsModel.tick()
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

        // The Graph and Plan fit tabs each use their own fixed panel height
        // distinct from the collapsed/expanded-extras math the Main tab
        // uses, so switching tabs needs the same resize-on-change treatment
        // as the collapsible sections above. (Plan fit item 3: it's no
        // longer a collapsible Main-tab section, so there's no separate
        // planFitExpanded publisher to watch here anymore — tab selection
        // alone now drives its visibility.)
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

        menu.addItem(.separator())

        // Pairs naturally with Lock Position below: snap flush into the
        // corner, then lock it there.
        let snapToTopRightItem = NSMenuItem(title: "Snap to Top Right", action: #selector(snapToTopRight), keyEquivalent: "")
        snapToTopRightItem.target = self
        menu.addItem(snapToTopRightItem)

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

        let hosting = NSHostingView(rootView: OverlayView(model: model, sessions: sessionsModel, chats: chatsModel, cloudSessions: cloudSessionsModel, planFit: planFitModel, graph: graphModel, onExpandGraph: { [weak self] in
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

        panel.setFrame(initialPanelFrame(height: initialHeight), display: false)

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

    /// The panel's very first frame, placed at the top-right of the main
    /// screen's visible area (i.e. below the menu bar) with a comfortable
    /// margin. This is the *only* place a screen-derived position is
    /// computed — every subsequent resize (see updatePanelSize below)
    /// preserves whatever top-right corner the panel already occupies
    /// rather than re-deriving one, so a manual drag away from this default
    /// sticks.
    private func initialPanelFrame(height: CGFloat) -> NSRect {
        let margin: CGFloat = 14
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.maxX - margin - panelWidth
        let y = visible.maxY - margin - height
        return NSRect(x: x, y: y, width: panelWidth, height: height)
    }

    /// On the Main tab, Sessions and Recent chats are independently
    /// collapsible, so the panel's height is the collapsed base plus
    /// whichever of the two sections' extra heights currently apply. The
    /// Graph and Plan fit tabs (item 3: Plan fit is no longer a Main-tab
    /// collapsible section) each replace all of that with their own fixed
    /// height.
    private func currentPanelHeight() -> CGFloat {
        switch graphModel.selectedTab {
        case .graph:
            return graphPanelHeight
        case .planFit:
            return planFitPanelHeight
        case .main:
            var height = collapsedPanelHeight
            if sessionsModel.sessionsExpanded { height += sessionsExpandedExtra }
            if chatsModel.chatsExpanded { height += chatsExpandedExtra }
            return height
        }
    }

    /// Item 1 fix: resizes the panel while preserving its TOP-RIGHT corner,
    /// i.e. it grows/shrinks purely downward-and-leftward from wherever that
    /// corner currently is. NSWindow.setFrame's default behavior anchors the
    /// window's *origin* (bottom-left corner) and grows toward the top-right
    /// on a height/width change — harmless for a window anchored at its
    /// bottom-left, but exactly backwards for this panel, which the user
    /// anchors at its TOP-right (e.g. flush into the screen's top-right
    /// corner to minimize screen use): a height change would silently walk
    /// the top edge upward/downward and away from wherever they'd placed it,
    /// which is what item 1 reported as "jumps off the top-right edge" on a
    /// Main/Graph tab switch (tabs have different fixed/derived heights, so
    /// nearly every switch is a resize).
    ///
    /// Deriving the new origin from the panel's own *current* frame (rather
    /// than a screen-relative anchor computed once at launch and never
    /// updated) also fixes a second bug that compounds the first: the panel
    /// is user-draggable via isMovableByWindowBackground whenever unlocked,
    /// and a launch-time anchor has no way of tracking that drag — so even
    /// a perfectly top-right-preserving resize would have snapped back to
    /// the *original* launch position instead of wherever the user last put
    /// it. Reading `panel.frame` here means the most recent drag (or the
    /// initial placement, if never dragged) IS the anchor, full stop.
    ///
    /// Applied unconditionally — locked or unlocked — per the task: the
    /// panel should always grow/shrink from its current top edge, and
    /// "locked" only needs to additionally block drag/move, which
    /// applyPanelLockState already handles separately.
    private func updatePanelSize() {
        guard let panel = overlayPanel else { return }
        let oldFrame = panel.frame
        let newHeight = currentPanelHeight()
        let newOrigin = NSPoint(x: oldFrame.maxX - panelWidth, y: oldFrame.maxY - newHeight)
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: panelWidth, height: newHeight))
        // No animation: keeps this a plain, immediate resize with no
        // in-flight state that could interact oddly with the click that
        // triggered it.
        panel.setFrame(newFrame, display: true, animate: false)
    }

    /// Item 1: moves the panel flush to the top-right corner of whichever
    /// screen it's currently on (falling back to the main screen if, for
    /// some reason, the panel isn't associated with one yet), respecting the
    /// menu bar via visibleFrame and a small 4pt inset. A user action from
    /// the menu — pairs naturally with "Lock Position" (snap, then lock) —
    /// rather than something applied automatically on every resize, per the
    /// task: auto-re-snapping on every resize would fight a user who
    /// deliberately dragged the panel somewhere else.
    @objc private func snapToTopRight() {
        guard let panel = overlayPanel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let inset: CGFloat = 4
        let height = panel.frame.height
        let newOrigin = NSPoint(x: visible.maxX - inset - panelWidth, y: visible.maxY - inset - height)
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: panelWidth, height: height))
        panel.setFrame(newFrame, display: true, animate: false)
    }
}
