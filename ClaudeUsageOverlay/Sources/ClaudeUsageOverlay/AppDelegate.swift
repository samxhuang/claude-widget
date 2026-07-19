import Cocoa
import SwiftUI
import Combine

/// Item 2 (user-resizable panel height): how much taller the user has
/// dragged the panel beyond its content-computed base height. `0` means the
/// panel is exactly its computed (base) size — the normal, un-resized state.
/// An `ObservableObject` (rather than a plain struct threaded through) so
/// OverlayView's Sessions ScrollView can react live as AppDelegate updates
/// this from `windowDidResize` during an in-progress drag, without
/// AppDelegate needing any reference into the SwiftUI view tree itself.
final class PanelSizeState: ObservableObject {
    @Published var userExtraHeight: CGFloat = 0
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: NSPanel!
    private let model = UsageModel()
    private let sessionsModel = SessionsModel()
    private let chatsModel = ChatsModel()
    // Item 4: cloud-only Cowork/Code sessions (fetched via ChatsFetcher,
    // see its header comment) — separate from sessionsModel, which is
    // file-backed (state.json) and refreshes on its own 10s timer. Item 3
    // amendment: this used to ride along with chat_conversations on the
    // 120s API timer, but that read as sluggish for something meant to
    // reflect "is Claude working right now" — it now has its own 30s timer
    // (ChatsFetcher.refreshRecentsOnly(), a dedicated /recents-only JS
    // round-trip) — see cloudSessionsTimer below. 30s (not the 10s local
    // sessions get) is the architect's chosen ceiling against an
    // authenticated claude.ai internal endpoint: faster risks
    // rate-limiting/abuse flags on the user's session cookie.
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
    /// Item 3 amendment: cloud sessions' own 30s cadence — see
    /// cloudSessionsModel's doc comment above.
    private var cloudSessionsTimer: Timer?
    // See startStateFileWatcher() — push-style refresh on state.json writes.
    private var stateDirWatcher: DispatchSourceFileSystemObject?
    private var stateWatchDebounce: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// Bug fix (move+resize firing together): the panel's frame origin at
    /// the moment the current title-bar drag began — nil when no drag is in
    /// progress. Mirrors resizeHandle's `dragStartExtra` pattern: OverlayView's
    /// MoveHandleView reports a CUMULATIVE screen-space delta since its own
    /// mouseDown (see its doc comment for why that's measured in raw
    /// `NSEvent.mouseLocation` rather than a SwiftUI DragGesture), so this is
    /// what turns that cumulative delta into an absolute target origin
    /// instead of drifting from repeated small additions.
    private var moveDragStartOrigin: NSPoint?

    // Panel sizing: fixed width, height computed from which tab is showing
    // and, on the Main tab, whether Sessions (now inclusive of chat rows —
    // see item 3's merge) is expanded.
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
    // collapsible section. Collapsed Main tab content at that point (header/
    // tab row + 2 usage rows + 2 dividers + 2 section headers) measured
    // 181pt, +3pt breathing room = 184.
    //
    // Item 3 (merge) re-audit: Recent chats' own always-visible header row
    // (chevron/title/badge) and the divider separating it from Sessions are
    // both gone now — chat rows joined the unified Sessions list instead
    // (see OverlayView.CombinedSessionRow). Re-measured via a temporary
    // NSHostingView.fittingSize probe (same technique as the item-1 audit
    // above, this time using a throwaway GraphModel forced to .main and
    // sessionsModel.sessionsExpanded forced false for the duration of the
    // measurement, both restored immediately after, so the live panel and
    // persisted defaults were never actually disturbed): collapsed Main tab
    // content (header/tab row + 2 usage rows + 1 divider + 1 section header,
    // at 8pt VStack spacing + 20pt outer padding) now measures 151pt via
    // `NSHostingView.fittingSize` at width 280. +3pt breathing room, same
    // rationale as before, = 154.
    private let collapsedPanelHeight: CGFloat = 154
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
    // of truth also used by the `.frame(height:)` on the section's actual
    // ScrollView) rather than restated as a separate literal, so this sum
    // can never silently drift out of sync with what OverlayView actually
    // renders. `siblingSpacing` accounts for the VStack(spacing: 8) gap
    // OverlayView.body inserts between the section's header row and its
    // expanded content block.
    //
    // Item 3 (merge): Recent chats is no longer a second, independently
    // collapsible section — its rows joined the unified Sessions list (see
    // OverlayView.CombinedSessionRow) — so `chatsExpandedExtra` and
    // `SectionLayout.chatsContentHeight` are gone; `collapsedPanelHeight`
    // below has also been re-audited down since Recent chats' own
    // always-visible header row + divider no longer exist to account for.
    private let sessionsExpandedExtra: CGFloat = SectionLayout.sessionsContentHeight + SectionLayout.siblingSpacing
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

