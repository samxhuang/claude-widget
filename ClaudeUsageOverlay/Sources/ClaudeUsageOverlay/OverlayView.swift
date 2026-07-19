import SwiftUI
import AppKit

/// Single source of truth for the fixed height the Sessions section's
/// expanded ScrollView content occupies. AppDelegate's currentPanelHeight()
/// composes this (plus `siblingSpacing`, matching this file's outer
/// `VStack(spacing: 8)` that every top-level row below is spliced into) into
/// its `sessionsExpandedExtra` constant, so the panel's reserved height and
/// the SwiftUI frame that actually consumes it can never drift apart.
///
/// Item 4 fix: this ScrollView used to be sized with `.frame(maxHeight:)`,
/// which is flexible — SwiftUI treats a ScrollView like that as wanting to
/// grow to fill whatever vertical slack is left over in the panel's (fixed,
/// AppDelegate-driven) height once the fixed-size rows are accounted for.
/// Back when Recent chats was a second, independently-expandable section,
/// that made Sessions' rendered height drift depending on Chats' state.
/// Giving the ScrollView a true fixed `.frame(height:)` removed it from any
/// shared slack pool entirely — its rendered height depends only on this
/// constant (plus item 2's user-resize extra, added at the call site).
///
/// Item 3 (merge): Recent chats is no longer its own collapsible section —
/// chat conversations now join the unified Sessions list as their own row
/// kind (see OverlayView.CombinedSessionRow), so `chatsContentHeight` and
/// its own header row/divider are gone. `sessionsContentHeight` is bumped
/// up from the old 137 to comfortably fit a mix of session and chat rows
/// now that this is the only list.
enum SectionLayout {
    /// VStack sibling spacing shared by every top-level row spliced into
    /// OverlayView.body's outer `VStack(spacing: 8)`.
    static let siblingSpacing: CGFloat = 8
    static let sessionsContentHeight: CGFloat = 220
    /// Item 2 bug fix: the smallest the user can manually shrink the
    /// Sessions ScrollView to via resizeHandle — enough for one full row
    /// plus roughly half of the next (a session row is ~31pt: 4pt v-padding
    /// + a ~12pt title line + 1pt spacing + a ~10pt subtitle line + 4pt
    /// v-padding, with a 6pt VStack gap between rows), signaling there's
    /// more to scroll/resize into rather than hard-cropping mid-row.
    /// Distinct from `sessionsContentHeight` above, which stays the
    /// *default* (non-dragged) size — before this fix the resize floor was
    /// wrongly pinned to that same default, so dragging could only grow the
    /// panel, never shrink it below its starting size.
    static let sessionsMinContentHeight: CGFloat = 54
}

