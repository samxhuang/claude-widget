import Foundation
import Combine
import Darwin

/// One remote host entry from config.json's `remote_hosts` array (contract
/// C1). The daemon reads these to know which hosts to sync; the widget is the
/// only writer. `deployedAt`/`deployedVersion` are stamped by HostDeployer on
/// a successful `@@OK` deploy and left nil until then.
struct RemoteHostConfig: Identifiable, Equatable {
    var name: String
    var ssh: String
    var enabled: Bool
    var python: String
    var stateDir: String
    var pollSeconds: Int
    var collectUsage: Bool
    var deployedAt: String?
    var deployedVersion: String?

    /// Host names are unique (validated on save) and can't contain `:`
    /// (they're used as the `<host>::<sid>` state.json key prefix, contract
    /// C3), so the name is a stable identity.
    var id: String { name }

    static func defaults(name: String, ssh: String) -> RemoteHostConfig {
        RemoteHostConfig(
            name: name, ssh: ssh, enabled: false,
            python: "python3", stateDir: "~/.claude-autoresume",
            pollSeconds: 30, collectUsage: true,
            deployedAt: nil, deployedVersion: nil
        )
    }
}

/// Typed, fully-defaulted view of config.json (contract C1). A missing or
/// malformed file decodes to these defaults, which are exactly today's
/// behavior (Max 20x, no budget, no remote hosts) — the widget never has to
/// special-case "no config yet".
struct AppConfig: Equatable {
    var version: Int = 1
    var accountType: String = "max"     // "max" | "api"
    var accountPlan: String = "max_20x" // "pro" | "max_5x" | "max_20x"
    var weeklyUsd: Double?
    var monthlyUsd: Double?
    var weekStart: String = "monday"
    var timezone: String = "local"
    var remoteHosts: [RemoteHostConfig] = []

    var isApiAccount: Bool { accountType == "api" }
}

/// Sole writer of `~/.claude-autoresume/config.json` (contract C1). Every
/// mutation is a read-modify-write under a `config.json.lock` flock, atomic
/// tmp + `replaceItemAt`, preserving any JSON keys this build doesn't know
/// about — the daemon and plan_fit.py are readers, and hand-editing must keep
/// working even though the Settings window is the only intended writer.
///
/// The flock/inode discipline here is copied VERBATIM from
/// SessionsModel.withLock (see its S1 comment): `open(O_RDWR | O_CREAT)` on
/// the lock file, never `FileManager.createFile`, because createFile replaces
/// the lock file's inode on every call and flock is per-inode — a widget
/// write racing a daemon read would then lock different inodes and exclude
/// nothing. All locked I/O runs off the main thread on a private serial
/// queue, published back on main, same as SessionsModel post-audit.
final class ConfigStore: ObservableObject {
    /// The current decoded config, republished on main after every load/write.
    @Published var config = AppConfig()

    private let configURL: URL
    private let lockURL: URL
    private let tmpURL: URL

