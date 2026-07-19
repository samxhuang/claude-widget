import SwiftUI
import AppKit
import Foundation

/// Owns the real (titled/closable) Settings NSWindow, hosting `SettingsView`.
/// Kept alive singleton-style by AppDelegate so the window and its ConfigStore
/// survive being closed and reopened. A plain NSWindow rather than a popover
/// per the plan — the Remote Hosts section (tables, deploy sheets) needs real
/// window chrome and room.
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(configStore: configStore))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Claude Widget Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 480, height: 600))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // Accessory app (no Dock icon) — activate so the window actually
        // comes to the front rather than opening behind whatever's focused.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root settings view

struct SettingsView: View {
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AccountBudgetSection(configStore: configStore)
                Divider()
                SessionsSection(configStore: configStore)
                Divider()
                RemoteHostsSection(configStore: configStore)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 480)
    }
}

// MARK: - Account & Budget

/// The four account choices the picker collapses (type, plan) into. API keeps
/// the last Max plan around (plan_fit.py still uses it for the tier-comparison
/// ratio on API accounts).
private enum AccountChoice: String, CaseIterable, Identifiable {
    case maxPro
    case max5x
    case max20x
    case api
    var id: String { rawValue }
    var label: String {
        switch self {
        case .maxPro: return "Max — Pro"
        case .max5x:  return "Max — 5x"
        case .max20x: return "Max — 20x"
        case .api:    return "API (dollar budget)"
        }
    }

    static func from(config: AppConfig) -> AccountChoice {
        if config.accountType == "api" { return .api }
        switch config.accountPlan {
        case "pro":    return .maxPro
        case "max_5x": return .max5x
        default:       return .max20x
        }
    }

    /// (type, plan) written back to config. For API, `preservingPlan` keeps
    /// whatever Max plan the user last had so switching back restores it.
    func typeAndPlan(preservingPlan plan: String) -> (String, String) {
        switch self {
        case .maxPro: return ("max", "pro")
        case .max5x:  return ("max", "max_5x")
        case .max20x: return ("max", "max_20x")
        case .api:    return ("api", plan)
        }
    }
}

// Finding 2: the Python config validator (contract C1) only accepts "monday"
// or "sunday" for week_start — any other value silently computes Monday weeks
// while the UI would have shown the chosen day. Restrict the picker to the two
// the daemon actually honors rather than offering all seven.
private let weekdayOptions = ["monday", "sunday"]

// MARK: - Sessions

/// How long an idle session stays in the Sessions list before the daemon
/// drops it (config.json `sessions.idle_retention_minutes`). A discrete
/// picker rather than a free-text field, so — unlike the typed budget fields
/// above — selecting IS applying; no Apply/Cancel ambiguity to resolve. The
/// daemon picks the change up within one 10s poll.
struct SessionsSection: View {
    @ObservedObject var configStore: ConfigStore

