import XCTest
@testable import Condux

/// 자동 릴레이: 구현(Claude API) → 검토(OpenAI API, 수정 필요) → 수정(Claude API) → 검토(승인) 이 사람 개입 없이 도는지.
/// 네트워크 없이 가짜 전송에 네 번의 응답을 순서대로 넣어 둡니다.
@MainActor
final class AppModelRelayTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var transport: FakeAPITransport!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "condux-relay-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        transport = FakeAPITransport()
        model = AppModel(store: ConversationStore(directory: directory), defaults: defaults,
                         secrets: InMemorySecretStore(), apiTransport: transport)
        model.saveClaudeAPIKey("sk-claude-test")
        model.saveOpenAIAPIKey("sk-openai-test")
    }

    override func tearDownWithError() throws {
        model.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "조건이 시간 안에 만족되지 않았습니다. 상태: \(model.relay?.statusText ?? "-") / 진행: \(model.progress.phase)")
    }

    private static func openAIReply(_ text: String) -> [String] {
        FakeAPITransport.sse([
            ("response.created", #"{"type":"response.created","response":{"id":"r","model":"gpt-6.1-sol"}}"#),
            ("response.output_text.delta", "{\"type\":\"response.output_text.delta\",\"item_id\":\"m\",\"output_index\":0,\"content_index\":0,\"delta\":\(Self.json(text))}"),
            ("response.output_text.done", "{\"type\":\"response.output_text.done\",\"item_id\":\"m\",\"output_index\":0,\"content_index\":0,\"text\":\(Self.json(text))}"),
            ("response.completed", #"{"type":"response.completed","response":{"id":"r","model":"gpt-6.1-sol","status":"completed","usage":{"input_tokens":50,"output_tokens":20}}}"#),
        ])
    }

    private static func json(_ s: String) -> String {
        String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
    }

    func testRelayRunsTwoRoundsUntilReviewerApproves() async throws {
        transport.responseQueue = [
            FakeAPITransport.happyTurn,                                      // 1) 구현자(Claude API) 첫 답변
            Self.openAIReply("NEEDS_CHANGES\n1. 인사말에 이름을 넣으세요."),   // 2) 검토: 수정 필요
            FakeAPITransport.happyTurn,                                      // 3) 구현자 수정
            Self.openAIReply("APPROVED 요구사항을 모두 만족합니다."),           // 4) 검토: 승인
        ]
        model.relayReviewer = .openAIAPI
        model.relayMaxRounds = 3
        await model.newConversation(provider: .claudeAPI)
        model.draft = "인사말을 만들어 줘"
        await model.startRelay()
        try await waitUntil { self.model.relay?.phase == .done }

        let state = try XCTUnwrap(model.relay)
        XCTAssertEqual(state.round, 2)
        XCTAssertTrue(state.summary.contains("검토자 승인"), state.summary)
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(transport.requests[1].url?.host, "api.openai.com")
        XCTAssertEqual(transport.requests[2].url?.host, "api.anthropic.com")
        // 검토 요청에는 작업 지시와 구현자 답변이 들어갑니다.
        let reviewBody = try JSONValue.parse(try XCTUnwrap(transport.requests[1].httpBody))
        let reviewText = reviewBody["input"]?[0]?["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(reviewText.contains("인사말을 만들어 줘"))
        XCTAssertTrue(reviewText.contains("안녕하세요"))
        XCTAssertEqual(reviewBody["instructions"]?.stringValue, RelayPrompts.reviewerSystem)
        // 수정 요청은 검토 의견을 담아 구현자에게 자동으로 갑니다.
        let fixBody = try JSONValue.parse(try XCTUnwrap(transport.requests[2].httpBody))
        let fixText = fixBody["messages"]?.arrayValue?.last?["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(fixText.contains("검토자 의견"))
        XCTAssertTrue(fixText.contains("이름을 넣으세요"))
        // 화면 항목: 시작, 검토 2개(수정 필요/승인), 완료
        let titles = model.entries.filter { $0.kind == .activity }.map(\.title)
        XCTAssertEqual(model.entries.first { $0.title.hasPrefix("릴레이 시작") }?.status, "완료", "시작 항목도 완료로 닫혀야 합니다")
        XCTAssertEqual(model.entries.filter { $0.title.hasPrefix("검토자 의견") }.map(\.status), ["수정 필요", "승인"])
        XCTAssertTrue(titles.contains { $0.hasPrefix("릴레이 완료") })
        // 검토 비용도 같은 대화 예산에 합산 (구현 2턴 + 검토 2턴 > 구현만 했을 때)
        XCTAssertGreaterThan(model.selectedConversation?.apiSpentUSD ?? 0, 2 * 0.00108)
        XCTAssertFalse(model.relayIsActive)
        XCTAssertEqual(model.draft, "")
    }

    func testRelayStopsAtMaxRounds() async throws {
        transport.responseQueue = [
            FakeAPITransport.happyTurn,
            Self.openAIReply("NEEDS_CHANGES 더 고치세요"),
            FakeAPITransport.happyTurn,
            Self.openAIReply("NEEDS_CHANGES 아직입니다"),
        ]
        model.relayReviewer = .openAIAPI
        model.relayMaxRounds = 2
        await model.newConversation(provider: .claudeAPI)
        model.draft = "작업"
        await model.startRelay()
        try await waitUntil { self.model.relay?.phase == .done }
        XCTAssertTrue(model.relay?.summary.contains("최대 2회") ?? false, model.relay?.summary ?? "")
        XCTAssertEqual(transport.requests.count, 4)
    }

    /// ‘자동 수정’을 끄면 검토 의견을 입력창에만 넣고 끝냅니다.
    func testReviewOnlyModeStopsAfterReviewAndFillsDraft() async throws {
        transport.responseQueue = [FakeAPITransport.happyTurn, Self.openAIReply("NEEDS_CHANGES\n1. 이름을 넣으세요.")]
        model.relayReviewer = .openAIAPI
        model.relayAutoFix = false
        await model.newConversation(provider: .claudeAPI)
        model.draft = "인사말"
        await model.startRelay()
        try await waitUntil { self.model.relay?.phase == .done }
        XCTAssertEqual(transport.requests.count, 2, "구현 1회 + 검토 1회, 수정 요청은 보내지 않음")
        XCTAssertTrue(model.relay?.summary.contains("입력창에 넣었습니다") ?? false, model.relay?.summary ?? "")
        XCTAssertTrue(model.draft.contains("검토자 의견") && model.draft.contains("이름을 넣으세요"), model.draft)
        XCTAssertFalse(model.progress.isBusy)
    }

    func testRelayNeedsDraftAndReviewerKey() async {
        model.clearOpenAIAPIKey()
        model.relayReviewer = .openAIAPI
        await model.newConversation(provider: .claudeAPI)
        model.draft = "작업"
        await model.startRelay()
        XCTAssertNil(model.relay)
        XCTAssertTrue(model.notice?.contains("키가 없습니다") ?? false)
        XCTAssertEqual(model.availableReviewers, [.claudeAPI])
    }

    func testIsApprovedParsing() {
        XCTAssertTrue(RelayPrompts.isApproved("APPROVED\n잘 됐습니다"))
        XCTAssertTrue(RelayPrompts.isApproved("  approved - 문제 없음"))
        XCTAssertFalse(RelayPrompts.isApproved("NEEDS_CHANGES\n1. ..."))
        XCTAssertFalse(RelayPrompts.isApproved("수정이 필요합니다. APPROVED 가 아닙니다. NEEDS_CHANGES"))
    }
    func testReviewerErrorsDoNotExposeKeysInSummaryNoticeOrSavedTitles() async throws {
        let key = "fixture-review-key"
        model.saveClaudeAPIKey(key)
        model.saveOpenAIAPIKey(key)
        for reviewer: Provider in [.openAIAPI, .claudeAPI] {
            let body: JSONValue = ["type": "error", "error": ["type": .string(key), "code": .string(key),
                "message": .string("\(key)\nAuthorization: Bearer header-secret\nx-api-key: api-secret")]]
            transport.responseQueue = [FakeAPITransport.happyTurn, FakeAPITransport.sse([("error", try body.compactJSON())])]
            model.relayReviewer = reviewer
            await model.newConversation(provider: .claudeAPI)
            model.draft = "확인해 줘"
            await model.startRelay()
            try await waitUntil { self.model.relay?.phase == .stopped }
            let summary = try XCTUnwrap(model.relay?.summary)
            XCTAssertTrue(summary.contains("검토 실패"))
            XCTAssertTrue(summary.contains("[가림]"))
            let saved = try String(contentsOf: ConversationStore(directory: directory).fileURL)
            let diagnostic = summary + (model.notice ?? "") + model.entries.map(\.title).joined() + saved
            for secret in [key, "header-secret", "api-secret"] { XCTAssertFalse(diagnostic.contains(secret)) }
        }
    }

    func testStoppingReviewerKeepsUserCancellationSummary() async throws {
        transport.responseQueue = [FakeAPITransport.happyTurn, []]
        transport.holdRequestNumber = 2
        model.relayReviewer = .openAIAPI
        await model.newConversation(provider: .claudeAPI)
        model.draft = "검토해 줘"
        await model.startRelay()
        // 구현 턴의 응답을 모두 받은 뒤 검토자의 스트림만 대기시킵니다.
        try await waitUntil { self.transport.requests.count == 2 }
        model.stopRelay()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.relay?.phase, .stopped)
        XCTAssertEqual(model.relay?.summary, "사용자가 중단")
    }

}