    private static let userExtraHeightDefaultsKey = "panelUserExtraHeight"
    /// Item 2: created eagerly (not lazily on first resize) so OverlayView
    /// always has a live object to observe from the very first frame,
    /// seeded from whatever extra height the user last dragged in (0 if
    /// never resized, or on first launch).
    ///
    /// Item 2 bug fix: no `max(0, ...)` clamp anymore — a negative extra
    /// (shrunk below default) is now valid, and this closure runs before
    /// `self` exists, so it has no access to `minimumContentHeight()` to
    /// clamp against anyway. The raw persisted value loads as-is;
    /// `currentPanelHeight()` (called moments later from
    /// setupOverlayPanel, with full instance context available) is what
    /// actually clamps it against the real floor/ceiling before the panel
    /// is ever sized.
    private let panelSizeState: PanelSizeState = {
        let state = PanelSizeState()
        let saved = UserDefaults.standard.double(forKey: AppDelegate.userExtraHeightDefaultsKey)
        state.userExtraHeight = CGFloat(saved)
        return state
    }()

    private static let panelLockedDefaultsKey = "panelPositionLocked"
    /// Persisted; defaults to unlocked so existing drag-to-move behavior is
    /// unchanged until the user opts in from the menu.
    private var panelPositionLocked: Bool = UserDefaults.standard.bool(forKey: AppDelegate.panelLockedDefaultsKey) {
        didSet {
            UserDefaults.standard.set(panelPositionLocked, forKey: Self.panelLockedDefaultsKey)
            applyPanelLockState()
        }
    }

    // How often we hit claude.ai's usage/chat_conversations endpoints. Kept
    // conservative on purpose — these are unofficial, undocumented endpoints
    // and there's no reason to hammer them for numbers that only need to
    // feel "roughly live". Item 3: split refresh cadences — this 120s lane
    // now covers only UsageFetcher/ChatsFetcher's chat_conversations/
    // PlanFitModel/GraphModel. Local sessions (state.json) refresh every
    // 10s (sessionsTimer below) and cloud sessions (/recents) refresh every
    // 30s (cloudSessionsTimer below) — both cheaper/more time-sensitive than
    // this lane, so they don't need to wait a full 2 minutes to reflect a
    // session that just started or finished.
    private let refreshInterval: TimeInterval = 120
    /// Item 3: local (state.json-backed) sessions refresh cadence — fast
    /// enough that a session's status dot/age label feels responsive
    /// without meaningfully increasing local disk I/O (state.json is small
    /// and this is a plain file read, not a network call).
    private let sessionsRefreshInterval: TimeInterval = 10
    /// Item 3 amendment: cloud sessions (/recents) refresh cadence — see
    /// cloudSessionsModel's doc comment for why this is 30s rather than the
    /// 10s local sessions get.
    private let cloudSessionsRefreshInterval: TimeInterval = 30

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
            // S5(b): only feed RECENTLY-ACTIVE local session titles into the
            // cloud-vs-local title dedupe. That dedupe exists for the
            // crash-continuation case (a just-crashed local session's
            // conversation reappearing as a cloud row), which by definition
            // involves a recently-live local row — so a stale local session
            // must not suppress a genuinely live cloud one. A session with no
            // lastActivityAt (old daemon build, can't confirm recency) is
            // excluded, erring toward showing the cloud row.
            let now = Date()
            let recentWindow: TimeInterval = 180
            return Set((self?.sessionsModel.sessions ?? [])
                .filter { entry in
                    guard let last = entry.lastActivityAt else { return false }
                    return now.timeIntervalSince(last) < recentWindow
                }
                .map { $0.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        }, onLoginNeeded: { [weak self] in
            self?.presentLoginWindow()
        })

