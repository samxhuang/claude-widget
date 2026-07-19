import Foundation
import Combine

/// The six deploy stages the WS-3 `deploy_remote.sh` marker contract emits,
/// in order. The script prints `@@STEP:<name>` at the start of each; this
/// enum drives the checklist the Add Host sheet shows so the user can see
/// where a deploy is (or where it stalled).
enum DeployStepKind: String, CaseIterable {
    case connect
    case python
    case copy
    case service
    case start
    case verify

    var label: String {
        switch self {
        case .connect: return "Connect over SSH"
        case .python:  return "Check python3"
        case .copy:    return "Copy daemon files"
        case .service: return "Install service"
        case .start:   return "Start daemon"
        case .verify:  return "Verify (remote_ctl dump)"
        }
    }
}

enum DeployStepStatus {
    case pending
    case active
    case done
    case failed
}

struct DeployStep: Identifiable {
    let kind: DeployStepKind
    var status: DeployStepStatus
    var id: String { kind.rawValue }
}

enum DeployPhase {
    case idle
    case running
    case succeeded
    case failed
}

/// Runs `deploy_remote.sh <target>` (the WS-3 remote-deploy script) via
/// `Process`, streams its stdout/stderr into a log the Add Host sheet shows,
/// and parses the machine-readable marker lines (`@@STEP:<name>`, `@@OK
/// version=<hash>`, `@@FAIL:<reason>`) into a step checklist + terminal
/// success/failure. Same machinery backs Add Host, Redeploy, and
/// Remove-with-uninstall (the latter passes `--uninstall`).
///
/// This class deliberately does NOT read the script's contents or know
/// anything about ssh — it's built strictly against the marker contract, so
/// WS-3 can finish the script in parallel. On success it reports the version
/// hash back through `onComplete`; the caller (SettingsWindow) owns the
/// resulting config.json write (stamp deployed_at/version + enable on OK,
/// leave disabled on failure).
final class HostDeployer: ObservableObject {
    @Published var phase: DeployPhase = .idle
    @Published var steps: [DeployStep] = DeployStepKind.allCases.map { DeployStep(kind: $0, status: .pending) }
    @Published var logText: String = ""
    /// The `@@FAIL:<reason>` short reason, or a synthesized one when the
    /// script couldn't be found / launched.
    @Published var failReason: String?
    /// Plain-language hints derived from the failure reason (no key-based ssh
    /// auth, python too old, `claude` missing on remote) — shown under the
    /// error so the user can act without reading the raw log.
    @Published var hints: [String] = []
    /// The `version=<hash>` from the `@@OK` line, passed to the config write.
    @Published var deployedVersion: String?

    private var process: Process?
    private var stdoutBuffer = Data()
    private var lineRemainder = ""

    var isRunning: Bool { phase == .running }

    // MARK: - Public entry points

    /// Deploy (or redeploy) the daemon to `target` (a `user@host` or
    /// `~/.ssh/config` alias). `onComplete(success, version)` fires on the
    /// main thread when the run terminates.
    func deploy(target: String, onComplete: @escaping (Bool, String?) -> Void) {
        run(target: target, uninstall: false, onComplete: onComplete)
    }

    /// Stop & remove the remote daemon via `deploy_remote.sh <target>
    /// --uninstall`. Leaves remote state/transcripts untouched (per WS-3).
    func uninstall(target: String, onComplete: @escaping (Bool, String?) -> Void) {
        run(target: target, uninstall: true, onComplete: onComplete)
    }

    // MARK: - Process plumbing