    /// (minutes, label). 30 is the historical default; the daemon clamps
    /// anything outside 5–1440.
    private static let options: [(Int, String)] = [
        (15, "15 minutes"),
        (30, "30 minutes (default)"),
        (60, "1 hour"),
        (120, "2 hours"),
        (240, "4 hours"),
        (720, "12 hours"),
        (1440, "24 hours"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(.headline)
            Picker("Keep idle sessions listed for", selection: Binding(
                get: { nearestOption(configStore.config.idleRetentionMinutes) },
                set: { configStore.setIdleRetention(minutes: $0) }
            )) {
                ForEach(Self.options, id: \.0) { minutes, label in
                    Text(label).tag(minutes)
                }
            }
            .pickerStyle(.menu)
            Text("A session that goes quiet stays in the widget's Sessions list this long before it's dropped. Applies immediately; sessions cut off by a rate limit are kept regardless until resumed.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// A hand-edited config can hold any clamped value (e.g. 45); snap the
    /// picker to the nearest option for display without rewriting the file.
    private func nearestOption(_ minutes: Int) -> Int {
        Self.options.min(by: {
            abs($0.0 - minutes) < abs($1.0 - minutes)
        })?.0 ?? 30
    }
}

struct AccountBudgetSection: View {
    @ObservedObject var configStore: ConfigStore

    @State private var accountChoice: AccountChoice = .max20x
    @State private var weeklyText: String = ""
    @State private var monthlyText: String = ""
    @State private var weekStart: String = "monday"
    @State private var seeded = false
    /// Snapshot of the section-owned config fields as this section last
    /// seeded them or wrote them via Apply. Fields now buffer locally until
    /// Apply (no save-on-change), so this serves two jobs: `isDirty`
    /// (edits differ from what's applied → enable Apply/Cancel) and external-
    /// edit attribution (a config change arriving while the user has NO
    /// pending edits re-seeds the fields; one arriving mid-edit leaves their
    /// typing alone — they can Cancel to pick it up).
    @State private var lastSyncedSnapshot: SectionSnapshot?

    /// The subset of AppConfig this section reads/writes, compared to decide
    /// whether an incoming config change originated here or elsewhere.
    private struct SectionSnapshot: Equatable {
        let choice: AccountChoice
        let weeklyUsd: Double?
        let monthlyUsd: Double?
        let weekStart: String
    }

    private func snapshot(of c: AppConfig) -> SectionSnapshot {
        SectionSnapshot(
            choice: AccountChoice.from(config: c),
            weeklyUsd: c.weeklyUsd,
            monthlyUsd: c.monthlyUsd,
            weekStart: weekdayOptions.contains(c.weekStart) ? c.weekStart : "monday"
        )
    }

    private var weeklyValid: Bool { Self.isValidBudget(weeklyText) }
    private var monthlyValid: Bool { Self.isValidBudget(monthlyText) }

    /// The fields as currently edited (not yet applied), in snapshot form.
    private var editedSnapshot: SectionSnapshot {
        SectionSnapshot(
            choice: accountChoice,
            weeklyUsd: weeklyText.isEmpty ? nil : Double(weeklyText),
            monthlyUsd: monthlyText.isEmpty ? nil : Double(monthlyText),
            weekStart: weekStart
        )
    }

    private var hasInvalidInput: Bool {
        (!weeklyText.isEmpty && !weeklyValid) || (!monthlyText.isEmpty && !monthlyValid)
    }

    /// Edits differ from the live config (or hold invalid text worth
    /// cancelling out of). Drives the Apply/Cancel enabled state.
    private var isDirty: Bool {
        hasInvalidInput || editedSnapshot != snapshot(of: configStore.config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account & Budget")
                .font(.headline)

            Picker("Account", selection: $accountChoice) {
                ForEach(AccountChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)

            // Budget fields are meaningful for both account types (the daemon
            // emits the budget block for Max too — the widget just doesn't
            // show bars there), so they're always editable. The caption below
            // notes that they only drive the main-tab bars on API accounts.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Weekly budget")
                    HStack(spacing: 4) {
                        Text("$")
                        TextField("none", text: $weeklyText)
                            .frame(width: 100)
                        if !weeklyText.isEmpty && !weeklyValid {
                            Text("must be a positive number").foregroundColor(.red).font(.caption)
                        }
                    }
                }
                GridRow {
                    Text("Monthly budget")
                    HStack(spacing: 4) {
                        Text("$")
                        TextField("none", text: $monthlyText)
                            .frame(width: 100)
                        if !monthlyText.isEmpty && !monthlyValid {
                            Text("must be a positive number").foregroundColor(.red).font(.caption)
                        }
                    }
                }
                GridRow {
                    Text("Week starts")
                    Picker("", selection: $weekStart) {
                        ForEach(weekdayOptions, id: \.self) { day in
                            Text(day.capitalized).tag(day)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            Text(accountChoice == .api
                 ? "On API accounts the main tab shows dollar budget bars instead of the Max session/weekly percentages."
                 : "Budgets are saved but the main tab shows Max session/weekly percentages for this account type.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Edits buffer locally until Apply — nothing is written on
            // change, so it's unambiguous when settings take effect. Both
            // buttons stay disabled while the fields match the live config.
            HStack {
                Spacer()
                Button("Cancel") { applyConfig(configStore.config) }
                    .disabled(!isDirty)
                Button("Apply") { applyEdits() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty || hasInvalidInput)
            }
        }
        .onAppear(perform: seedFromConfig)
        // Finding 2: the Settings window is kept alive (isReleasedWhenClosed =
        // false), so an externally-edited config.json picked up by
        // ConfigStore.reloadIfChanged must reflect here without a relaunch.
        // Re-seed only when the user has no pending edits relative to what we
        // last seeded/applied — an external change arriving mid-edit leaves
        // their typing alone (Cancel discards it and picks up the new values).
        .onChange(of: configStore.config) { newConfig in
            if editedSnapshot == lastSyncedSnapshot {
                applyConfig(newConfig)
            }
        }
    }

    private func seedFromConfig() {
        guard !seeded else { return }
        seeded = true
        applyConfig(configStore.config)
    }

    /// Seeds all editable fields from `c` and records the snapshot so a
    /// subsequent config change can be attributed to this section or elsewhere.
    private func applyConfig(_ c: AppConfig) {
        accountChoice = AccountChoice.from(config: c)
        weeklyText = c.weeklyUsd.map { Self.formatBudget($0) } ?? ""
        monthlyText = c.monthlyUsd.map { Self.formatBudget($0) } ?? ""
        // Finding 2 (round 1): only monday/sunday are valid options now — fall
        // back to monday for any other stored value (old/hand-edited config) so
        // the Picker has a matching tag rather than rendering blank.
        weekStart = weekdayOptions.contains(c.weekStart) ? c.weekStart : "monday"
        lastSyncedSnapshot = snapshot(of: c)
    }

    /// Apply: write all buffered edits to config in one go. Only reachable
    /// with valid input (the button disables on hasInvalidInput). Records the
    /// applied snapshot so the resulting config publish isn't mistaken for an
    /// external edit.
    private func applyEdits() {
        let (type, plan) = accountChoice.typeAndPlan(preservingPlan: configStore.config.accountPlan)
        configStore.setAccount(type: type, plan: plan)
        configStore.setBudget(weeklyUsd: weeklyText.isEmpty ? nil : Double(weeklyText),
                              monthlyUsd: monthlyText.isEmpty ? nil : Double(monthlyText),
                              weekStart: weekStart, timezone: configStore.config.timezone)
        lastSyncedSnapshot = editedSnapshot
    }

    private static func isValidBudget(_ s: String) -> Bool {
        guard let v = Double(s) else { return false }
        return v.isFinite && v > 0
    }

    private static func formatBudget(_ v: Double) -> String {
        (v == v.rounded()) ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}

// MARK: - Remote Hosts

/// Which host sheet is up. One enum-driven `.sheet(item:)` rather than three
/// separate `.sheet` modifiers on the same view — stacking multiple sheet
/// modifiers on one view is historically unreliable in SwiftUI.
private enum HostSheet: Identifiable {
    case add
    case redeploy(RemoteHostConfig)
    case remove(RemoteHostConfig)
    var id: String {
        switch self {
        case .add: return "add"
        case .redeploy(let h): return "redeploy-\(h.name)"
        case .remove(let h): return "remove-\(h.name)"
        }
    }
}

struct RemoteHostsSection: View {
    @ObservedObject var configStore: ConfigStore

    @State private var activeSheet: HostSheet?
    /// Hosts whose most recent deploy attempt (this session) failed — drives
    /// the ⚠ status. Cleared on a subsequent successful deploy.
    @State private var deployFailed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Remote Hosts")
                    .font(.headline)
                Spacer()
                Button {
                    activeSheet = .add
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }

            if configStore.config.remoteHosts.isEmpty {
                Text("No remote hosts. Add one to sync Claude Code sessions running over SSH.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(configStore.config.remoteHosts) { host in
                        HostRow(
                            host: host,
                            status: status(for: host),
                            onToggleEnabled: { configStore.setHostEnabled(named: host.name, $0) },
                            onChange: { configStore.upsertHost($0) },
                            onRedeploy: { activeSheet = .redeploy(host) },
                            onRemove: { activeSheet = .remove(host) }
                        )
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddHostSheet(configStore: configStore, existingNames: Set(configStore.config.remoteHosts.map { $0.name })) { name, succeeded in
                    if !succeeded { deployFailed.insert(name) } else { deployFailed.remove(name) }
                }
            case .redeploy(let host):
                RedeploySheet(configStore: configStore, host: host) { succeeded in
                    if succeeded { deployFailed.remove(host.name) } else { deployFailed.insert(host.name) }
                }
            case .remove(let host):
                RemoveHostSheet(configStore: configStore, host: host)
            }
        }
    }

    /// Status shown in the row's dot. We can't observe live sync reachability
    /// from the Settings window (the daemon owns that) — so this reflects
    /// config + this session's deploy outcomes: ⚠ if the last deploy failed,
    /// ● deployed if a version was recorded, ○ otherwise.
    private func status(for host: RemoteHostConfig) -> HostStatus {
        if deployFailed.contains(host.name) { return .deployFailed }
        if host.deployedAt != nil { return .deployed }
        return .notDeployed
    }
}

private enum HostStatus {
    case deployed
    case notDeployed
    case deployFailed

    var symbol: String {
        switch self {
        case .deployed:     return "●"
        case .notDeployed:  return "○"
        case .deployFailed: return "⚠"
        }
    }
    var color: Color {
        switch self {
        case .deployed:     return .green
        case .notDeployed:  return .secondary
        case .deployFailed: return .orange
        }
    }
    var help: String {
        switch self {
        case .deployed:     return "Daemon deployed"
        case .notDeployed:  return "Not deployed yet"
        case .deployFailed: return "Last deploy failed — redeploy to retry"
        }
    }
}

private struct HostRow: View {
    let host: RemoteHostConfig
    let status: HostStatus
    let onToggleEnabled: (Bool) -> Void
    let onChange: (RemoteHostConfig) -> Void
    let onRedeploy: () -> Void
    let onRemove: () -> Void

    @State private var expanded = false
    @State private var pollText: String = ""
    @State private var collectUsage: Bool = true
    /// Finding 4 (round 2): the pollSeconds value pollText was last seeded from.
    /// Used to skip re-seeding pollText when a host change touched only another
    /// field (e.g. the collectUsage toggle persisting) — otherwise seedFromHost
    /// would discard an in-progress, not-yet-submitted poll edit.
    @State private var lastSeededPoll: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(status.symbol)
                    .foregroundColor(status.color)
                    .help(status.help)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).fontWeight(.medium)
                    Text(host.ssh).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { host.enabled },
                    set: { onToggleEnabled($0) }
                ))
                .labelsHidden()
                .help("Enable syncing this host's sessions")
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }

            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Poll interval (s)").font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            TextField("30", text: $pollText)
                                .frame(width: 60)
                                .onSubmit { persist() }
                            // Finding 4: the daemon floors poll interval at 10s
                            // (Python silently resets anything < 10 to 30), so
                            // flag sub-10 input rather than persisting a value
                            // the daemon will quietly override.
                            if let poll = Int(pollText), poll < 10 {
                                Text("minimum 10s").font(.caption2).foregroundColor(.red)
                            }
                        }
                    }
                    GridRow {
                        Text("Collect usage").font(.caption)
                        Toggle("", isOn: $collectUsage)
                            .labelsHidden()
                            .onChange(of: collectUsage) { _ in persist() }
                    }
                }
                HStack {
                    Button("Redeploy", action: onRedeploy)
                    Button("Remove", role: .destructive, action: onRemove)
                    Spacer()
                    if let version = host.deployedVersion {
                        Text("v\(version.prefix(10))").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .onAppear { seedFromHost() }
        // Finding 4: pollText/collectUsage were seeded only in onAppear, so if
        // the host entry changed underneath the row while it stayed on screen
        // (e.g. a deploy stamped deployed_version, or an external config edit)
        // the fields kept showing the stale seed. Re-seed whenever the host
        // value changes. RemoteHostConfig is Equatable, so this only fires on
        // an actual change.
        .onChange(of: host) { _ in seedFromHost() }
    }

    private func seedFromHost() {
        // Finding 4 (round 2): only re-seed pollText when pollSeconds itself
        // changed. pollText commits on submit (not per-keystroke), so an
        // unsubmitted value is live editing — a host change from another field
        // (collectUsage toggle, deploy stamping version) must not overwrite it.
        if host.pollSeconds != lastSeededPoll {
            pollText = String(host.pollSeconds)
            lastSeededPoll = host.pollSeconds
        }
        collectUsage = host.collectUsage
    }

    private func persist() {
        var updated = host
        // Finding 4: enforce the daemon's 10s floor here so config.json never
        // carries a sub-10 interval (which the daemon would silently reset to
        // 30). Only persist a valid, in-range value; a below-floor entry is
        // flagged inline and left unsaved until corrected.
        if let poll = Int(pollText), poll >= 10 { updated.pollSeconds = poll }
        updated.collectUsage = collectUsage
        onChange(updated)
    }
}

// MARK: - Add Host sheet

struct AddHostSheet: View {
    @ObservedObject var configStore: ConfigStore
    let existingNames: Set<String>
    /// (name, succeeded) reported to the parent so it can track ⚠ status.
    let onFinished: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var deployer = HostDeployer()

