import Foundation
import Testing
@testable import ClaudeAPI

/// Drives ClaudeAPIClient end-to-end through a fake transport: success,
/// loggedOut, HTTP error, malformed envelope, backlog-full, plus the
/// decoders. Completions fire synchronously from the fake, so no
/// expectations/awaiting are needed.
///
/// (swift-testing rather than XCTest: this machine has Command Line Tools
/// only — XCTest ships with Xcode, Testing.framework ships with the
/// toolchain. See the run command in the report / Tests/README note.)
@Suite("ClaudeAPIClient")
struct ClaudeAPIClientTests {

    // MARK: - Helpers

    private func usageResult(_ runner: FakeScriptRunner) -> Result<UsageReport, ClaudeAPIError> {
        var captured: Result<UsageReport, ClaudeAPIError>?
        ClaudeAPIClient(session: runner).fetchUsage { captured = $0 }
        guard let captured else {
            Issue.record("fetchUsage completion never fired")
            return .failure(.transport("no completion"))
        }
        return captured
    }

    private func failure<T>(_ result: Result<T, ClaudeAPIError>) -> ClaudeAPIError? {
        switch result {
        case .success:
            Issue.record("expected failure, got success")
            return nil
        case .failure(let e):
            return e
        }
    }

    /// Terse description of an error case, so a mismatch reports what it
    /// actually got instead of just "false".
    private func tag(_ error: ClaudeAPIError?) -> String {
        switch error {
        case .none: return "nil"
        case .loggedOut: return "loggedOut"
        case .backlogFull: return "backlogFull"
        case .transport(let d): return "transport(\(d))"
        case .http(let e, let s): return "http(\(e),\(s))"
        case .unexpectedShape(let e, let d): return "unexpectedShape(\(e),\(d))"
        }
    }

    // The shape CONTRACT.md documents, with every scalar kind present.
    static let usageJSON = """
    {"ok": true, "usage": {
      "five_hour": {"utilization": 45, "resets_at": "2026-07-26T18:00:00Z"},
      "seven_day": {"utilization": 12, "resets_at": "2026-07-30T00:00:00.000Z"},
      "limits": [
        {"kind": "weekly", "is_active": true, "percent": 12},
        {"kind": "weekly_scoped", "scope": {"model": {"id": null, "display_name": " Fable "}},
         "is_active": true, "percent": 100, "severity": "critical",
         "resets_at": "2026-07-27T09:00:00Z"},
        {"kind": "weekly_scoped", "scope": {"model": {"display_name": ""}}, "is_active": true}
      ],
      "spend": {"used": {"currency": "USD", "amount_minor": 404, "exponent": 2},
                "limit": {"currency": "USD", "amount_minor": 100000, "exponent": 2},
                "enabled": true, "severity": "normal"},
      "extra_usage": {"used_credits": 404, "monthly_limit": 100000,
                      "utilization": 0.404, "currency": "USD",
                      "decimal_places": 2, "is_enabled": true}
    }}
    """

    // MARK: - Success path

    @Test("usage: full payload decodes")
    func usageSuccessDecodesEverything() throws {
        let result = usageResult(FakeScriptRunner(json: Self.usageJSON))
        guard case .success(let report) = result else {
            Issue.record("expected success, got \(tag(failure(result)))")
            return
        }
        #expect(report.session.percent == 45)
        #expect(report.weekly.percent == 12)
        #expect(report.session.resetsAt != nil)
        #expect(report.weekly.resetsAt != nil, "fractional-seconds ISO variant must parse")
        // utilizationRaw stays an NSNumber for SnapshotLogger's frozen format.
        #expect(report.session.utilizationRaw?.intValue == 45)
        #expect(report.session.resetsAtRaw == "2026-07-26T18:00:00Z")

        // Only model-scoped, non-empty-named limits survive.
        #expect(report.scopedLimits.count == 1)
        let fable = try #require(report.scopedLimits.first)
        #expect(fable.modelDisplayName == "Fable", "display name is trimmed")
        #expect(fable.modelID == nil, "observed null id must not become a string")
        #expect(fable.percent == 100)
        #expect(fable.isActive)
        #expect(fable.resetsAt != nil)
        #expect(fable.severity == "critical")

        let spend = try #require(report.spendLimit)
        #expect(spend.spentMinor == 404)
        #expect(spend.limitMinor == 100000)
        #expect(spend.exponent == 2)
        #expect(spend.currency == "USD")
        #expect(abs((spend.utilizationPercent ?? 0) - 0.404) < 0.0001)
        #expect(spend.enabled)
        #expect(spend.severity == "normal")
        #expect(abs(spend.spentAmount - 4.04) < 0.0001)
    }