    private func run(target: String, uninstall: Bool, onComplete: @escaping (Bool, String?) -> Void) {
        // Reset per-run state.
        phase = .running
        steps = DeployStepKind.allCases.map { DeployStep(kind: $0, status: .pending) }
        logText = ""
        failReason = nil
        hints = []
        deployedVersion = nil
        stdoutBuffer = Data()
        lineRemainder = ""

        guard let scriptPath = Self.resolveScriptPath() else {
            // Neither the installed copy nor a repo copy exists — the daemon
            // side hasn't been installed yet.
            phase = .failed
            failReason = "deploy_remote.sh not found"
            appendLog("deploy_remote.sh not found in ~/.claude-autoresume/bin or the repo.\nRun claude-autoresume/install.sh first.")
            hints = ["Run claude-autoresume/install.sh to install the deploy script locally, then try again."]
            onComplete(false, nil)
            return
        }

        var args = [target]
        if uninstall { args.append("--uninstall") }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath] + args
        // The script shells out to ssh/scp/python; make sure the usual tool
        // locations are on PATH regardless of the (accessory app's) inherited
        // environment.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? extraPaths
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.finish(exitCode: p.terminationStatus, onComplete: onComplete)
            }
        }

        self.process = proc
        do {
            try proc.run()
        } catch {
            phase = .failed
            failReason = "could not launch deploy script"
            appendLog("Failed to launch deploy_remote.sh: \(error.localizedDescription)")
            onComplete(false, nil)
        }
    }

    /// Cancels an in-flight run (e.g. the sheet was dismissed). Safe to call
    /// when nothing is running.
    func cancel() {
        process?.terminationHandler = nil
        process?.interrupt()
        process = nil
        if phase == .running { phase = .idle }
    }

    // MARK: - Streaming + marker parsing

    private func ingest(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let combined = self.lineRemainder + chunk
            var lines = combined.components(separatedBy: "\n")
            // Last element is a partial line (no trailing newline yet) — hold
            // it back until the rest of it arrives, so a marker split across
            // two reads still parses correctly.
            self.lineRemainder = lines.removeLast()
            for line in lines {
                self.handleLine(line)
            }
        }
    }

    /// Parses one complete line. Marker lines (`@@…`) drive the checklist and
    /// terminal state; everything else is human-readable detail appended to
    /// the log verbatim.
    private func handleLine(_ line: String) {
        appendLog(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@@STEP:") {
            let name = String(trimmed.dropFirst("@@STEP:".count)).trimmingCharacters(in: .whitespaces)
            if let kind = DeployStepKind(rawValue: name) {
                markStepActive(kind)
            }
        } else if trimmed.hasPrefix("@@OK") {
            // "@@OK version=<hash>"
            if let range = trimmed.range(of: "version=") {
                let v = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { deployedVersion = v }
            }
            markAllStepsDone()
        } else if trimmed.hasPrefix("@@FAIL:") {
            let reason = String(trimmed.dropFirst("@@FAIL:".count)).trimmingCharacters(in: .whitespaces)
            failReason = reason.isEmpty ? "deploy failed" : reason
            markActiveStepFailed()
        }
    }

    /// Marks `kind` active and every earlier step done — the script emits a
    /// step marker only at each stage's START, so reaching stage N implies the
    /// prior ones succeeded.
    private func markStepActive(_ kind: DeployStepKind) {
        guard let idx = steps.firstIndex(where: { $0.kind == kind }) else { return }
        for i in steps.indices {
            if i < idx {
                if steps[i].status != .failed { steps[i].status = .done }
            } else if i == idx {
                steps[i].status = .active
            }
        }
    }

    private func markAllStepsDone() {
        for i in steps.indices where steps[i].status != .failed {
            steps[i].status = .done
        }
    }

    private func markActiveStepFailed() {
        if let idx = steps.firstIndex(where: { $0.status == .active }) {
            steps[idx].status = .failed
        } else if let idx = steps.lastIndex(where: { $0.status != .done }) {
            // No step was active yet (failed at/before connect) — flag the
            // first not-done step so the checklist still shows where it died.
            steps[idx].status = .failed
        }
    }

    private func finish(exitCode: Int32, onComplete: @escaping (Bool, String?) -> Void) {
        // Flush any trailing partial line the stream never newline-terminated.
        if !lineRemainder.isEmpty {
            handleLine(lineRemainder)
            lineRemainder = ""
        }
        // Exit code mirrors OK/FAIL per the contract, but treat a seen `@@OK`
        // as authoritative in case the two ever disagree.
        let succeeded = (exitCode == 0) && (failReason == nil)
        if succeeded {
            phase = .succeeded
            markAllStepsDone()
        } else {
            phase = .failed
            if failReason == nil {
                failReason = "deploy exited with code \(exitCode)"
            }
            markActiveStepFailed()
            hints = Self.hints(for: failReason ?? "", log: logText)
        }
        process = nil
        onComplete(succeeded, deployedVersion)
    }

    private func appendLog(_ line: String) {
        if !logText.isEmpty { logText += "\n" }
        logText += line
    }

    // MARK: - Connection test (Add Host sheet's pre-flight)

    /// Non-interactive ssh reachability probe for the Add Host sheet's "Test
    /// Connection" button — the same BatchMode/ConnectTimeout discipline the
    /// deploy and the daemon's sync use (contract C4), so a green here means
    /// key-based auth is actually set up. `completion(ok, message)` fires on
    /// the main thread.
    static func testConnection(target: String, completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                target, "true"
            ]
            var env = ProcessInfo.processInfo.environment
            let extraPaths = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
            env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? extraPaths
            proc.environment = env
            let pipe = Pipe()
            proc.standardError = pipe
            proc.standardOutput = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                DispatchQueue.main.async { completion(false, "could not launch ssh: \(error.localizedDescription)") }
                return
            }
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.async {
                completion(ok, ok ? nil : (errText.isEmpty ? "connection failed (exit \(proc.terminationStatus))" : errText))
            }
        }
    }

    // MARK: - Script resolution + hints

    /// Prefers the installed copy (`install.sh` puts it in
    /// `~/.claude-autoresume/bin/`); falls back to a repo copy found by
    /// walking up from the running executable's bundle. Returns nil when
    /// neither exists (caller shows "run install.sh first").
    private static func resolveScriptPath() -> String? {
        let fm = FileManager.default
        let installed = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-autoresume")
            .appendingPathComponent("bin")
            .appendingPathComponent("deploy_remote.sh")
        if fm.isReadableFile(atPath: installed.path) { return installed.path }

        // Repo fallback: walk up from the executable/bundle location looking
        // for claude-autoresume/deploy_remote.sh (dev builds run out of the
        // repo tree via build_and_run.command).
        var dir = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("claude-autoresume")
                .appendingPathComponent("deploy_remote.sh")
            if fm.isReadableFile(atPath: candidate.path) { return candidate.path }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Maps a failure reason (and, as a fallback, the raw log) to
    /// plain-language remedies for the three common deploy failures.
    private static func hints(for reason: String, log: String) -> [String] {
        let haystack = (reason + " " + log).lowercased()
        var out: [String] = []
        if haystack.contains("auth") || haystack.contains("permission denied")
            || haystack.contains("publickey") || haystack.contains("connect") {
            out.append("SSH couldn't authenticate non-interactively. Set up key-based ssh to this host (ssh-copy-id) — the deploy never prompts for a password.")
        }
        if haystack.contains("python") {
            out.append("The remote python3 is missing or too old (need ≥ 3.9). Install a newer python3 on the host.")
        }
        if haystack.contains("claude") && haystack.contains("not") {
            out.append("`claude` isn't on the remote host's PATH. Install Claude Code there so the daemon can resume sessions.")
        }
        if out.isEmpty && !reason.isEmpty {
            out.append(reason)
        }
        return out
    }
}