    /// S2 (mirrored): every locked read-modify-write runs here, off the main
    /// thread and serially, so a `mutate` enqueued immediately before a
    /// dependent read runs first.
    private let ioQueue = DispatchQueue(label: "com.claude-widget.config-io")

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-autoresume")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.configURL = dir.appendingPathComponent("config.json")
        self.lockURL = dir.appendingPathComponent("config.json.lock")
        self.tmpURL = configURL.appendingPathExtension("tmp")
        load()
    }

    // MARK: - Load

    /// Re-reads config.json and republishes `config`. A missing/unparsable
    /// file publishes full defaults (today's behavior) rather than an error.
    func load() {
        withLock { [weak self] in
            guard let self = self else { return }
            let decoded = Self.decode(self.readRaw())
            DispatchQueue.main.async { self.config = decoded }
        }
    }

    // MARK: - Mutations (typed setters, each a locked read-modify-write)

    /// Account type + plan. For "api" the plan is still stored (plan_fit.py
    /// uses it for the tier-comparison ratio even on API accounts).
    func setAccount(type: String, plan: String) {
        mutate { root in
            var account = (root["account"] as? [String: Any]) ?? [:]
            account["type"] = type
            account["plan"] = plan
            root["account"] = account
        }
    }

    /// Budget dollar limits + period definition. `nil` clears a period's
    /// limit (stored as JSON null so the daemon distinguishes "unconfigured"
    /// from "0"). Non-positive values are treated as nil (validator: budgets
    /// numeric > 0 else null, matching WS-0's config module).
    func setBudget(weeklyUsd: Double?, monthlyUsd: Double?, weekStart: String, timezone: String) {
        mutate { root in
            var budget = (root["budget"] as? [String: Any]) ?? [:]
            budget["weekly_usd"] = Self.sanitizedBudget(weeklyUsd) ?? NSNull()
            budget["monthly_usd"] = Self.sanitizedBudget(monthlyUsd) ?? NSNull()
            budget["week_start"] = weekStart
            budget["timezone"] = timezone
            root["budget"] = budget
        }
    }

    /// Inserts a new host or updates an existing one (matched by name),
    /// merging over any unknown per-host keys the current on-disk entry has.
    func upsertHost(_ host: RemoteHostConfig) {
        mutate { root in
            var hosts = (root["remote_hosts"] as? [[String: Any]]) ?? []
            var merged = Self.hostDict(host)
            if let idx = hosts.firstIndex(where: { ($0["name"] as? String) == host.name }) {
                // Preserve unknown per-host keys the config already carries.
                var existing = hosts[idx]
                for (k, v) in merged { existing[k] = v }
                hosts[idx] = existing
            } else {
                merged["name"] = host.name
                hosts.append(merged)
            }
            root["remote_hosts"] = hosts
        }
    }

    func removeHost(named name: String) {
        mutate { root in
            var hosts = (root["remote_hosts"] as? [[String: Any]]) ?? []
            hosts.removeAll { ($0["name"] as? String) == name }
            root["remote_hosts"] = hosts
        }
    }

    func setHostEnabled(named name: String, _ enabled: Bool) {
        mutateHost(named: name) { $0["enabled"] = enabled }
    }

    /// Stamps a host's config entry after a successful deploy (contract:
    /// HostDeployer writes deployed_at/deployed_version on `@@OK` and enables
    /// the host). Kept as one atomic write so a partial stamp can't happen.
    func recordDeployment(named name: String, deployedAt: String, version: String?, enable: Bool) {
        mutateHost(named: name) { host in
            host["deployed_at"] = deployedAt
            if let version = version { host["deployed_version"] = version }
            if enable { host["enabled"] = true }
        }
    }

    // MARK: - Locked read-modify-write

    /// The single mutation primitive: read the raw dict off disk under the
    /// flock, apply `change` (which sees and can preserve every unknown key),
    /// write it back atomically, then re-decode and republish. Reading fresh
    /// off disk each time — rather than editing the in-memory `config` — is
    /// what preserves keys written by the daemon or a hand-edit between our
    /// own writes.
    private func mutate(_ change: @escaping (inout [String: Any]) -> Void) {
        withLock { [weak self] in
            guard let self = self else { return }
            var root = self.readRaw()
            if root["version"] == nil { root["version"] = 1 }
            change(&root)
            self.writeRaw(root)
            let decoded = Self.decode(root)
            DispatchQueue.main.async { self.config = decoded }
        }
    }

    /// Convenience wrapper for a single-host mutation that no-ops (rather than
    /// creating a phantom entry) when the named host isn't present — a host
    /// removed in a racing write shouldn't be resurrected by a late toggle.
    private func mutateHost(named name: String, _ change: @escaping (inout [String: Any]) -> Void) {
        mutate { root in
            var hosts = (root["remote_hosts"] as? [[String: Any]]) ?? []
            guard let idx = hosts.firstIndex(where: { ($0["name"] as? String) == name }) else { return }
            var host = hosts[idx]
            change(&host)
            hosts[idx] = host
            root["remote_hosts"] = hosts
        }
    }

    /// Reads and JSON-parses config.json. Called only while holding the lock.
    /// Returns an empty dict on any failure — decode() then fills defaults.
    private func readRaw() -> [String: Any] {
        guard let raw = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// Atomic tmp + replaceItemAt write. Called only while holding the lock.
    private func writeRaw(_ root: [String: Any]) {
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            NSLog("[ConfigStore] serialize failed")
            return
        }
        do {
            try out.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
        } catch {
            NSLog("[ConfigStore] write failed: %@", error.localizedDescription)
        }
    }

    /// See SessionsModel.withLock's S1 comment — this is that pattern
    /// verbatim: `open(O_RDWR | O_CREAT)` (never FileManager.createFile, which
    /// would replace the lock file's inode and defeat cross-process flock),
    /// LOCK_EX, run the body, unlock, close.
    private func withLock(_ body: @escaping () -> Void) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fd = open(self.lockURL.path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else { body(); return }
            flock(fd, LOCK_EX)
            body()
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    // MARK: - Encode / decode

    private static func sanitizedBudget(_ value: Double?) -> Double? {
        guard let v = value, v.isFinite, v > 0 else { return nil }
        return v
    }

    private static func hostDict(_ host: RemoteHostConfig) -> [String: Any] {
        var d: [String: Any] = [
            "name": host.name,
            "ssh": host.ssh,
            "enabled": host.enabled,
            "python": host.python,
            "state_dir": host.stateDir,
            "poll_seconds": host.pollSeconds,
            "collect_usage": host.collectUsage
        ]
        if let deployedAt = host.deployedAt { d["deployed_at"] = deployedAt }
        if let version = host.deployedVersion { d["deployed_version"] = version }
        return d
    }

    private static func decode(_ root: [String: Any]) -> AppConfig {
        var c = AppConfig()
        if let version = root["version"] as? Int { c.version = version }
        if let account = root["account"] as? [String: Any] {
            if let type = account["type"] as? String { c.accountType = type }
            if let plan = account["plan"] as? String { c.accountPlan = plan }
        }
        if let budget = root["budget"] as? [String: Any] {
            c.weeklyUsd = (budget["weekly_usd"] as? NSNumber)?.doubleValue
            c.monthlyUsd = (budget["monthly_usd"] as? NSNumber)?.doubleValue
            if let ws = budget["week_start"] as? String { c.weekStart = ws }
            if let tz = budget["timezone"] as? String { c.timezone = tz }
        }
        if let hosts = root["remote_hosts"] as? [[String: Any]] {
            c.remoteHosts = hosts.compactMap { h in
                guard let name = h["name"] as? String, let ssh = h["ssh"] as? String else { return nil }
                return RemoteHostConfig(
                    name: name,
                    ssh: ssh,
                    enabled: h["enabled"] as? Bool ?? false,
                    python: h["python"] as? String ?? "python3",
                    stateDir: h["state_dir"] as? String ?? "~/.claude-autoresume",
                    pollSeconds: (h["poll_seconds"] as? NSNumber)?.intValue ?? 30,
                    collectUsage: h["collect_usage"] as? Bool ?? true,
                    deployedAt: h["deployed_at"] as? String,
                    deployedVersion: h["deployed_version"] as? String
                )
            }
        }
        return c
    }
}