    /// The portability assertion (audit §1.3): the same payload expressed as
    /// NATIVE Swift scalars — what swift-foundation's JSON core produces off
    /// Darwin, where no Objective-C bridging exists — must decode identically.
    @Test("usage: native Swift scalars decode identically (no ObjC bridging)")
    func usageDecodesNativeSwiftScalars() {
        let native: [String: Any] = [
            "ok": true,
            "usage": [
                "five_hour": ["utilization": 45, "resets_at": "2026-07-26T18:00:00Z"],
                "seven_day": ["utilization": 12.0, "resets_at": "2026-07-30T00:00:00Z"],
                "limits": [[
                    "scope": ["model": ["display_name": "Fable"]],
                    "is_active": true, "percent": 100
                ]],
                "extra_usage": [
                    "used_credits": 404, "monthly_limit": 100000,
                    "utilization": 0.404, "currency": "USD",
                    "decimal_places": 2, "is_enabled": false
                ]
            ]
        ]
        let result = usageResult(FakeScriptRunner(native: native))
        guard case .success(let report) = result else {
            Issue.record("expected success, got \(tag(failure(result)))")
            return
        }
        #expect(report.session.percent == 45)
        #expect(report.weekly.percent == 12)
        #expect(report.scopedLimits.first?.isActive == true)
        #expect(report.spendLimit?.spentMinor == 404, "extra_usage fallback shape")
        #expect(report.spendLimit?.enabled == false, "is_enabled:false must not read as the ?? true default")
    }

    /// 0 and 1 are legitimate percentages, and on Darwin `as? Bool` accepts
    /// both — a boolean-first accessor would silently mangle them.
    @Test("usage: 0 and 1 percents stay integers")
    func zeroAndOnePercentsAreIntsNotBooleans() {
        let runner = FakeScriptRunner(json: """
        {"ok": true, "usage": {"five_hour": {"utilization": 0}, "seven_day": {"utilization": 1}}}
        """)
        guard case .success(let report) = usageResult(runner) else {
            Issue.record("expected success")
            return
        }
        #expect(report.session.percent == 0)
        #expect(report.weekly.percent == 1)
        #expect(report.session.utilizationRaw == NSNumber(value: 0))
    }

    @Test("usage: no spend blocks ⇒ nil spendLimit (Max/Pro)")
    func usageWithoutSpendBlocksHasNoSpendLimit() {
        let runner = FakeScriptRunner(json: """
        {"ok": true, "usage": {"five_hour": {"utilization": 5}, "seven_day": {"utilization": 5}}}
        """)
        guard case .success(let report) = usageResult(runner) else {
            Issue.record("expected success")
            return
        }
        #expect(report.spendLimit == nil)
        #expect(report.scopedLimits.isEmpty)
    }

    // MARK: - Envelope failure paths