    @State private var name = ""
    @State private var ssh = ""
    @State private var testMessage: String?
    @State private var testOK: Bool?
    @State private var testing = false
    @State private var started = false

    // Finding 3: validate (and later save) the TRIMMED name/ssh. Python
    // stores state under the cleaned name and resolveHostSSH matches it
    // exactly, so an untrimmed " devbox " here would (a) slip past the
    // duplicate-name check against the already-cleaned existingNames and
    // (b) diverge from the daemon's key, breaking host resolution.
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedSSH: String { ssh.trimmingCharacters(in: .whitespaces) }

    private var nameValid: Bool {
        !trimmedName.isEmpty
            && !trimmedName.contains(":")
            && !existingNames.contains(trimmedName)
    }
    private var canSave: Bool {
        nameValid && !trimmedSSH.isEmpty && !deployer.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Remote Host").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("devbox", text: $name)
                        if !name.isEmpty && !nameValid {
                            Text(trimmedName.contains(":") ? "no “:” allowed in a host name"
                                 : (existingNames.contains(trimmedName) ? "a host with this name already exists" : "required"))
                                .font(.caption).foregroundColor(.red)
                        }
                    }
                }
                GridRow {
                    Text("SSH target")
                    TextField("sam@devbox or an ~/.ssh/config alias", text: $ssh)
                }
            }

            HStack {
                Button("Test Connection") { runTest() }
                    .disabled(ssh.trimmingCharacters(in: .whitespaces).isEmpty || testing || deployer.isRunning)
                if testing { ProgressView().controlSize(.small) }
                if let msg = testMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(testOK == true ? .green : .red)
                }
            }

            if started {
                DeployProgressView(deployer: deployer)
            }

            HStack {
                Button("Cancel") {
                    deployer.cancel()
                    dismiss()
                }
                Spacer()
                Button(deployer.phase == .succeeded ? "Done" : "Save & Deploy") {
                    if deployer.phase == .succeeded {
                        dismiss()
                    } else {
                        save()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave && deployer.phase != .succeeded)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Finding 3: cancel any in-flight deploy if the sheet goes away by any
        // route (Escape, click-outside, app quit), not just the Cancel button —
        // otherwise the Process is orphaned and its read handler keeps firing.
        .onDisappear { deployer.cancel() }
    }

    private func runTest() {
        testing = true
        testMessage = nil
        testOK = nil
        HostDeployer.testConnection(target: ssh) { ok, message in
            testing = false
            testOK = ok
            testMessage = ok ? "Connected." : message
        }
    }

    private func save() {
        // Finding 3: persist and deploy against the trimmed values so the
        // config key, the deploy target, and the daemon's cleaned state key
        // all agree.
        let cleanName = trimmedName
        let cleanSSH = trimmedSSH
        let host = RemoteHostConfig.defaults(name: cleanName, ssh: cleanSSH)
        // Save disabled first so a failed deploy still leaves a record the
        // user can retry from; a successful deploy re-records it enabled.
        configStore.upsertHost(host)
        started = true
        deployer.deploy(target: cleanSSH) { succeeded, version in
            if succeeded {
                let stamp = ISO8601DateFormatter().string(from: Date())
                configStore.recordDeployment(named: cleanName, deployedAt: stamp, version: version, enable: true)
            }
            onFinished(cleanName, succeeded)
        }
    }
}

