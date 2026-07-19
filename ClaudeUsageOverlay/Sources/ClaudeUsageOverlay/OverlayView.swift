import SwiftUI
import AppKit

struct OverlayView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var sessions: SessionsModel
    @ObservedObject var chats: ChatsModel
    @ObservedObject var planFit: PlanFitModel
    @ObservedObject var graph: GraphModel
    /// Opens the larger, resizable graph window (item 3) — forwarded down to
    /// GraphView's expand button.
    var onExpandGraph: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
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

            tabSwitch

            if graph.selectedTab == .main {
                mainTabContent
            } else {
                GraphView(model: graph, onExpand: onExpandGraph)
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
    }

    // MARK: - Tab switch

    /// Small pill-style tab switch between the existing main view (usage
    /// bars + sessions + chats + plan fit) and the new Graph view. Styled to
    /// match the panel's existing dark, compact controls rather than a
    /// native segmented control, which would look out of place here.
    private var tabSwitch: some View {
        HStack(spacing: 4) {
            tabButton(title: "Main", tab: .main)
            tabButton(title: "Graph", tab: .graph)
            Spacer()
        }
    }

    private func tabButton(title: String, tab: PanelTab) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: graph.selectedTab == tab ? .bold : .medium))
            .foregroundColor(graph.selectedTab == tab ? .white : .white.opacity(0.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(graph.selectedTab == tab ? Color.white.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard graph.selectedTab != tab else { return }
                graph.toggleTab()
            }
    }

    // MARK: - Main tab content

    @ViewBuilder
    private var mainTabContent: some View {
        row(label: "Session (5h)", percent: model.sessionPercent, resetText: model.resetText(for: model.sessionResetsAt))
        row(label: "Weekly", percent: model.weeklyPercent, resetText: model.resetText(for: model.weeklyResetsAt))

        Text(model.lastUpdatedText)
            .font(.system(size: 8.5))
            .foregroundColor(.white.opacity(0.4))

        Divider().background(Color.white.opacity(0.15))

        sessionsSection

        Divider().background(Color.white.opacity(0.15))

        chatsSection

        Divider().background(Color.white.opacity(0.15))

        planFitSection
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
            if !sessions.sessions.isEmpty {
                Text("\(sessions.sessions.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            sessions.toggleSessionsExpanded()
        }

        if sessions.sessionsExpanded {
            if sessions.sessions.isEmpty {
                Text("No sessions")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions.sessions) { entry in
                            sessionRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ entry: SessionEntry) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(entry.isActive ? Color.blue : Color.orange)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                // The session's own title (e.g. "Test session do nothing")
                // — much more useful for telling sessions in the same repo
                // apart than the project folder name alone, which is all
                // this used to show.
                Text(entry.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                if entry.displayTitle != entry.projectName {
                    Text(entry.projectName)
                        .font(.system(size: 8.5))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
                if entry.needsAttention {
                    Text("needs attention")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.red.opacity(0.9))
                }
            }

            Spacer()

            Text(sessions.resetText(for: entry.resetsAt))
                .font(.system(size: 8.5))
                .foregroundColor(readyToResume(entry) ? .green : .white.opacity(0.45))

            if !entry.isActive {
                Button("Resume") {
                    sessions.resumeNow(entry.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.blue.opacity(0.9))
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
                    Toggle("", isOn: Binding(
                        get: { entry.resumeArmed },
                        set: { sessions.setResumeArmed(entry.id, $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(.red)
                }
                .help(entry.resumeArmed
                      ? "Armed: the daemon will attempt to auto-resume this Cowork session via UI automation (currently dry-run only — logs intent, does not click anything)"
                      : "Arm auto-resume for this Cowork session via UI automation of Claude Desktop's Resume space (currently dry-run only)")
            } else {
                Toggle("", isOn: Binding(
                    get: { entry.enabled },
                    set: { sessions.setEnabled(entry.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(entry.isActive ? "Auto-resume if this session hits a rate limit" : "Auto-resume when the limit resets")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }

    private func readyToResume(_ entry: SessionEntry) -> Bool {
        guard let resetsAt = entry.resetsAt else { return false }
        return resetsAt <= sessions.now
    }

    // MARK: - Recent chats

    @ViewBuilder
    private var chatsSection: some View {
        HStack {
            Image(systemName: chats.chatsExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
            Text("Recent chats")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            if chats.isLoggedOut {
                Text("Sign in needed")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.orange)
            } else if !chats.chats.isEmpty {
                Text("\(chats.chats.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            chats.toggleChatsExpanded()
        }

        if chats.chatsExpanded {
            if chats.isLoggedOut {
                Text("Sign in needed")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.85))
            } else if chats.lastError != nil {
                // Undocumented endpoint — on any failure (auth aside), show
                // one muted line rather than surfacing raw error text or an
                // empty-looking list that reads as "you have no chats".
                Text("chats unavailable")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            } else if chats.chats.isEmpty {
                Text("No recent chats")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(chats.chats.prefix(8)) { entry in
                            chatRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ entry: ChatEntry) -> some View {
        HStack(spacing: 6) {
            Text(entry.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.95))
                .lineLimit(1)

            Spacer()

            Text(chats.relativeText(for: entry.updatedAt))
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.45))
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

    // MARK: - Plan fit

    @ViewBuilder
    private var planFitSection: some View {
        HStack {
            Image(systemName: planFit.planFitExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
            Text("Plan fit")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            if let plan = planFit.data?.currentPlan {
                Text(planFit.displayName(forPlanKey: plan))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
        }
        .contentShape(Rectangle())
        // Collapsed, this header row is the last thing in the card — without
        // a little breathing room here the text sits flush against the
        // panel's bottom edge. Only needed while collapsed; expanded state
        // already has plenty of trailing content below it.
        .padding(.bottom, planFit.planFitExpanded ? 0 : 3)
        .onTapGesture {
            planFit.toggleExpanded()
        }

        if planFit.planFitExpanded {
            if let data = planFit.data {
                VStack(alignment: .leading, spacing: 6) {
                    // Moving averages — one line per window, coverage
                    // annotation only shown while the window is still
                    // filling up. Missing windows are simply omitted.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(["1d", "7d", "30d", "90d"], id: \.self) { key in
                            if let w = data.movingAverages[key] {
                                Text(planFit.movingAverageLine(key: key, window: w))
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                    }

                    if let apiEquiv = planFit.apiEquivalentText(data) {
                        Text(apiEquiv)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }

                    // Item 6: was a single Text(peaksText) trying to cram
                    // four values onto one line — with all four present it
                    // overflowed the panel width and the last value (peak 7d
                    // util) got clipped by SwiftUI's default truncation.
                    // Split into two label-prefixed rows (cost, then
                    // utilization) so nothing ever truncates.
                    peaksGrid(data)

                    if !data.tiers.isEmpty {
                        tierGrid(data.tiers)
                    }
                }
            } else {
                Text("collecting data…")
                    .font(.system(size: 9))
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

    @ViewBuilder
    private func row(label: String, percent: Int?, resetText: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(percent != nil ? "\(percent!)%" : "—")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(percent))
                        .frame(width: geo.size.width * CGFloat(min(max(percent ?? 0, 0), 100)) / 100.0)
                }
            }
            .frame(height: 5)
            Text(resetText)
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private func barColor(_ percent: Int?) -> Color {
        guard let p = percent else { return .gray }
        if p >= 90 { return .red }
        if p >= 70 { return .orange }
        return .green
    }
}