    @Test("envelope: loggedOut")
    func loggedOutEnvelope() {
        let e = failure(usageResult(FakeScriptRunner(json: #"{"loggedOut": true}"#)))
        guard case .loggedOut? = e else {
            Issue.record("expected .loggedOut, got \(tag(e))")
            return
        }
    }

    /// `loggedOut: false` must fall through to the ok/error checks, not trip
    /// re-auth.
    @Test("envelope: loggedOut:false is not an auth failure")
    func loggedOutFalseIsNotAuthFailure() {
        let e = failure(usageResult(FakeScriptRunner(json: #"{"loggedOut": false}"#)))
        guard case .unexpectedShape(_, let detail)? = e else {
            Issue.record("expected .unexpectedShape, got \(tag(e))")
            return
        }
        #expect(detail == "usage_bad_envelope")
    }

    @Test("envelope: <name>_http_<status> maps to .http")
    func httpErrorEnvelope() {
        let e = failure(usageResult(FakeScriptRunner(json: #"{"error": "usage_http_500"}"#)))
        guard case .http(let endpoint, let status)? = e else {
            Issue.record("expected .http, got \(tag(e))")
            return
        }
        #expect(endpoint == "usage")
        #expect(status == 500)
    }

    /// The org preamble runs inside every script, so its failures must keep
    /// their own endpoint name rather than the caller's.
    @Test("envelope: org-preamble HTTP error keeps its endpoint name")
    func httpErrorFromOrgPreamble() {
        let e = failure(usageResult(FakeScriptRunner(json: #"{"error": "orgs_http_503"}"#)))
        guard case .http(let endpoint, let status)? = e else {
            Issue.record("expected .http, got \(tag(e))")
            return
        }
        #expect(endpoint == "orgs")
        #expect(status == 503)
    }

    @Test("envelope: non-HTTP error string becomes .unexpectedShape")
    func nonHTTPErrorStringBecomesUnexpectedShape() {
        let e = failure(usageResult(FakeScriptRunner(json: #"{"error": "no_orgs"}"#)))
        guard case .unexpectedShape(let endpoint, let detail)? = e else {
            Issue.record("expected .unexpectedShape, got \(tag(e))")
            return
        }
        #expect(endpoint == "usage")
        #expect(detail == "no_orgs")
    }

    @Test("envelope: missing ok")
    func malformedEnvelopeMissingOk() {
        let e = failure(usageResult(FakeScriptRunner(json: #"{"usage": {}}"#)))
        guard case .unexpectedShape(_, let detail)? = e else {
            Issue.record("expected .unexpectedShape, got \(tag(e))")
            return
        }
        #expect(detail == "usage_bad_envelope")
    }

    /// Strict by design: `ok` must be a real boolean (or Darwin's numeric
    /// 0/1 equivalent). A string never passes the gate.
    @Test("envelope: non-boolean ok is rejected",
          arguments: [#"{"ok": "true", "usage": {}}"#,
                      #"{"ok": 2, "usage": {}}"#,
                      #"{"ok": false, "usage": {}}"#])
    func malformedEnvelopeNonBooleanOk(literal: String) {
        let e = failure(usageResult(FakeScriptRunner(json: literal)))
        guard case .unexpectedShape(_, let detail)? = e else {
            Issue.record("expected .unexpectedShape for \(literal), got \(tag(e))")
            return
        }
        #expect(detail == "usage_bad_envelope")
    }

    @Test("envelope: response isn't an object")
    func malformedEnvelopeNotADict() {
        let e = failure(usageResult(FakeScriptRunner(json: "[1,2,3]")))
        guard case .unexpectedShape(_, let detail)? = e else {
            Issue.record("expected .unexpectedShape, got \(tag(e))")
            return
        }
        #expect(detail == "usage_not_a_dict")
    }

    @Test("envelope: ok but no payload")
    func okEnvelopeMissingPayload() {
        let e = failure(usageResult(FakeScriptRunner(json: #"{"ok": true}"#)))
        guard case .unexpectedShape(_, let detail)? = e else {
            Issue.record("expected .unexpectedShape, got \(tag(e))")
            return
        }
        #expect(detail == "usage_missing_payload")
    }

    // MARK: - Transport failure paths

    @Test("transport: backlogFull maps to .backlogFull")
    func backlogFullMapsToBacklogFullError() {
        let e = failure(usageResult(FakeScriptRunner(failure: ClaudeTransportError.backlogFull)))
        guard case .backlogFull? = e else {
            Issue.record("expected .backlogFull, got \(tag(e))")
            return
        }
    }

    /// The mapping is transport-neutral now, so it holds for every call —
    /// not just whichever one was tested when it matched a WebKit-specific
    /// error type.
    @Test("transport: backlogFull maps on every call")
    func backlogFullMapsOnEveryCall() {
        let client = ClaudeAPIClient(session: FakeScriptRunner(failure: ClaudeTransportError.backlogFull))
        var seen: [ClaudeAPIError] = []
        client.fetchChatConversations { if case .failure(let e) = $0 { seen.append(e) } }
        client.fetchCloudSessions { if case .failure(let e) = $0 { seen.append(e) } }
        #expect(seen.count == 2)
        for e in seen {
            guard case .backlogFull = e else {
                Issue.record("expected .backlogFull, got \(tag(e))")
                continue
            }
        }
    }

    @Test("transport: other errors keep their description")
    func otherTransportErrorsKeepTheirDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "js exception" } }
        let e = failure(usageResult(FakeScriptRunner(failure: Boom())))
        guard case .transport(let detail)? = e else {
            Issue.record("expected .transport, got \(tag(e))")
            return
        }
        #expect(detail == "js exception")
    }

    // MARK: - Chats

    @Test("chats: decode, dropping id-less items")
    func chatsDecodeAndDropIdlessItems() {
        let runner = FakeScriptRunner(json: """
        {"ok": true, "chats": [
          {"uuid": "a", "name": "First", "updated_at": "2026-07-25T10:00:00Z"},
          {"uuid": "b", "name": "", "updated_at": null},
          {"uuid": "", "name": "dropped"}
        ]}
        """)
        var captured: Result<[ChatConversation], ClaudeAPIError>?
        ClaudeAPIClient(session: runner).fetchChatConversations { captured = $0 }
        guard case .success(let chats)? = captured else {
            Issue.record("expected success")
            return
        }
        #expect(chats.map(\.id) == ["a", "b"])
        #expect(chats[0].title == "First")
        #expect(chats[0].updatedAt != nil)
        #expect(chats[1].title == "", "empty title stays empty; the app owns the fallback")
        #expect(chats[1].updatedAt == nil)
    }

    @Test("chats: empty list is success, not an error")
    func emptyChatListIsSuccess() {
        var captured: Result<[ChatConversation], ClaudeAPIError>?
        ClaudeAPIClient(session: FakeScriptRunner(json: #"{"ok": true, "chats": []}"#))
            .fetchChatConversations { captured = $0 }
        guard case .success(let chats)? = captured else {
            Issue.record("expected success")
            return
        }
        #expect(chats.isEmpty)
    }

    // MARK: - Recents

    @Test("recents: work states, archive flag, unknown vocabulary")
    func recentsDecodeStatusesAndArchiveFlag() {
        let runner = FakeScriptRunner(json: """
        {"ok": true, "cloudSessions": [
          {"id": "cse_1", "title": "Running", "worker_status": "running",
           "status": "active", "updated_at": "2026-07-25T10:00:00Z",
           "created_at": "2026-07-25T09:00:00Z"},
          {"id": "cse_2", "title": "Blocked", "worker_status": "requires_action",
           "status": "active", "updated_at": "2026-07-25T10:00:00Z",
           "created_at": "2026-07-25T09:00:00Z"},
          {"id": "cse_3", "title": "Archived", "worker_status": null,
           "status": "archived", "updated_at": null, "created_at": null},
          {"id": "cse_4", "title": "Alien", "worker_status": "quantum_foam",
           "status": "active", "updated_at": null, "created_at": null}
        ]}
        """)
        var captured: Result<[CloudSessionRecord], ClaudeAPIError>?
        ClaudeAPIClient(session: runner).fetchCloudSessions { captured = $0 }
        guard case .success(let records)? = captured else {
            Issue.record("expected success")
            return
        }
        #expect(records.map(\.id) == ["cse_1", "cse_2", "cse_3", "cse_4"])
        #expect(stateName(records[0].workState) == "running")
        #expect(stateName(records[1].workState) == "needsInput")
        #expect(stateName(records[2].workState) == "idle")
        #expect(records[2].isArchived)
        #expect(!records[0].isArchived)
        #expect(stateName(records[3].workState) == "unknown", "unknown vocabulary must not be guessed")
        #expect(records[0].createdAt != nil, "created_at is the dedupe join key")
    }

    // MARK: - Session lifecycle pass-through

    @Test("signOut forwards to the transport")
    func signOutForwardsToTransport() {
        let runner = FakeScriptRunner(json: #"{"ok": true}"#)
        var done = false
        ClaudeAPIClient(session: runner).signOut { done = true }
        #expect(done)
        #expect(runner.resetCount == 1)
    }

    @Test("signIn forwards the pasted key verbatim and returns its result")
    func signInForwardsPastedKeyAndResult() {
        let runner = FakeScriptRunner(json: #"{"ok": true}"#)
        runner.installResult = false
        var installed: Bool?
        ClaudeAPIClient(session: runner).signIn(sessionKey: "sessionKey=abc; other=1") { installed = $0 }
        #expect(installed == false)
        #expect(runner.installedKeys == ["sessionKey=abc; other=1"],
                "the client must not pre-parse the paste; the transport owns extraction")
    }

    @Test("debugRawHandler sees the undecoded payload")
    func debugRawHandlerSeesUndecodedPayload() {
        let client = ClaudeAPIClient(session: FakeScriptRunner(json: Self.usageJSON))
        var labels: [String] = []
        client.debugRawHandler = { label, _ in labels.append(label) }
        client.fetchUsage { _ in }
        #expect(labels == ["usage"])
    }
}

/// CloudWorkState is intentionally not Equatable in the module's public API;
/// compare by name in tests rather than retroactively conforming it.
private func stateName(_ state: CloudWorkState) -> String {
    switch state {
    case .running: return "running"
    case .needsInput: return "needsInput"
    case .idle: return "idle"
    case .unknown: return "unknown"
    }
}