// MARK: - Redeploy sheet

struct RedeploySheet: View {
    @ObservedObject var configStore: ConfigStore
    let host: RemoteHostConfig
    let onFinished: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var deployer = HostDeployer()
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Redeploy \(host.name)").font(.headline)
            Text(host.ssh).font(.caption).foregroundColor(.secondary)

            if started {
                DeployProgressView(deployer: deployer)
            } else {
                Text("Re-copies the daemon files and restarts the service on this host.")
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Button("Close") {
                    deployer.cancel()
                    dismiss()
                }
                Spacer()
                Button(started ? (deployer.phase == .succeeded ? "Done" : "Redeploy") : "Redeploy") {
                    if deployer.phase == .succeeded {
                        dismiss()
                    } else {
                        run()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(deployer.isRunning)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Finding 3: cancel an in-flight redeploy on any dismissal route.
        .onDisappear { deployer.cancel() }
    }

    private func run() {
        started = true
        deployer.deploy(target: host.ssh) { succeeded, version in
            if succeeded {
                let stamp = ISO8601DateFormatter().string(from: Date())
                configStore.recordDeployment(named: host.name, deployedAt: stamp, version: version, enable: true)
            }
            onFinished(succeeded)
        }
    }
}

// MARK: - Remove host sheet

struct RemoveHostSheet: View {
    @ObservedObject var configStore: ConfigStore
    let host: RemoteHostConfig

    @Environment(\.dismiss) private var dismiss
    @StateObject private var deployer = HostDeployer()
    @State private var alsoUninstall = false
    @State private var uninstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove \(host.name)?").font(.headline)
            Text("Stops syncing this host and removes it from the widget's config.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("Also stop & remove the daemon on the host", isOn: $alsoUninstall)
                .help("Runs deploy_remote.sh --uninstall over SSH — leaves the remote's state and transcripts untouched")

            if uninstalling {
                DeployProgressView(deployer: deployer)
            }

            HStack {
                Button("Cancel") {
                    deployer.cancel()
                    dismiss()
                }
                Spacer()
                Button("Remove", role: .destructive) { remove() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(deployer.isRunning)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Finding 3: cancel an in-flight uninstall on any dismissal route.
        .onDisappear { deployer.cancel() }
    }

    private func remove() {
        if alsoUninstall {
            uninstalling = true
            deployer.uninstall(target: host.ssh) { _, _ in
                // Remove from config regardless of uninstall outcome — the
                // user asked to remove the host; a failed remote uninstall is
                // surfaced in the log but shouldn't block dropping the entry.
                configStore.removeHost(named: host.name)
                dismiss()
            }
        } else {
            configStore.removeHost(named: host.name)
            dismiss()
        }
    }
}

// MARK: - Deploy progress (checklist + log), shared by all three sheets

struct DeployProgressView: View {
    @ObservedObject var deployer: HostDeployer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if deployer.isRunning { ProgressView().controlSize(.small) }
                Text(phaseLabel).font(.subheadline).fontWeight(.medium)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(deployer.steps) { step in
                    HStack(spacing: 6) {
                        Text(symbol(for: step.status))
                            .foregroundColor(color(for: step.status))
                            .frame(width: 14)
                        Text(step.label)
                            .font(.caption)
                            .foregroundColor(step.status == .pending ? .secondary : .primary)
                    }
                }
            }

            if let reason = deployer.failReason {
                Text(reason).font(.caption).foregroundColor(.red)
            }
            ForEach(Array(deployer.hints.enumerated()), id: \.offset) { _, hint in
                Text("• \(hint)").font(.caption).foregroundColor(.secondary)
            }

            if !deployer.logText.isEmpty {
                DisclosureGroup("Log") {
                    ScrollView {
                        Text(deployer.logText)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
                }
            }
        }
    }

    private var phaseLabel: String {
        switch deployer.phase {
        case .idle:      return "Ready"
        case .running:   return "Deploying…"
        case .succeeded: return "Deployed"
        case .failed:    return "Deploy failed"
        }
    }

    private func symbol(for status: DeployStepStatus) -> String {
        switch status {
        case .pending: return "○"
        case .active:  return "◔"
        case .done:    return "✓"
        case .failed:  return "✗"
        }
    }
    private func color(for status: DeployStepStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .active:  return .accentColor
        case .done:    return .green
        case .failed:  return .red
        }
    }
}
