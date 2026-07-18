import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var sessions: SessionsModel

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

            row(label: "Session (5h)", percent: model.sessionPercent, resetText: model.resetText(for: model.sessionResetsAt))
            row(label: "Weekly", percent: model.weeklyPercent, resetText: model.resetText(for: model.weeklyResetsAt))

            Text(model.lastUpdatedText)
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.4))

            Divider().background(Color.white.opacity(0.15))

            sessionsSection
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

            if !entry.isCowork {
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
