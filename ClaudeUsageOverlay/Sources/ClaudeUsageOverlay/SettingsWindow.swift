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

private let weekdayOptions = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

struct AccountBudgetSection: View {
    @ObservedObject var configStore: ConfigStore

    @State private var accountChoice: AccountChoice = .max20x
    @State private var weeklyText: String = ""
    @State private var monthlyText: String = ""
    @State private var weekStart: String = "monday"
    @State private var seeded = false

    private var weeklyValid: Bool { Self.isValidBudget(weeklyText) }
    private var monthlyValid: Bool { Self.isValidBudget(monthlyText) }

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
            .onChange(of: accountChoice) { _ in persistAccount() }

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
                            .onChange(of: weeklyText) { _ in persistBudget() }
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
                            .onChange(of: monthlyText) { _ in persistBudget() }
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
                    .onChange(of: weekStart) { _ in persistBudget() }
                }
            }

            Text(accountChoice == .api
                 ? "On API accounts the main tab shows dollar budget bars instead of the Max session/weekly percentages."
                 : "Budgets are saved but the main tab shows Max session/weekly percentages for this account type.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear(perform: seedFromConfig)
    }

    private func seedFromConfig() {
        guard !seeded else { return }
        seeded = true
        let c = configStore.config
        accountChoice = AccountChoice.from(config: c)
        weeklyText = c.weeklyUsd.map { Self.formatBudget($0) } ?? ""
        monthlyText = c.monthlyUsd.map { Self.formatBudget($0) } ?? ""
        weekStart = c.weekStart
    }

    private func persistAccount() {
        let (type, plan) = accountChoice.typeAndPlan(preservingPlan: configStore.config.accountPlan)
        configStore.setAccount(type: type, plan: plan)
    }

    private func persistBudget() {
        // Empty ⇒ nil (unconfigured). Invalid partial input ⇒ don't persist
        // this keystroke; the red caption already flags it and a later valid
        // edit saves.
        let weekly = weeklyText.isEmpty ? nil : Double(weeklyText)
        let monthly = monthlyText.isEmpty ? nil : Double(monthlyText)
        if (!weeklyText.isEmpty && weekly == nil) || (!monthlyText.isEmpty && monthly == nil) {
            return
        }
        configStore.setBudget(weeklyUsd: weekly, monthlyUsd: monthly,
                              weekStart: weekStart, timezone: configStore.config.timezone)
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
                        TextField("30", text: $pollText)
                            .frame(width: 60)
                            .onSubmit { persist() }
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
        .onAppear {
            pollText = String(host.pollSeconds)
            collectUsage = host.collectUsage
        }
    }

    private func persist() {
        var updated = host
        if let poll = Int(pollText), poll > 0 { updated.pollSeconds = poll }
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

    private var nameValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.contains(":")
            && !existingNames.contains(name)
    }
    private var canSave: Bool {
        nameValid && !ssh.trimmingCharacters(in: .whitespaces).isEmpty && !deployer.isRunning
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
                            Text(name.contains(":") ? "no “:” allowed in a host name"
                                 : (existingNames.contains(name) ? "a host with this name already exists" : "required"))
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
        let host = RemoteHostConfig.defaults(name: name, ssh: ssh)
        // Save disabled first so a failed deploy still leaves a record the
        // user can retry from; a successful deploy re-records it enabled.
        configStore.upsertHost(host)
        started = true
        deployer.deploy(target: ssh) { succeeded, version in
            if succeeded {
                let stamp = ISO8601DateFormatter().string(from: Date())
                configStore.recordDeployment(named: name, deployedAt: stamp, version: version, enable: true)
            }
            onFinished(name, succeeded)
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
                        Text(step.kind.label)
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