struct OverlayView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var sessions: SessionsModel
    @ObservedObject var chats: ChatsModel
    /// Item 4: cloud-only Cowork/Code sessions, shown appended to the
    /// Sessions section — see CloudSessionsModel's header comment.
    @ObservedObject var cloudSessions: CloudSessionsModel
    @ObservedObject var planFit: PlanFitModel
    @ObservedObject var graph: GraphModel
    /// WS-2 finding 1: the live config.json store. The API-vs-Max mode switch
    /// (dollar budget bars vs. Max session/weekly percentages) is gated on
    /// THIS — the user's just-saved account type — not on `planFit.data`,
    /// which is regenerated at most hourly and so lagged the UI by up to an
    /// hour after a Settings change. The dollar NUMBERS still come from
    /// `planFit.data`; config only decides which mode to render and, in the
    /// transitional window (config flipped to API but plan_fit.json not yet
    /// rewritten), drives a "calculating…" scaffold instead of falling back to
    /// the Max bars. A missing/`"max"` config (no config.json) reads as Max ⇒
    /// exactly the pre-WS-2 UI.
    @ObservedObject var configStore: ConfigStore
    /// Item 2 (resizable panel): the panel's user-dragged "extra" height
    /// beyond its content-computed base — see AppDelegate.PanelSizeState's
    /// doc comment.
    ///
    /// Item 2 stutter fix: deliberately NOT `@ObservedObject` here. That was
    /// the actual cause of the reported drag stutter — with it observed at
    /// this (OverlayView) level, EVERY published change (i.e. every single
    /// mouseDragged tick, dozens/sec) invalidated this view's entire `body`,
    /// which re-runs `combinedSessionRows`' full sort on every pixel of
    /// drag. Held as a plain reference instead; only
    /// `ResizableSessionsHeight` below (a dedicated leaf view) subscribes to
    /// it, so a live drag only ever re-diffs that one small subtree.
    let panelSize: PanelSizeState
    /// Opens the larger, resizable graph window (item 3) — forwarded down to
    /// GraphView's expand button.
    var onExpandGraph: () -> Void = {}
    /// Item 2 bug fix: called with the *absolute* extra height resizeHandle's
    /// drag gesture wants (not a delta) — AppDelegate.setUserExtraHeight
    /// clamps and applies it to both `panelSize` and the real NSPanel frame.
    /// See setupOverlayPanel's styleMask comment for why this exists at all
    /// (borderless panels don't get native edge-drag resize).
    var onResizeDrag: (CGFloat) -> Void = { _ in }
    /// Bug fix (move+resize firing together): called with the CUMULATIVE
    /// screen-space delta since titleBarDragArea's own mouseDown (see
    /// MoveHandleView's doc comment) — AppDelegate.moveWindow turns that
    /// into an absolute target origin. `onMoveDragEnded` clears
    /// AppDelegate's drag-start bookkeeping.
    var onMoveDragChanged: (CGSize) -> Void = { _ in }
    var onMoveDragEnded: () -> Void = {}
    /// Hide button on the title row: hides the panel (orderOut) without
    /// quitting the app — for getting at whatever's underneath without
    /// hunting for the panel later. Reopen via the menu-bar gauge icon →
    /// "Show Overlay" (AppDelegate keeps that menu item's checkmark in sync).
    var onHide: () -> Void = {}
    /// WS-2: opens the Settings window (gear button on the title row, and the
    /// "No budget set — open Settings" prompt on an API account's main tab).
    var onOpenSettings: () -> Void = {}
    /// WS-2: resolves a remote session's config host NAME (state.json's
    /// `host`, e.g. "devbox") to its ssh target (config's `ssh`, e.g.
    /// "sam@devbox" or an ~/.ssh/config alias) so openLocalSession can build
    /// the exact `ssh -t <target> …` command. Falls back to the host name
    /// itself when unresolved (works when name == an ssh alias). Wired from
    /// AppDelegate's ConfigStore.
    var resolveHostSSH: (String) -> String? = { _ in nil }

    /// Sort-deadband state (see combinedSessionRows): an ordered list of row
    /// ids from the last computed arrangement, used as the tiebreak below.
    /// Held as a plain (non-@Published) reference type inside @State so the
    /// same instance — and thus the memory — survives across SwiftUI
    /// recreating this View struct on every re-render; mutating its
    /// property doesn't itself trigger a redraw (only the @ObservedObject
    /// models above do that), which is exactly what's wanted here: this is
    /// a derived cache, not source-of-truth state.
    @State private var sessionOrderMemory = SessionOrderMemory()
    /// Item 2 bug fix: the extra height at the moment the current resize
    /// drag began, captured on the gesture's first `onChanged` and cleared
    /// on `onEnded` — DragGesture's `translation` is cumulative from
    /// gesture-start, not a per-event delta, so this is what turns that
    /// cumulative translation into an absolute target height.
    @State private var dragStartExtra: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Item 1: the Main/Graph/Plan fit tab pills used to occupy their
            // own row under the title; folded onto the title row itself
            // (right-aligned, title left) to reclaim that row's height for
            // an always-on-top panel where vertical economy is the point.
            HStack {
                // Bug fix (drag-anywhere-moves, and racing the resize
                // handle): this used to move the whole panel via
                // `isMovableByWindowBackground` on ANY background drag. Now
                // only this title/spacer/error region is a drag-to-move
                // target — scoped by putting MoveHandleRepresentable behind
                // just these views in their own ZStack, as a sibling to
                // tabSwitch rather than wrapping it, so the tab pills' own
                // tap gestures are entirely untouched.
                // Bug fix (click-hijack): this used to be a ZStack with
                // MoveHandleRepresentable as an unconstrained peer — with no
                // `.frame()` of its own, a plain NSViewRepresentable has no
                // size opinion and simply accepts whatever's proposed to it,
                // which (via the outer VStack's later
                // `.frame(maxWidth:.infinity, maxHeight:.infinity)`) could be
                // the ENTIRE window. `.background()` instead proposes
                // exactly this HStack's own resolved size to the
                // representable, so it can never be bigger than the visible
                // title text/spacer region it's meant to scope to.
                HStack {
                    // "Claude Usage" title removed (user request): the tab
                    // pills were truncating ("Gra…"/"Plan…") in the space the
                    // title ate, and what the panel is is self-evident. The
                    // HStack + Spacer stay: this region is still the
                    // MoveHandle drag-to-move target (see .background below),
                    // and the sign-in/error status still renders here.
                    Spacer()
                    if model.isLoggedOut {
                        Text("Sign in needed")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.orange)
                    } else if let err = model.lastError {
                        Text(err)
                            .font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                // minHeight: with the title text gone this HStack's only
                // unconditional child is the Spacer, which has ZERO height on
                // its own — and the MoveHandle behind it inherits that zero-
                // height frame, making drag-to-move unhittable (reported live
                // after the title's removal). Pin it to the pill row's height
                // so the empty left region stays a real drag target.
                .frame(minHeight: 19)
                .background(MoveHandleRepresentable(onDragChanged: onMoveDragChanged, onDragEnded: onMoveDragEnded))
                tabSwitch
                // WS-2: Settings gear — also a sibling of tabSwitch (outside
                // the MoveHandle scope) so its click opens Settings rather
                // than starting a window drag. Pairs with the status-item
                // menu's "Settings…" entry.
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Settings — account type, budget, and remote hosts")
                // Hide (not quit): sits OUTSIDE the MoveHandle background's
                // scope (a sibling of tabSwitch, same as the pills) so its
                // click can't start a window drag.
                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide the widget — reopen from the menu bar gauge icon → Show Overlay")
            }

            if graph.selectedTab == .main {
                mainTabContent
            } else if graph.selectedTab == .graph {
                GraphView(model: graph, onExpand: onExpandGraph)
            } else {
                planFitTabContent
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        // The hosting view no longer auto-sizes the window to this content
        // (see AppDelegate: hosting.sizingOptions = []), so this card can be
        // shorter than the panel's frame (e.g. right after collapsing).
        // Pin it to the top so it stays flush with the anchored top edge
        // instead of SwiftUI centering it in the leftover space.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Item 2 bug fix: only the Main tab has anywhere to put extra height
        // (the Sessions ScrollView) — Graph/Plan fit have a fixed panel
        // height (AppDelegate.computedContentHeight), so the handle would
        // just do nothing there and its cursor/affordance would be a lie.
        //
        // Bug fix (handle "floating" mid-window): also gated on
        // `sessions.sessionsExpanded` now — with Sessions collapsed there's
        // no ScrollView to absorb extra height either (mirrors
        // AppDelegate.currentPanelHeight()'s matching guard), so showing the
        // handle here would offer a resize that visibly does nothing but
        // inflate blank window space below the card.
        .overlay(alignment: .bottom) {
            if graph.selectedTab == .main && sessions.sessionsExpanded {
                resizeHandle
            }
        }
    }

    // MARK: - Resize handle

    /// A visible grab strip pinned to the panel's bottom edge. Exists
    /// because a borderless NSPanel never gets AppKit's native edge-drag
    /// resize no matter what's in its styleMask — see AppDelegate.
    /// setupOverlayPanel's comment.
    ///
    /// Item 2 tracking-accuracy fix: this used to use SwiftUI's
    /// `DragGesture`, whose `translation` is measured in the dragged view's
    /// OWN coordinate frame — but that frame moves, because the handle is
    /// pinned to the panel's bottom edge, which is exactly what we're
    /// resizing IN RESPONSE to the drag being measured. Each tick's motion
    /// partially cancels against the view's own resulting repositioning, so
    /// the measured translation consistently undercounts real cursor
    /// movement (reported: "only about half of where the cursor drags to").
    /// `ResizeHandleRepresentable` below tracks via `NSEvent.mouseLocation`
    /// instead — real SCREEN coordinates, entirely decoupled from any
    /// window's own frame, so resizing the window mid-drag can't feed back
    /// into the measurement.
    private var resizeHandle: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 32, height: 4)
            ResizeHandleRepresentable(
                onDragChanged: { delta in
                    if dragStartExtra == nil {
                        dragStartExtra = panelSize.userExtraHeight
                    }
                    onResizeDrag((dragStartExtra ?? 0) + delta)
                },
                onDragEnded: {
                    dragStartExtra = nil
                }
            )
        }
        // Bug fix (click-hijack): `minHeight` alone is a FLOOR, not a
        // ceiling — it doesn't stop the flexible, opinion-less
        // ResizeHandleRepresentable from accepting whatever height gets
        // proposed to it, which via the enclosing `.overlay(alignment:
        // .bottom)` (attached to a `maxHeight: .infinity` frame) could be
        // the entire window. Since `.overlay` content sits topmost in
        // z-order — and AppKit hit-testing always hands mouseDown to the
        // frontmost subview under the cursor — a window-sized
        // ResizeHandleView silently swallowed every click before any
        // SwiftUI button/toggle underneath ever saw it. `maxHeight: 12`
        // caps it to the intended thin strip.
        .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12)
    }

    // MARK: - Resize handle (native mouse tracking)

    /// Bridges `ResizeHandleView` (below) into SwiftUI. `onDragChanged`
    /// fires on every `mouseDragged` with the cumulative screen-space delta
    /// since `mouseDown` (not a per-event delta); `onDragEnded` fires once
    /// on `mouseUp`.
    private struct ResizeHandleRepresentable: NSViewRepresentable {
        var onDragChanged: (CGFloat) -> Void
        var onDragEnded: () -> Void

        func makeNSView(context: Context) -> ResizeHandleView {
            let view = ResizeHandleView()
            view.onDragChanged = onDragChanged
            view.onDragEnded = onDragEnded
            return view
        }

        func updateNSView(_ nsView: ResizeHandleView, context: Context) {
            nsView.onDragChanged = onDragChanged
            nsView.onDragEnded = onDragEnded
        }

        /// Bug fix (click-hijack) belt-and-braces: a plain NSViewRepresentable
        /// has no size opinion of its own and accepts whatever ancestor
        /// modifiers propose, which is what let this balloon to cover the
        /// whole window (see resizeHandle's doc comment). The `maxHeight: 12`
        /// on that ancestor frame is the real fix; this gives the
        /// representable an explicit opinion too, so a future ancestor
        /// change can't silently reopen the same hit-testing hijack.
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResizeHandleView, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 280, height: min(proposal.height ?? 12, 12))
        }
    }

    /// Raw AppKit mouse tracking for the resize handle — see resizeHandle's
    /// doc comment for why SwiftUI's `DragGesture` doesn't work here.
    /// `NSEvent.mouseLocation` is screen space (AppKit: y increases
    /// upward), so dragging the mouse DOWN decreases it; `delta` is negated
    /// so a downward drag (which should grow the panel) reports positive.
    private final class ResizeHandleView: NSView {
        var onDragChanged: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        private var dragStartScreenY: CGFloat?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { NSCursor.resizeUpDown.push() }
        override func mouseExited(with event: NSEvent) { NSCursor.pop() }

        override func mouseDown(with event: NSEvent) {
            dragStartScreenY = NSEvent.mouseLocation.y
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startY = dragStartScreenY else { return }
            onDragChanged?(startY - NSEvent.mouseLocation.y)
        }

        override func mouseUp(with event: NSEvent) {
            dragStartScreenY = nil
            onDragEnded?()
        }
    }

    // MARK: - Title bar (move) handle

    /// Bridges `MoveHandleView` (below) into SwiftUI, mirroring
    /// `ResizeHandleRepresentable` above. `onDragChanged` fires on every
    /// `mouseDragged` with the cumulative screen-space delta since
    /// `mouseDown` (not a per-event delta); `onDragEnded` fires once on
    /// `mouseUp`.
    private struct MoveHandleRepresentable: NSViewRepresentable {
        var onDragChanged: (CGSize) -> Void
        var onDragEnded: () -> Void

        func makeNSView(context: Context) -> MoveHandleView {
            let view = MoveHandleView()
            view.onDragChanged = onDragChanged
            view.onDragEnded = onDragEnded
            return view
        }

        func updateNSView(_ nsView: MoveHandleView, context: Context) {
            nsView.onDragChanged = onDragChanged
            nsView.onDragEnded = onDragEnded
        }

        /// Bug fix (click-hijack) belt-and-braces: the `.background()` on
        /// the title `HStack` (see body) is the real fix — it proposes
        /// exactly that HStack's own resolved size rather than an
        /// unconstrained ZStack peer. This gives the representable an
        /// explicit size opinion too (16pt covers the 11pt title font's line
        /// height with headroom) so a future restructure can't silently
        /// reopen the same window-covering hijack this class of view is
        /// prone to.
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: MoveHandleView, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 0, height: min(proposal.height ?? 16, 16))
        }
    }

    /// Bug fix (move+resize firing together): replaces
    /// `NSPanel.isMovableByWindowBackground` (which made the ENTIRE panel a
    /// move target, including the resize handle's own region — the two
    /// raced on the same gesture) with an explicit drag region scoped to
    /// just the title row. Uses the same raw `NSEvent.mouseLocation`
    /// tracking as `ResizeHandleView` rather than a SwiftUI `DragGesture`,
    /// for the same reason: a `DragGesture`'s translation is measured in the
    /// dragged view's own coordinate frame, which moves as the window moves
    /// in response, undercounting real cursor movement. Delta here is
    /// screen-space and needs no sign flip (unlike the resize handle's
    /// negated Y) — AppKit's window-origin Y and `NSEvent.mouseLocation`'s Y
    /// both increase upward, so "cursor moved up 10pt" and "window should
    /// move up 10pt" are already the same sign.
    private final class MoveHandleView: NSView {
        var onDragChanged: ((CGSize) -> Void)?
        var onDragEnded: (() -> Void)?
        private var dragStartScreenLocation: NSPoint?

        override func mouseDown(with event: NSEvent) {
            dragStartScreenLocation = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStartScreenLocation else { return }
            let current = NSEvent.mouseLocation
            onDragChanged?(CGSize(width: current.x - start.x, height: current.y - start.y))
        }

        override func mouseUp(with event: NSEvent) {
            dragStartScreenLocation = nil
            onDragEnded?()
        }
    }

    // MARK: - Tab switch

    /// Small pill-style tab switch between the main view (usage bars +
    /// sessions + chats), the Graph view, and the Plan fit view (item 3).
    /// Styled to match the panel's existing dark, compact controls rather
    /// than a native segmented control, which would look out of place here.
    /// Lives on the title row now (item 1), so it's tightened up (smaller
    /// pill padding/spacing than the old standalone row needed) to keep
    /// three tabs plus the title fitting the panel width without truncation.
    private var tabSwitch: some View {
        HStack(spacing: 3) {
            tabButton(title: "Main", tab: .main)
            tabButton(title: "Graph", tab: .graph)
            tabButton(title: "Plan fit", tab: .planFit)
        }
        // Truncation fix ("Gra…"/"Plan…" even with free space on the row):
        // the title row's outer HStack splits its width between its flexible
        // children — the Spacer-bearing status region and this stack — so the
        // pills were being PROPOSED roughly half the row regardless of how
        // little the other side actually needed, and the tail pills truncated
        // into that artificial ceiling. fixedSize() makes the pills always
        // take exactly their ideal width; the Spacer region absorbs whatever
        // is left (and the status/error text there is lineLimit(1), so IT
        // truncates first when genuinely tight — the right precedence).
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabButton(title: String, tab: PanelTab) -> some View {
        Text(title)
            .font(.system(size: 9, weight: graph.selectedTab == tab ? .bold : .medium))
            .foregroundColor(graph.selectedTab == tab ? .white : .white.opacity(0.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(graph.selectedTab == tab ? Color.white.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                graph.selectTab(tab)
            }
    }

    // MARK: - Main tab content

    @ViewBuilder
    private var mainTabContent: some View {
        // WS-2: on an API-billed account the Max session/weekly percentages
        // are meaningless — swap in 1-2 dollar budget bars (reusing row(...)
        // so the projection dot / red-pinning / 70/90 thresholds all carry
        // over), or a "No budget set" prompt when none is configured. A
        // missing/`"max"` account block (no config.json or a Max plan) falls
        // through to exactly today's two percentage rows.
        //
        // Finding 1: gate on the LIVE config account type (republished the
        // instant Settings writes it), not on `planFit.data.isApiAccount` —
        // the latter is regenerated at most hourly, so the mode switch used
        // to lag a Settings change by up to an hour. The dollar numbers still
        // come from `planFit.data`; config only picks the mode.
        if configStore.config.isApiAccount {
            apiBudgetSection(planFit.data)
        } else {
            row(label: "Session (5h)", percent: model.sessionPercent, estimatedPercent: model.sessionEstimatedPercent, resetText: model.resetText(for: model.sessionResetsAt))
            // Item 2: the standalone "updated Xm" line is gone — folded onto the
            // Weekly row's reset caption line instead (right-aligned, italic),
            // saving the row entirely.
            row(label: "Weekly", percent: model.weeklyPercent, estimatedPercent: model.weeklyEstimatedPercent, resetText: model.resetText(for: model.weeklyResetsAt), trailingCaption: model.lastUpdatedText)
        }

        Divider().background(Color.white.opacity(0.15))

        // Item 3 (merge): Recent chats used to be its own collapsible
        // section here (its own header row + divider + ScrollView). It's
        // gone — chat conversations now join the unified list inside
        // sessionsSection as their own row kind (see CombinedSessionRow),
        // sorted into the idle/done bucket like a finished session. See
        // combinedSessionRows/chatRow for the row-level details.
        sessionsSection
    }

    // MARK: - API budget bars (WS-2)

    /// API accounts: 1-2 dollar budget bars in place of the Session/Weekly
    /// percentage rows, or a muted "No budget set" prompt that opens Settings
    /// when neither period is configured. `UsageFetcher` keeps running behind
    /// this regardless (it still feeds SnapshotLogger/the Graph tab) — only
    /// the display of its percentages is suppressed here.
    ///
    /// Finding 1: which periods to show comes from the LIVE config
    /// (`weeklyUsd`/`monthlyUsd`), so it flips the instant the user sets a
    /// budget — the dollar numbers come from `data` (plan_fit.json) once the
    /// daemon has recomputed them. Transitional window (config has a budget
    /// but plan_fit.json hasn't been regenerated with matching numbers yet):
    /// show the bar scaffold with a muted "calculating…" rather than snapping
    /// back to the Max percentage rows. `data` is nil when plan_fit.json
    /// doesn't exist yet at all — same scaffold path.
    @ViewBuilder
    private func apiBudgetSection(_ data: PlanFitData?) -> some View {
        let weeklyConfigured = configStore.config.weeklyUsd != nil
        let monthlyConfigured = configStore.config.monthlyUsd != nil
        if weeklyConfigured || monthlyConfigured {
            if weeklyConfigured {
                budgetRowOrScaffold(label: "Weekly budget", window: data?.budgetWeekly)
            }
            if monthlyConfigured {
                budgetRowOrScaffold(label: "Monthly budget", window: data?.budgetMonthly)
            }
        } else {
            Button(action: onOpenSettings) {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 10))
                    Text("No budget set — open Settings")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Set a weekly or monthly dollar budget in Settings to show budget bars here")
        }
    }

    /// Finding 1: a real budget bar once plan_fit.json carries this period's
    /// numbers, otherwise the "calculating…" scaffold — an empty bar with the
    /// period label, so the panel doesn't visibly flip modes while the daemon
    /// catches up to a just-saved budget.
    @ViewBuilder
    private func budgetRowOrScaffold(label: String, window: BudgetWindow?) -> some View {
        if let w = window, w.limitUsd != nil {
            budgetRow(label: label, window: w)
        } else {
            row(label: label, percent: nil, resetText: "calculating…")
        }
    }

    /// One dollar budget bar built on the shared row(...): pct drives the bar
    /// fill (with its 70/90 color thresholds), projected pct drives the
    /// projection dot + red-pinning, period_end drives the reset countdown,
    /// and the "$61.34 / $200" spent/limit caption rides the reset line as
    /// the trailing caption. `sessions.now` (already observed by this view,
    /// ticked off the shared UI cadence) is the clock for the countdown.
    @ViewBuilder
    private func budgetRow(label: String, window w: BudgetWindow) -> some View {
        // When the projection overshoots the limit, the red-pinned dot says
        // "over" but not by how much — append the projected dollar landing
        // and the overrun ("proj $612 (+$112)") to the spent/limit caption.
        let caption = [planFit.budgetSpentText(w), planFit.budgetOverrunText(w)]
            .compactMap { $0 }
            .joined(separator: " · ")
        row(label: label,
            percent: planFit.budgetPct(w),
            estimatedPercent: planFit.budgetProjectedPct(w),
            resetText: planFit.budgetResetText(w, now: sessions.now),
            trailingCaption: caption)
    }

    // MARK: - Interrupted sessions

    @ViewBuilder
    private var sessionsSection: some View {
        HStack {
            Image(systemName: sessions.sessionsExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
            Text("Sessions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            // Status classification item: replaces the old plain total-count
            // capsule with a compact running/needs-input/done breakdown
            // across the combined (local + cloud, deduped) list — the
            // needs-input count is the one thing here worth acting on, so
            // it's bold amber rather than blending into the muted counts
            // around it. Zero-count categories are omitted entirely rather
            // than shown as "0 done" clutter.
            sessionStatusCounts
            if sessions.sessionsExpanded && !sessions.sessions.isEmpty {
                // Item 1: a column-header-style caption over the toggle
                // column, so it's clear those switches don't just "show" a
                // session — they ARM auto-resume for it (CLI resume-on-reset,
                // or Cowork's dry-run UI-automation resume). Folded into the
                // existing header row (rather than a dedicated row below it)
                // so it doesn't add height that would need to be re-added to
                // sessionsExpandedExtra/SectionLayout.
                Text("auto-resume")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            sessions.toggleSessionsExpanded()
        }

        if sessions.sessionsExpanded {
            // Item 2 stutter fix: the frame that actually grows with the
            // drag is now isolated inside ResizableSessionsHeight (a leaf
            // view that alone observes `panelSize`) rather than applied
            // inline here — see OverlayView.panelSize's doc comment for why
            // that isolation is what fixes the stutter.
            ResizableSessionsHeight(panelSize: panelSize) {
                // Item 4: fixed height (see SectionLayout's doc comment)
                // instead of the old `.frame(maxHeight: 300)`, so this
                // block's rendered height never depends on whether Recent
                // chats is expanded.
                Group {
                    // Item 3 (merge): chats folded in here too, so "no rows
                    // at all" now depends on all three sources being empty.
                    // Chat fetch failures (isLoggedOut/lastError) are
                    // deliberately not surfaced with their own message here
                    // anymore (unlike the old standalone Recent chats
                    // section) — both fetchers share the same underlying
                    // webview session, so a real sign-out is already
                    // flagged at the title row's
                    // `model.isLoggedOut`/`model.lastError`; a chats-only
                    // hiccup just means zero chat rows join the list below,
                    // which reads fine on its own.
                    if sessions.sessions.isEmpty && cloudSessions.sessions.isEmpty && chats.chats.isEmpty {
                        Text("No sessions")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                // Status classification item: local, cloud,
                                // and (item 3) chat rows are merged into one
                                // list and sorted by status (needs-input
                                // first, then running, then idle/done —
                                // chats always fall into idle/done) rather
                                // than rendered as separate,
                                // independently-ordered blocks — a
                                // needs-input cloud session shouldn't be
                                // buried below a pile of idle local ones
                                // just because of which model it came from.
                                ForEach(combinedSessionRows) { row in
                                    switch row {
                                    case .local(let entry):
                                        sessionRow(entry)
                                    case .cloud(let entry):
                                        cloudSessionRow(entry)
                                    case .chat(let entry):
                                        chatRow(entry)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Item 2 stutter fix: the only piece of the Sessions section that needs
    /// to react live to a resize drag, isolated into its own tiny view so
    /// that reacting to it doesn't also force OverlayView.body — and
    /// therefore combinedSessionRows' full sort — to re-run on every pixel
    /// of drag. See OverlayView.panelSize's doc comment for the full
    /// diagnosis.
    private struct ResizableSessionsHeight<Content: View>: View {
        @ObservedObject var panelSize: PanelSizeState
        @ViewBuilder let content: Content

        var body: some View {
            content
                // Item 2 bug fix: extra height can now go negative (down to
                // the `sessionsMinContentHeight` floor set in
                // AppDelegate.setUserExtraHeight) so the user can shrink
                // below the default, not just grow beyond it — `max(...)`
                // here is a defensive clamp matching that same floor in
                // case `panelSize` is ever set from somewhere else.
                .frame(
                    height: max(SectionLayout.sessionsMinContentHeight, SectionLayout.sessionsContentHeight + panelSize.userExtraHeight),
                    alignment: .top
                )
        }
    }

    /// Status classification item: one row from either model, tagged so
    /// they can be merged into a single sorted list. See `combinedSessionRows`.
    private enum CombinedSessionRow: Identifiable {
        case local(SessionEntry)
        case cloud(CloudSessionEntry)
        /// Item 3 (merge): a claude.ai web conversation, folded into the
        /// unified list as its own row kind rather than living in a
        /// separate "Recent chats" section.
        case chat(ChatEntry)

        var id: String {
            switch self {
            case .local(let e): return "local-\(e.id)"
            case .cloud(let e): return "cloud-\(e.id)"
            case .chat(let e): return "chat-\(e.uuid)"
            }
        }

        var sortPriority: Int {
            switch self {
            case .local(let e): return OverlayView.priority(for: e.workStatus)
            case .cloud(let e): return OverlayView.priority(for: e.workStatus)
            // Item 3 (merge): a chat conversation is never "in progress"
            // work the way a session is — it always sorts into the same
            // bucket as an idle/done session, regardless of how recently it
            // was touched.
            case .chat: return OverlayView.priority(for: .idle)
            }
        }

        /// Sort deadband: the recency signal the secondary sort quantizes —
        /// local rows use the daemon's last-activity timestamp, cloud rows
        /// and chats their respective `updated_at`. `nil` (e.g. a
        /// pre-work_status daemon build) sorts as if it has no recency
        /// signal at all, i.e. last within its bucket rather than crashing
        /// the comparator.
        var recencyDate: Date? {
            switch self {
            case .local(let e): return e.lastActivityAt
            case .cloud(let e): return e.updatedAt
            case .chat(let e): return e.updatedAt
            }
        }
    }

    /// Sort-deadband tiebreak state (ITEM 1): holds the row-id order from the
    /// last time `combinedSessionRows` was computed. A plain class (not
    /// ObservableObject) — it's mutated as a side effect of computing the
    /// sort, not a publisher anything observes — wrapped in `@State` on
    /// OverlayView so the instance itself persists across body
    /// re-evaluations.
    private final class SessionOrderMemory {
        var order: [String] = []
    }

    /// Local rows (already de-duped by SessionsModel) plus cloud rows
    /// (already de-duped against local ids/titles and capped by
    /// CloudSessionsModel), merged and sorted:
    ///
    /// 1. Primary: needs-input < running < idle/done — a status-bucket
    ///    change (e.g. running -> needs_input) reorders immediately.
    /// 2. Secondary, WITHIN a status bucket: recency, but quantized to
    ///    60-second buckets (`floor(timestamp / 60)`) rather than raw
    ///    timestamps. Two rows whose activity lands in the same bucket are
    ///    NOT reordered by recency at all — a row must lead by a full
    ///    minute-bucket to overtake another. This is the fix for the report
    ///    that two running sessions trading activity within ~1s of each
    ///    other kept swapping rows on every refresh.
    /// 3. Tertiary, for rows in the same bucket: the row's position in the
    ///    PREVIOUSLY DISPLAYED arrangement (`sessionOrderMemory.order`)
    ///    rather than raw recency or insertion order — SwiftUI recomputing
    ///    this computed property gives no implicit stability of its own
    ///    (unlike, say, a `List` diffing by id), so the last arrangement is
    ///    persisted explicitly and used as the tiebreak. A row not present
    ///    in the previous arrangement (brand new this refresh) sorts after
    ///    every row that was already showing, rather than jumping in ahead
    ///    of them by chance.
    ///
    /// Idempotent by construction: re-running this against the SAME
    /// `sessionOrderMemory.order` it just wrote reproduces the identical
    /// arrangement (the tiebreak is a fixed point), which matters because
    /// SwiftUI may evaluate this computed property more than once per
    /// render pass.
    private var combinedSessionRows: [CombinedSessionRow] {
        let rows: [CombinedSessionRow] =
            sessions.sessions.map { .local($0) }
            + cloudSessions.sessions.map { .cloud($0) }
            // Item 3 (merge): same display cap (8) the old standalone
            // Recent chats section used — chats always sort into the
            // idle/done bucket regardless, so this only bounds how long the
            // scrollable list can get, never pushes out a running/
            // needs-input row.
            + chats.chats.prefix(8).map { .chat($0) }

        let previousIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: sessionOrderMemory.order.enumerated().map { ($1, $0) }
        )
        func bucket(_ row: CombinedSessionRow) -> Int {
            guard let date = row.recencyDate else { return Int.min }
            return Int(floor(date.timeIntervalSince1970 / 60))
        }

        let sorted = rows.sorted { a, b in
            if a.sortPriority != b.sortPriority { return a.sortPriority < b.sortPriority }
            let bucketA = bucket(a)
            let bucketB = bucket(b)
            if bucketA != bucketB { return bucketA > bucketB } // more-recent bucket first
            let indexA = previousIndex[a.id] ?? Int.max
            let indexB = previousIndex[b.id] ?? Int.max
            if indexA != indexB { return indexA < indexB }
            return false // genuinely tied (both new, same bucket): sorted(by:) is stable, so the local-then-cloud concatenation order above stands
        }

        sessionOrderMemory.order = sorted.map { $0.id }
        return sorted
    }

    /// needs-input < running < idle. A local row with no `workStatus` (daemon
    /// build predates the field) is bucketed with idle rather than given
    /// special placement — there's no classification to sort it by.
    private static func priority(for workStatus: SessionWorkStatus?) -> Int {
        switch workStatus {
        case .needsInput: return 0
        case .running: return 1
        case .idle, .none: return 2
        }
    }

    /// Status classification item: title text dims to signal done/idle —
    /// the dot's absence (see StatusIndicator) is the primary "this row is
    /// done" cue, but graying the title too makes it unambiguous even
    /// before you consciously notice a dot is missing. Running/needs-input
    /// rows keep the normal bright title.
    private func titleColor(_ workStatus: SessionWorkStatus?) -> Color {
        (workStatus ?? .idle) == .idle ? .white.opacity(0.45) : .white.opacity(0.95)
    }

    /// Combined running/needs-input/done counts across the full (local +
    /// cloud, deduped, pre-display-cap) list — see the header's doc comment
    /// at the call site.
    private var sessionRunningCount: Int {
        sessions.sessions.filter { OverlayView.priority(for: $0.workStatus) == 1 }.count + cloudSessions.runningCount
    }
    private var sessionNeedsInputCount: Int {
        sessions.sessions.filter { OverlayView.priority(for: $0.workStatus) == 0 }.count + cloudSessions.needsInputCount
    }
    /// Item 3 (merge) design choice: chat rows are folded into the "done"
    /// count rather than left uncounted. They aren't "work" in the
    /// running/needs-input sense the header's breakdown is really about,
    /// but the badge's total should still match how many rows are actually
    /// in the list below it — leaving them out risks the badge reading e.g.
    /// "2 running" while several more (chat) rows sit unaccounted-for
    /// beneath. Capped the same way the list itself is (prefix(8)).
    private var sessionIdleCount: Int {
        sessions.sessions.filter { OverlayView.priority(for: $0.workStatus) == 2 }.count
            + cloudSessions.idleCount
            + chats.chats.prefix(8).count
    }

    /// Status classification item: compact "N running · N input · N done"
    /// breakdown replacing the old plain total-count capsule. Zero-count
    /// categories are omitted; needs-input is bold amber since it's the one
    /// category that actually wants the user's attention.
    @ViewBuilder
    private var sessionStatusCounts: some View {
        let running = sessionRunningCount
        let needsInput = sessionNeedsInputCount
        let idle = sessionIdleCount
        if running + needsInput + idle > 0 {
            HStack(spacing: 3) {
                if running > 0 {
                    Text("\(running) running")
                }
                if needsInput > 0 {
                    if running > 0 {
                        Text("·").foregroundColor(.white.opacity(0.3))
                    }
                    Text("\(needsInput) input")
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                }
                if idle > 0 {
                    if running > 0 || needsInput > 0 {
                        Text("·").foregroundColor(.white.opacity(0.3))
                    }
                    Text("\(idle) done")
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private func sessionRow(_ entry: SessionEntry) -> some View {
        HStack(spacing: 6) {
            // Status classification item: unified running(pulsing
            // green)/needs-input(amber)/idle(no dot) indicator, same
            // language cloudSessionRow uses. A daemon build predating
            // `work_status` (nil) degrades to the idle/done treatment —
            // there's no classification to draw from in that case, and
            // idle is the safer default (never wrongly implies the row
            // needs attention).
            //
            // WS-2: a disconnected remote session's last-known work_status is
            // frozen and can't be trusted (the host stopped syncing), so
            // suppress the live dot entirely (nil → idle/no-dot) rather than
            // show a stale pulsing-green "running".
            StatusIndicator(workStatus: entry.remoteStale ? nil : entry.workStatus)

            // WS-2: remote-session badge — a desktopcomputer glyph in the
            // same icon slot cloudSessionRow uses for its cloud badge, so a
            // glance tells local / remote / cloud rows apart. Dimmed further
            // when the host is disconnected.
            if entry.isRemote {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(entry.remoteStale ? 0.3 : 0.6))
            }

            // Item 3B (click-to-open): tap targets ONLY this title/subtitle
            // column, not the whole row — the row also hosts the Resume
            // button and the auto-resume/arm toggle, which must keep
            // working as independent tap targets. `contentShape` makes the
            // VStack's whole bounding box (including its own vertical
            // padding-free gaps between the title/subtitle lines) tappable
            // rather than only the glyphs' own tight text bounds.
            VStack(alignment: .leading, spacing: 1) {
                // The session's own title (e.g. "Test session do nothing")
                // — much more useful for telling sessions in the same repo
                // apart than the project folder name alone, which is all
                // this used to show.
                Text(entry.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    // WS-2: a disconnected remote row grays out regardless of
                    // its (now-stale) work_status.
                    .foregroundColor(entry.remoteStale ? .white.opacity(0.35) : titleColor(entry.workStatus))
                    .lineLimit(1)
                if entry.displayTitle != entry.projectName {
                    Text(entry.projectName)
                        .font(.system(size: 8.5))
                        .foregroundColor((entry.workStatus ?? .idle) == .idle ? .white.opacity(0.25) : .white.opacity(0.4))
                        .lineLimit(1)
                }
                // WS-2: "on <host>" for remote rows, with a "disconnected"
                // note when the host stopped syncing.
                if let host = entry.host {
                    Text(entry.remoteStale ? "on \(host) · disconnected" : "on \(host)")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(entry.remoteStale ? 0.3 : 0.45))
                        .lineLimit(1)
                }
                if entry.needsAttention {
                    Text("needs attention")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.red.opacity(0.9))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                openLocalSession(entry)
            }
            // WS-2: remote rows copy an `ssh … claude --resume` command to the
            // clipboard on click (there's nothing local to foreground); local
            // rows foreground Claude Desktop. Disclose which via the tooltip.
            .help(entry.isRemote
                  ? "Copy an ssh resume command for this remote session to the clipboard"
                  : "Open Claude Desktop")

            Spacer()

            // Item 5: waiting (rate-limited) sessions still show the reset
            // countdown; active sessions show how long since their last
            // real activity instead of the old, always-identical
            // "active now". WS-2: a disconnected remote row shows
            // "disconnected" instead of a stale age.
            Text(entry.remoteStale
                 ? "disconnected"
                 : (entry.resetsAt != nil
                    ? sessions.resetText(for: entry.resetsAt)
                    : sessions.activityAgeText(entry.lastActivityAt)))
                .font(.system(size: 8.5))
                .foregroundColor(entry.remoteStale ? .white.opacity(0.3) : (readyToResume(entry) ? .green : .white.opacity(0.45)))

            if !entry.isActive {
                Button("Resume") {
                    sessions.resumeNow(entry.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.blue.opacity(0.9))
                // S4: be explicit that this runs unattended — the daemon
                // resumes the session in the background with a "continue"
                // prompt, permission mode acceptEdits by default.
                .help("Resume this session now, unattended: the daemon relaunches it with a \"continue\" prompt (permission mode acceptEdits by default)")
            }

            if entry.isCowork {
                // Cowork rows never show the CLI-oriented `enabled` toggle
                // (there's no rate-limit/resume cycle for Cowork to opt
                // into) — this is a distinct control: arming OS-level UI
                // automation of Claude Desktop's Resume space. Styled in
                // red/bolt to visually set it apart from the ordinary blue
                // `enabled` switch and make an armed row impossible to miss
                // at a glance. Nothing here fires automatically — arming
                // just flips a flag in state.json; the daemon-side
                // automation itself is hardcoded to dry-run until an
                // explicit follow-up sign-off.
                HStack(spacing: 3) {
                    if entry.resumeArmed {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.red.opacity(0.9))
                    }
                    // Toggle styling item: custom-drawn switch (CompactSwitch)
                    // replaces SwiftUI's native Toggle(.switch) here — see
                    // OverlayControls.swift's header comment for why (.tint
                    // doesn't reliably render on this control at .mini size
                    // on this macOS build). Saturated red track when armed.
                    CompactSwitch(isOn: entry.resumeArmed, tint: Color(nsColor: .systemRed)) {
                        sessions.setResumeArmed(entry.id, !entry.resumeArmed)
                    }
                }
                .help(entry.resumeArmed
                      ? "Armed: the daemon will attempt to auto-resume this Cowork session via UI automation (currently dry-run only — logs intent, does not click anything)"
                      : "Arm auto-resume for this Cowork session via UI automation of Claude Desktop's Resume space (currently dry-run only)")
            } else {
                // Toggle styling item: custom-drawn switch (CompactSwitch),
                // saturated green track when on — this is now the sole
                // visual indicator that auto-resume is armed for this row,
                // since the row background tint was removed previously.
                CompactSwitch(isOn: entry.enabled, tint: Color(nsColor: .systemGreen)) {
                    sessions.setEnabled(entry.id, !entry.enabled)
                }
                // S4: disclose that auto-resume runs the session unattended
                // (background "continue" prompt, permission mode acceptEdits
                // by default) — not just that it will fire on a rate limit.
                .help(entry.isActive
                      ? "Auto-resume if this session hits a rate limit — runs unattended with a \"continue\" prompt (permission mode acceptEdits by default)"
                      : "Auto-resume when the limit resets — runs unattended with a \"continue\" prompt (permission mode acceptEdits by default)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        // Toggle styling item: the row-tint background (green/red wash for
        // enabled/armed rows) was removed at the user's request — the
        // saturated toggle track (plus the bolt icon on armed Cowork rows)
        // is now the sole enabled/armed indicator, so every row shares the
        // same neutral background regardless of toggle state.
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }

    private func readyToResume(_ entry: SessionEntry) -> Bool {
        guard let resetsAt = entry.resetsAt else { return false }
        return resetsAt <= sessions.now
    }

    /// Cloud sessions item: a session running entirely on claude.ai's
    /// servers, with nothing local for the daemon to resume — so unlike
    /// sessionRow above, this has no enabled/resume-armed toggle or Resume
    /// button, only a small cloud badge marking it apart from the
    /// locally-tracked rows. A leading dot + brighter text mark sessions
    /// updated within the last ~10 minutes (CloudSessionsModel.isActive) as
    /// actively-running right now, vs. the dimmer treatment for older ones —
    /// this is what makes an active session like "Pittsburgh medical team
    /// search" (root cause of it going missing entirely: see ChatsFetcher's
    /// header comment) visually stand out once it IS being shown.
    @ViewBuilder
    private func cloudSessionRow(_ entry: CloudSessionEntry) -> some View {
        let active = cloudSessions.isActive(entry)
        // Status classification item: idle/done rows gray out regardless of
        // `active` (updated-recently) — a session that finished cleanly
        // shouldn't read as "bright" just because it was touched a few
        // minutes ago. Running/needs-input rows keep the existing
        // recency-driven brightness.
        let isDone = entry.workStatus == .idle
        HStack(spacing: 6) {
            // Status classification item: same running(pulsing
            // green)/needs-input(amber)/idle(no dot) language as
            // sessionRow — replaces the old green(recently-updated)/gray
            // dot, which conflated "updated recently" with "Claude is
            // actively working" (not the same thing; `active`/isActive
            // below still separately drives the brighter-text treatment
            // for a recently-touched, non-done row).
            StatusIndicator(workStatus: entry.workStatus)

            Image(systemName: "cloud.fill")
                .font(.system(size: 9))
                .foregroundColor(.cyan.opacity(isDone ? 0.35 : (active ? 0.95 : 0.5)))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isDone ? .white.opacity(0.45) : .white.opacity(active ? 0.95 : 0.55))
                    .lineLimit(1)
                Text("cloud session")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.cyan.opacity(isDone ? 0.25 : (active ? 0.6 : 0.35)))
            }

            Spacer()

            Text(cloudSessions.relativeText(for: entry.updatedAt))
                .font(.system(size: 8.5))
                .foregroundColor(isDone ? .white.opacity(0.3) : (active ? .green.opacity(0.85) : .white.opacity(0.4)))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.cyan.opacity(isDone ? 0.05 : (active ? 0.14 : 0.06))))
        // Item 3B: no competing interactive controls on this row (unlike
        // sessionRow's Resume button/toggle), so the whole row is the tap
        // target — same pattern chatRow uses.
        .contentShape(Rectangle())
        .onTapGesture {
            openCloudSession(entry)
        }
    }

    // MARK: - Chats (item 3: merged into the unified Sessions list — see
    // CombinedSessionRow.chat/combinedSessionRows above; this is now just
    // one row kind rendered inside sessionsSection's ForEach, no longer its
    // own collapsible section)

    /// A claude.ai web conversation row. Styled like a permanently
    /// idle/done session — no StatusIndicator dot (a conversation is never
    /// "in progress" the way a running session is), dimmed title, and a
    /// chat-bubble glyph in the icon slot cloudSessionRow uses for its cloud
    /// badge, so a glance tells the three row kinds apart (plain row =
    /// local, cloud icon = cloud session, bubble = chat). Click-to-open
    /// behavior (opens https://claude.ai/chat/{uuid} in the default
    /// browser) is unchanged from the old standalone Recent chats section.
    @ViewBuilder
    private func chatRow(_ entry: ChatEntry) -> some View {
        HStack(spacing: 6) {
            // Same idle placeholder every idle/done sessionRow/
            // cloudSessionRow uses, so the leading column stays aligned
            // across all three row kinds in the merged list.
            StatusIndicator(workStatus: .idle)

            Image(systemName: "bubble.left.fill")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.3))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                Text("chat")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.25))
            }

            Spacer()

            Text(chats.relativeText(for: entry.updatedAt))
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture {
            openChat(entry.uuid)
        }
    }

    /// Opens the conversation in the default browser rather than trying to
    /// deep-link into the (hidden, headless-ish) webview this widget already
    /// owns — simple and reliable, and it's the same place the user would
    /// end up reading/replying anyway.
    private func openChat(_ uuid: String) {
        guard let url = URL(string: "https://claude.ai/chat/\(uuid)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Item 3B (click-to-open, local CLI/Cowork rows): originally deep-linked
    /// into Claude Desktop's own `claude://resume?session={id}` route
    /// (reverse-engineered from
    /// /Applications/Claude.app/Contents/Resources/app.asar — LocalSession-
    /// Manager.importCliSession), which imports the transcript and brings
    /// Desktop to the foreground.
    ///
    /// Item 3B bug fix (round 1): a real user report caught this creating
    /// duplicate tabs for Cowork rows — importCliSession keys every import
    /// as `local_<cliSessionId>` and only dedupes against ITS OWN prior
    /// imports, with no awareness that a native Cowork tab might already
    /// reference that same CLI transcript via that tab's own internal
    /// `cliSessionId` field. So clicking didn't focus the existing tab — it
    /// silently created a second, generic ("General coding session") static
    /// copy and switched focus to *that*, which is also why the live tab's
    /// auto/permission mode appeared to vanish: it hadn't been disabled, the
    /// click had just navigated to a different session object that never
    /// had it set. Fixed by no longer deep-linking Cowork rows — just
    /// foreground Desktop and leave tab selection to the user.
    ///
    /// Item 3B bug fix (round 2): a follow-up report showed the exact same
    /// duplicate-"General coding session"-tab symptom on plain CLI/Code
    /// rows too — so the earlier assumption that CLI sessions are safe
    /// (because they'd have no pre-existing native tab to collide with) was
    /// wrong; Desktop can end up with its own native representation of a
    /// CLI session in other ways (e.g. its own Code-session browsing), and
    /// importCliSession has no way to detect that from outside any more
    /// than it could for Cowork. No URL fixes this — it's a gap in
    /// Desktop's own import path, not a wrong query param — so ALL local
    /// rows (CLI and Cowork alike) now just foreground Claude Desktop and
    /// leave tab selection to the user.
    ///
    /// WS-2 (remote rows): a remote session has nothing local to foreground —
    /// its transcript lives on the remote host's `~/.claude/projects`. Instead
    /// of a dead click, copy a ready-to-run resume command
    /// (`ssh -t <target> 'cd <dir> && claude --resume <remoteId>'`) to the
    /// pasteboard so the user can paste it into a terminal. `<target>` is the
    /// config ssh target resolved from the entry's host name (falling back to
    /// the host name itself when unresolved — works when it's an ssh alias).
    private func openLocalSession(_ entry: SessionEntry) {
        if entry.isRemote, let host = entry.host {
            let target = resolveHostSSH(host) ?? host
            let remoteId = entry.remoteId ?? entry.id
            // Finding 6: projectDir is interpolated inside a single-quoted
            // shell word — a literal `'` in the path would otherwise close the
            // quote early and produce a broken command. Escape via the
            // standard '\'' technique (close quote, escaped quote, reopen).
            let safeDir = entry.projectDir.replacingOccurrences(of: "'", with: "'\\''")
            let command = "ssh -t \(target) 'cd \(safeDir) && claude --resume \(remoteId)'"
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
            return
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Item 3B (click-to-open, cloud session rows): see the "Item 3B
    /// click-to-open findings" block at the bottom of ChatsFetcher.swift for
    /// what was actually probed/confirmed about claude.ai's URL shape for a
    /// `/recents` code/cowork session — no reliable per-session deep link
    /// was found (candidate paths 200'd identically for real vs. bogus
    /// ids), so this opens the claude.ai home page rather than guessing a
    /// path that might 404 or land somewhere confusing.
    private func openCloudSession(_ entry: CloudSessionEntry) {
        guard let url = URL(string: "https://claude.ai") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Plan fit (item 3: its own tab, not a Main-tab collapsible
    // section anymore — always shows full content when selected, no
    // expand/collapse chevron needed since the tab selection itself is the
    // show/hide control.)

    @ViewBuilder
    private var planFitTabContent: some View {
        if let data = planFit.data {
            // Finding 1: gate the API-vs-Max layout switch on the LIVE config
            // account type (mirrors mainTabContent), not `data.isApiAccount`
            // from plan_fit.json — the latter is regenerated at most hourly, so
            // the Plan-fit tab used to lag the Main tab by seconds-to-an-hour
            // after an account-type flip. Dollar numbers still come from `data`;
            // config only picks which framing to show.
            let isApi = configStore.config.isApiAccount
            VStack(alignment: .leading, spacing: 9) {
                // Current-plan identity used to live in the section header's
                // trailing badge; kept here (rather than dropped) since the
                // tab pill alone doesn't say which plan the numbers below
                // are being judged against. WS-2: hidden on API accounts —
                // the plan/tier comparison isn't the relevant framing there
                // (a dollar budget is), so it's replaced by the budget
                // summary line below.
                // The capsule reads the LIVE config plan, not plan_fit.json's
                // current_plan — the latter only updates after the daemon's
                // config-triggered rewrite lands AND this model re-reads the
                // file, which made a Max pro/5x/20x switch in Settings look
                // like it didn't take. (Same live-config treatment the
                // API/Max framing already got.) The verdict/tier text below
                // still comes from plan_fit.json and catches up within
                // seconds via the post-config-change refresh burst.
                if !isApi {
                    HStack {
                        Text("Current plan")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                        Text(planFit.displayName(forPlanKey: configStore.config.accountPlan))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                }

                // WS-2: compact budget summary for API accounts — the
                // moving-averages / run-rate / cost-peaks below stay
                // (they're account-type-agnostic), but the tier grid and Max
                // recommendation are suppressed further down.
                if isApi {
                    apiBudgetSummary(data)
                }

                // Moving averages — one line per window, coverage annotation
                // only shown while the window is still filling up. Missing
                // windows are simply omitted.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(["1d", "7d", "30d", "90d"], id: \.self) { key in
                        if let w = data.movingAverages[key] {
                            Text(planFit.movingAverageLine(key: key, window: w))
                                .font(.system(size: 9.5))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }

                if let apiEquiv = planFit.apiEquivalentText(data) {
                    Text(apiEquiv)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }

                // Item 6: two label-prefixed rows (cost, then utilization)
                // rather than one line, so nothing truncates.
                peaksGrid(data)

                // WS-2: the plan-tier comparison grid is Max-plan framing —
                // hidden on API accounts, where the budget summary above is
                // the relevant number instead.
                if !data.tiers.isEmpty && !isApi {
                    tierGrid(data.tiers)
                }
            }
        } else {
            Text("collecting data…")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    /// WS-2: compact budget summary for the Plan-fit tab on API accounts —
    /// one line per configured period ("Weekly $61 / $200 (31%)"). Replaces
    /// the plan capsule / tier grid framing, which doesn't apply to a
    /// dollar-billed account. Shows a muted prompt when no budget is set.
    @ViewBuilder
    private func apiBudgetSummary(_ data: PlanFitData) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if data.hasBudget {
                if let line = planFit.budgetSummaryLine(label: "Weekly", window: data.budgetWeekly) {
                    Text(line)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
                if let line = planFit.budgetSummaryLine(label: "Monthly", window: data.budgetMonthly) {
                    Text(line)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
            } else {
                Text("No budget set")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    /// Item 4: fixed-column Grid so plan name / price / ratio / peaks line up
    /// vertically across tier rows instead of drifting per-row with an
    /// HStack + Spacer. The "× API" header labels the ratio column so each
    /// row's number reads unambiguously as "N times the price of API-metered
    /// usage" (item 4a) without repeating "API value" on every row.
    @ViewBuilder
    private func tierGrid(_ tiers: [TierVerdict]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            GridRow {
                Text("Plan")
                Text("Price").gridColumnAlignment(.trailing)
                Text("× API").gridColumnAlignment(.trailing)
                Text("Peaks")
            }
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.4))

            ForEach(tiers, id: \.key) { tier in
                tierGridRow(tier)
            }
        }
    }

    @ViewBuilder
    private func tierGridRow(_ tier: TierVerdict) -> some View {
        let color: Color = tier.isFlagged ? .red.opacity(0.9) : .white.opacity(0.85)
        GridRow {
            Text(tier.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
            Text(planFit.priceText(tier) ?? "—")
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(.white.opacity(0.55))
            Text(planFit.ratioText(tier) ?? "—")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.8))
            Text(tierPeaksText(tier))
                .font(.system(size: 8.5).monospacedDigit())
                .foregroundColor(tier.isFlagged ? .red.opacity(0.9) : .white.opacity(0.5))
        }
    }

    private func tierPeaksText(_ tier: TierVerdict) -> String {
        let p5 = tier.projectedPeak5hUtil.map { String(format: "5h %.0f%%", $0) } ?? "—"
        let p7 = tier.projectedPeak7dUtil.map { String(format: "7d %.0f%%", $0) } ?? "—"
        return "\(p5) / \(p7)"
    }

    /// Item 6: two short label-prefixed rows (cost, then utilization) in
    /// place of the old single-line "peak 1h: … · peak 5h: … · peak 5h
    /// util: … · peak 7d util: …" which truncated the last value. Grid keeps
    /// each row's two values column-aligned the same way the tier rows are.
    /// Returns nothing (not even the label column) if there's genuinely no
    /// peak data at all, same as the old peaksText's nil-hides-the-row
    /// behavior.
    @ViewBuilder
    private func peaksGrid(_ data: PlanFitData) -> some View {
        let hasCost = data.peakOneHourUsd != nil || data.peakFiveHourUsd != nil
        let hasUtil = data.utilFiveHourPeakPct != nil || data.utilSevenDayPeakPct != nil
        if hasCost || hasUtil {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                if hasCost {
                    GridRow {
                        Text("peak cost").foregroundColor(.white.opacity(0.4))
                        Text(planFit.formatPeak("1h", "$%.2f", data.peakOneHourUsd)).foregroundColor(.white.opacity(0.7))
                        Text(planFit.formatPeak("5h", "$%.2f", data.peakFiveHourUsd)).foregroundColor(.white.opacity(0.7))
                    }
                }
                if hasUtil {
                    GridRow {
                        Text("peak util").foregroundColor(.white.opacity(0.4))
                        Text(planFit.formatPeak("5h", "%.0f%%", data.utilFiveHourPeakPct)).foregroundColor(.white.opacity(0.7))
                        Text(planFit.formatPeak("7d", "%.0f%%", data.utilSevenDayPeakPct)).foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .font(.system(size: 8.5).monospacedDigit())
        }
    }

    // MARK: - Usage rows

    /// Item 2: `trailingCaption`, when supplied (the Weekly row passes
    /// `model.lastUpdatedText`), renders right-aligned and italicized on the
    /// same line as `resetText` — this is what let the old standalone
    /// "updated Xm" line under the usage rows be deleted entirely.
    ///
    /// `estimatedPercent` (projected usage at reset — see
    /// UsageModel.estimatedPercent) shows up two ways: as a muted
    /// "(N%)" next to the actual percent, and as a small dot on the bar at
    /// the projected position. If the projection exceeds 100%, the dot
    /// turns red and pins to the 100% mark instead of running off the end of
    /// the bar, and the "(N%)" label turns red too.
    @ViewBuilder
    private func row(label: String, percent: Int?, estimatedPercent: Int? = nil, resetText: String, trailingCaption: String? = nil) -> some View {
        let willExceed = (estimatedPercent ?? 0) > 100
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(percent != nil ? "\(percent!)%" : "—")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                if let estimatedPercent {
                    Text("(\(estimatedPercent)%)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(willExceed ? .red.opacity(0.9) : .white.opacity(0.45))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(percent))
                        .frame(width: geo.size.width * CGFloat(min(max(percent ?? 0, 0), 100)) / 100.0)
                    if let estimatedPercent {
                        let dotRadius: CGFloat = 2.5
                        let fraction = CGFloat(min(max(estimatedPercent, 0), 100)) / 100.0
                        let x = min(max(geo.size.width * fraction, dotRadius), geo.size.width - dotRadius)
                        Circle()
                            .fill(willExceed ? Color.red : Color.white)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: x, y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 5)
            HStack {
                Text(resetText)
                    .font(.system(size: 8.5))
                    .foregroundColor(.white.opacity(0.45))
                if let trailingCaption {
                    Spacer()
                    Text(trailingCaption)
                        .italic()
                        .font(.system(size: 8.5))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
        }
    }

    private func barColor(_ percent: Int?) -> Color {
        guard let p = percent else { return .gray }
        if p >= 90 { return .red }
        if p >= 70 { return .orange }
        return .green
    }
}
