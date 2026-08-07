import Foundation
@testable import ClaudeAPI

/// A `ClaudeScriptRunner` that never touches WebKit or the network: it hands
/// back a canned value for each `run(script:)` call. This is the whole point
/// of the transport seam (audit §1.10) — before it, nothing in
/// ClaudeAPIClient could be exercised without a live, logged-in webview.
final class FakeScriptRunner: ClaudeScriptRunner {
    /// Queued results, consumed in order. When exhausted, `lastResponse` (or
    /// the final queued entry) is replayed, so a test that only cares about
    /// one call doesn't have to enumerate them.
    private var queue: [Result<Any, Error>]
    private var lastResponse: Result<Any, Error>

    /// Every script this runner was asked to evaluate, in order.
    private(set) var scripts: [String] = []
    private(set) var installedKeys: [String] = []
    private(set) var resetCount = 0
    /// What `installSessionKey` reports back.
    var installResult = true

    init(_ response: Result<Any, Error>) {
        self.queue = []
        self.lastResponse = response
    }

    /// Canned response parsed from a JSON literal — i.e. exactly the
    /// Foundation types `JSONSerialization` produces on this platform.
    convenience init(json: String) {
        self.init(.success(FakeScriptRunner.parse(json)))
    }

    /// Canned response built from *native Swift* scalars (Bool/Int/Double/
    /// String), which is what the newer swift-foundation JSON core produces
    /// off Darwin. Decoding must behave identically to the parsed form.
    convenience init(native: [String: Any]) {
        self.init(.success(native))
    }

    convenience init(failure: Error) {
        self.init(.failure(failure))
    }

    func enqueue(_ response: Result<Any, Error>) {
        queue.append(response)
        lastResponse = response
    }

    static func parse(_ json: String) -> Any {
        // Force-try is deliberate: a malformed literal is a broken test, and
        // failing loudly at the source beats a confusing decode assertion.
        try! JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    // MARK: ClaudeScriptRunner

    func run(script: String, completion: @escaping (Result<Any, Error>) -> Void) {
        scripts.append(script)
        let response = queue.isEmpty ? lastResponse : queue.removeFirst()
        completion(response)
    }

    func installSessionKey(_ pasted: String, completion: @escaping (Bool) -> Void) {
        installedKeys.append(pasted)
        completion(installResult)
    }

    func resetSession(completion: @escaping () -> Void) {
        resetCount += 1
        completion()
    }
}