        // Give the hidden webview a moment to finish its first navigation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.fetcher.refresh()
            self?.chatsFetcher.refresh()
            self?.chatsFetcher.refreshRecentsOnly()
        }

        // Plan fit and the graph data both read local files (no webview
        // dependency), so they can refresh immediately rather than waiting
        // on the webview navigation.
        planFitModel.refresh()
        graphModel.refresh()

        // Item 3: this 120s lane no longer touches cloud sessions — see
        // cloudSessionsTimer below for that lane's own, faster cadence.
        dataTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetcher.refresh()
            self?.chatsFetcher.refresh()
            self?.planFitModel.refresh()
            self?.graphModel.refresh()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.model.tick()
            self?.chatsModel.tick()
            self?.cloudSessionsModel.tick()
        }

        // Item 3: split out of the old shared 5s cadence into its own fast
        // lane — this is ONLY the cheap local-file work (state.json read +
        // the `now` tick that drives session age labels/status dots),
        // nothing here ever touches the network. `tick()` runs right before
        // `refresh()` each cycle so `now` and the freshly-read state agree
        // with each other on the same beat.
        sessionsModel.tick()
        sessionsModel.refresh()
        sessionsTimer = Timer.scheduledTimer(withTimeInterval: sessionsRefreshInterval, repeats: true) { [weak self] _ in
            self?.sessionsModel.tick()
            self?.sessionsModel.refresh()
        }
        startStateFileWatcher()

        // Item 3 amendment: cloud sessions' own 30s lane — a dedicated
        // /recents-only JS round-trip (ChatsFetcher.refreshRecentsOnly(),
        // which guards against overlapping in-flight fetches internally),
        // distinct from chat_conversations/usage's 120s lane above.
        cloudSessionsTimer = Timer.scheduledTimer(withTimeInterval: cloudSessionsRefreshInterval, repeats: true) { [weak self] _ in
            self?.chatsFetcher.refreshRecentsOnly()
        }

        sessionsModel.$sessionsExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main) // @Published emits on willSet; hop a beat so the resize runs after the value has actually changed
            .sink { [weak self] expanded in
                self?.updatePanelSize()
                self?.statusItem.menu?.item(withTitle: "Show Sessions")?.state = expanded ? .on : .off
            }
            .store(in: &cancellables)

        // Item 3 (merge): Recent chats no longer has its own expand/collapse
        // state to watch here — chat rows ride along with Sessions'
        // sessionsExpanded above.

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

    /// Latency fix: state.json is replaced atomically (tmp + rename) by the
    /// daemon, so instead of waiting for the next 10s poll tick, watch the
    /// state DIRECTORY for writes (a rename into a directory is a directory
    /// write; watching the file's own descriptor would go stale after the
    /// first replace) and refresh immediately. The 10s timer stays as the
    /// fallback and for age-label ticking; this just makes status changes
    /// (running -> needs input) land in the panel the moment the daemon
    /// publishes them. Debounced 200ms so a burst of writes coalesces.
    ///
    /// S10: the watched fd is the DIRECTORY's own inode, so if
    /// ~/.claude-autoresume is deleted and recreated (e.g. a fresh
    /// install.sh, or the user clearing it out) the source silently goes
    /// stale — it keeps watching the now-orphaned old inode and never fires
    /// again. `.delete`/`.rename` are added to the mask so we notice, and on
    /// those events the source is cancelled and the watcher re-established
    /// against the new inode (retried shortly if the directory doesn't exist
    /// yet). Push behavior is restored; the 10s timer covers the brief gap.
    private func startStateFileWatcher() {
        let dirPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-autoresume")
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else {
            // Directory not present yet — retry shortly so a later
            // install.sh / mkdir re-establishes push updates. The 10s poll
            // timer keeps the panel current in the meantime.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startStateFileWatcher()
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data
            // S10: the directory inode itself was removed/renamed out from
            // under us — this watcher is now dead. Tear it down and rebuild
            // against whatever inode currently occupies the path.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.stateDirWatcher?.cancel()
                self.stateDirWatcher = nil
                self.startStateFileWatcher()
                return
            }
            self.stateWatchDebounce?.cancel()
            let work = DispatchWorkItem {
                self.sessionsModel.tick()
                self.sessionsModel.refresh()
            }
            self.stateWatchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        stateDirWatcher = source
    }

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

        // Item 3 (merge): no more standalone "Show Chats" toggle — chat rows
        // are part of the unified Sessions list now, governed by "Show
        // Sessions" above.

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
        chatsFetcher.refreshRecentsOnly()
        sessionsModel.tick()
        sessionsModel.refresh()
    }

    @objc private func toggleSessionsSection() {
        sessionsModel.sessionsExpanded.toggle()
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

    /// The panel's own hide (×) button: identical to toggling "Show Overlay"
    /// off — hides without quitting, keeps the menu item's checkmark in sync
    /// so reopening from the menu-bar icon works exactly as before. The app
    /// stays running (menu-bar accessory; there is no Dock icon).
    private func hideOverlay() {
        guard overlayPanel.isVisible else { return }
        overlayPanel.orderOut(nil)
        statusItem.menu?.item(withTitle: "Show Overlay")?.state = .off
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

        let hosting = NSHostingView(rootView: OverlayView(model: model, sessions: sessionsModel, chats: chatsModel, cloudSessions: cloudSessionsModel, planFit: planFitModel, graph: graphModel, panelSize: panelSizeState, onExpandGraph: { [weak self] in
            self?.presentGraphWindow()
        }, onResizeDrag: { [weak self] extra in
            self?.setUserExtraHeight(extra)
        }, onMoveDragChanged: { [weak self] cumulativeDelta in
            self?.moveWindow(cumulativeScreenDelta: cumulativeDelta)
        }, onMoveDragEnded: { [weak self] in
            self?.moveDragStartOrigin = nil
        }, onHide: { [weak self] in
            self?.hideOverlay()
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

        // Item 2 bug fix: `.resizable` alone does nothing here — a
        // *borderless* NSWindow/NSPanel has no NSThemeFrame border to
        // hit-test against, so AppKit never starts an edge/corner drag no
        // matter what's in styleMask (this is a longstanding AppKit
        // limitation, not something ever configured wrong here). Verified by
        // the user reporting drag-to-resize simply did nothing. `.resizable`
        // is left in the mask (harmless) but the actual resizing is now
        // driven entirely by OverlayView's own resizeHandle view (a visible
        // grab strip at the panel's bottom edge) via the onResizeDrag
        // closure below -> setUserExtraHeight. minSize/maxSize below still
        // exist to bound that manual resize's screen-visible-height ceiling.
        // See applyResizeConstraints/setUserExtraHeight for the min/max
        // plumbing and currentPanelHeight()'s doc comment for how the
        // resulting extra height flows into the SwiftUI view.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: initialHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Bug fix (move+resize firing together): this was `true`, making the
        // ENTIRE panel background drag-to-move — including the resize
        // handle's own region, which raced AppKit's window-background-move
        // against OverlayView's ResizeHandleView mouse tracking on the same
        // gesture. Moving is now handled exclusively by OverlayView's own
        // title-bar drag region (MoveHandleView, mirroring the resize
        // handle's native mouse-tracking approach) via
        // onMoveDragChanged/onMoveDragEnded above, so this stays false and
        // dragging anywhere else on the panel does nothing at all — matching
        // the ask: move only from the title bar, resize only from the
        // bottom edge.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        // NSWindowDelegate: windowDidResize below is what turns a live user
        // drag into a published `userExtraHeight`. Note `isMovable`/
        // `isMovableByWindowBackground` (toggled by Lock Position, see
        // applyPanelLockState) only govern *moving* the window — they have
        // no effect on `.resizable`'s drag-to-resize, so a locked panel
        // stays resizable by design.
        panel.delegate = self
        applyResizeConstraints(to: panel)

        panel.setFrame(initialPanelFrame(height: initialHeight), display: false)

        panel.orderFrontRegardless()
        self.overlayPanel = panel
        applyPanelLockState()
    }

    /// Item 2: width is fixed (min == max == panelWidth, so a drag can only
    /// ever change height); height's floor is `minimumContentHeight()` (see
    /// its doc comment — NOT the same as the tab's default size) and its
    /// ceiling is the screen's visible height. Re-applied from
    /// updatePanelSize() whenever the floor might have changed (tab switch,
    /// section expand/collapse) — not just once at launch — since minSize
    /// is a hard AppKit constraint that would otherwise still reflect the
    /// old tab/section's requirements. (These no longer gate the actual
    /// manual-drag resize path — see setUserExtraHeight — but are kept
    /// correct in case AppKit ever exercises them itself, e.g. window
    /// zoom/fullscreen.)
    private func applyResizeConstraints(to panel: NSPanel) {
        let minHeight = minimumContentHeight()
        let screenHeight = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 2000
        panel.minSize = NSSize(width: panelWidth, height: minHeight)
        panel.maxSize = NSSize(width: panelWidth, height: max(minHeight, screenHeight))
    }

    /// Reflects `panelPositionLocked` onto the live panel. `isMovable` is
    /// kept in sync for any AppKit-native move machinery that might consult
    /// it (Mission Control, accessibility), but the actual enforcement for
    /// our own move path is the `!panelPositionLocked` guard inside
    /// `moveWindow(cumulativeScreenDelta:)` — `isMovableByWindowBackground`
    /// is no longer part of this at all (see setupOverlayPanel's comment on
    /// why it's permanently `false` now). Defaults to unlocked, so out of
    /// the box nothing changes.
    private func applyPanelLockState() {
        guard let panel = overlayPanel else { return }
        panel.isMovable = !panelPositionLocked
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

    /// On the Main tab, Sessions is collapsible, so the panel's height is
    /// the collapsed base plus its extra height when expanded. The Graph and
    /// Plan fit tabs (item 3: Plan fit is no longer a Main-tab collapsible
    /// section) each replace all of that with their own fixed height. This
    /// is the pure CONTENT-driven height — it deliberately excludes
    /// `panelSizeState.userExtraHeight` (item 2) so it can double as the
    /// resize floor in `applyResizeConstraints`; `currentPanelHeight()`
    /// below is the one that adds the user's extra back in for actually
    /// sizing/placing the panel.
    private func computedContentHeight() -> CGFloat {
        switch graphModel.selectedTab {
        case .graph:
            return graphPanelHeight
        case .planFit:
            return planFitPanelHeight
        case .main:
            var height = collapsedPanelHeight
            if sessionsModel.sessionsExpanded { height += sessionsExpandedExtra }
            return height
        }
    }

    /// Item 2 bug fix: the smallest height a manual drag can shrink the
    /// panel to — distinct from `computedContentHeight()`, which is the
    /// tab's *default* (non-dragged) size. Before this fix the resize floor
    /// WAS `computedContentHeight()`, i.e. identical to the default size, so
    /// dragging could only ever grow the panel — shrinking below where you
    /// started was impossible (reported: wanting to shrink down to ~1.5
    /// session rows). On the Main tab with Sessions expanded, this swaps in
    /// `SectionLayout.sessionsMinContentHeight` for the full
    /// `sessionsExpandedExtra`; every other case (Graph/Plan fit, or Main
    /// with Sessions collapsed) has no shrinkable content, so it's identical
    /// to `computedContentHeight()`.
    private func minimumContentHeight() -> CGFloat {
        guard graphModel.selectedTab == .main, sessionsModel.sessionsExpanded else {
            return computedContentHeight()
        }
        return collapsedPanelHeight + SectionLayout.sessionsMinContentHeight + SectionLayout.siblingSpacing
    }

    /// Item 2: `computedContentHeight()` plus however much extra height the
    /// user has dragged the panel to on the Main tab (see
    /// `PanelSizeState`/`windowDidResize`) — the Sessions ScrollView is the
    /// only thing that can absorb that extra space (OverlayView adds it to
    /// `SectionLayout.sessionsContentHeight`), so it only applies there; the
    /// Graph/Plan fit tabs always get exactly their fixed content height.
    /// `userExtraHeight` can be negative now (shrinking below the default —
    /// see minimumContentHeight()'s doc comment), so this is clamped to
    /// never go below the floor regardless of what's currently published.
    ///
    /// Bug fix (handle "floating" mid-window): this used to only guard on
    /// the Main tab, not on Sessions actually being expanded — so with
    /// Sessions collapsed, a nonzero `userExtraHeight` (e.g. persisted from
    /// an earlier drag) still inflated the window past its content, since
    /// nothing in OverlayView absorbs that extra when the Sessions
    /// ScrollView isn't even rendered. The window grew but the visible card
    /// stayed at its short collapsed height, leaving the resize handle
    /// (bottom-anchored to the window, not the card) stranded over blank
    /// space instead of flush against the card's visible bottom edge.
    /// `minimumContentHeight()` already had this exact double guard — this
    /// just brings currentPanelHeight() in line with it.
    private func currentPanelHeight() -> CGFloat {
        let base = computedContentHeight()
        guard graphModel.selectedTab == .main, sessionsModel.sessionsExpanded else { return base }
        return max(minimumContentHeight(), base + panelSizeState.userExtraHeight)
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
        // Item 2: the content-driven floor (minSize) can change with this
        // same call (e.g. Sessions just expanded, or the tab switched to
        // one with a different fixed height) — refresh it BEFORE computing
        // newFrame below, so AppKit's own min/max clamping (setFrame is
        // constrained by minSize/maxSize) can't fight the frame we're about
        // to request using a now-stale floor from the previous tab/section
        // state.
        applyResizeConstraints(to: panel)
        let oldFrame = panel.frame
        let newHeight = currentPanelHeight()
        let newOrigin = NSPoint(x: oldFrame.maxX - panelWidth, y: oldFrame.maxY - newHeight)
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: panelWidth, height: newHeight))
        // No animation: keeps this a plain, immediate resize with no
        // in-flight state that could interact oddly with the click that
        // triggered it.
        panel.setFrame(newFrame, display: true, animate: false)
    }

    /// Item 2 bug fix: the actual entry point for user-driven resizing now
    /// that native edge-drag doesn't exist for a borderless panel (see
    /// setupOverlayPanel's styleMask comment) — OverlayView's resizeHandle
    /// calls this with the *absolute* extra height its drag gesture wants
    /// (drag-start extra + cumulative delta), and this clamps it to
    /// [minimumContentHeight() - base, screen-visible-height - base],
    /// publishes it (so the Sessions ScrollView resizes live), persists it,
    /// and resizes the real NSPanel frame. Only meaningful on the Main tab —
    /// resizeHandle only renders there — but clamps against
    /// `computedContentHeight()`/`minimumContentHeight()` regardless of tab
    /// so a stray call elsewhere can't misbehave.
    ///
    /// Item 2 bug fix: `extra` can now be negative — the floor used to be
    /// `0` (i.e. never smaller than the tab's default size), which is why
    /// the panel could only ever grow from a drag, never shrink below where
    /// it started.
    private func setUserExtraHeight(_ extra: CGFloat) {
        guard sessionsModel.sessionsExpanded, let panel = overlayPanel else { return }
        let base = computedContentHeight()
        let screenHeight = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 2000
        let minExtra = minimumContentHeight() - base
        let maxExtra = max(minExtra, screenHeight - base)
        let clamped = min(max(minExtra, extra), maxExtra)
        guard abs(clamped - panelSizeState.userExtraHeight) > 0.01 else { return }
        panelSizeState.userExtraHeight = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.userExtraHeightDefaultsKey)
        updatePanelSize()
    }

    /// Bug fix (move+resize firing together, and moving from anywhere on the
    /// panel): the panel's move path now that `isMovableByWindowBackground`
    /// is permanently off (see setupOverlayPanel) — OverlayView's
    /// MoveHandleView, scoped to just the title row (not the tab pills, not
    /// the rest of the card), calls this with the cumulative screen-space
    /// delta since its own mouseDown. `panelPositionLocked` is checked here
    /// directly (not via `isMovable`) since that's the actual source of
    /// truth `toggleLockPosition` writes to. Origin is captured lazily on
    /// the first delta of a drag and cleared by `onMoveDragEnded` (wired in
    /// setupOverlayPanel) rather than here, so a drag that starts while
    /// locked and is unlocked mid-drag doesn't jump using a stale origin.
    private func moveWindow(cumulativeScreenDelta: CGSize) {
        guard !panelPositionLocked, let panel = overlayPanel else { return }
        if moveDragStartOrigin == nil {
            moveDragStartOrigin = panel.frame.origin
        }
        guard let start = moveDragStartOrigin else { return }
        let newOrigin = NSPoint(x: start.x + cumulativeScreenDelta.width, y: start.y + cumulativeScreenDelta.height)
        panel.setFrame(NSRect(origin: newOrigin, size: panel.frame.size), display: true, animate: false)
    }

    // MARK: - NSWindowDelegate (item 2: user-resizable panel height)

    /// Historically this was the only path from a user drag to
    /// `panelSizeState` (back when the panel's styleMask was expected to
    /// support native edge-drag resize). It doesn't — see setupOverlayPanel's
    /// styleMask comment — so `setUserExtraHeight` above is the real path
    /// now. This delegate method still fires for our own programmatic
    /// `setFrame` calls (`updatePanelSize`, `snapToTopRight`), but the
    /// `abs(...) > 0.5` guard makes it a no-op for those: a programmatic
    /// resize always sets `frame.height = computedContentHeight() +
    /// panelSizeState.userExtraHeight`, so recomputing `extra` from the
    /// resulting frame lands back on the same value modulo floating-point
    /// noise. Left in place as a harmless safety net rather than removed.
    ///
    /// Item 2 bug fix: no longer `max(0, ...)` — `userExtraHeight` can be
    /// negative now (shrinking below the tab's default size, see
    /// minimumContentHeight()'s doc comment), and clamping this recomputed
    /// value to 0 was fighting every shrink: after setUserExtraHeight set a
    /// negative extra and resized the frame, this would recompute `extra` as
    /// 0 (clamped), see it differed from the real negative value, and
    /// immediately snap `panelSizeState.userExtraHeight` back to 0 — the
    /// panel visibly bouncing back to default the instant you shrank it.
    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === overlayPanel else { return }
        guard graphModel.selectedTab == .main, sessionsModel.sessionsExpanded else { return }
        let base = computedContentHeight()
        let extra = panel.frame.height - base
        guard abs(extra - panelSizeState.userExtraHeight) > 0.5 else { return }
        panelSizeState.userExtraHeight = extra
        UserDefaults.standard.set(Double(extra), forKey: Self.userExtraHeightDefaultsKey)
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
