import XCTest
@testable import Condux

/// AppModel 의 OpenAI API 흐름: 키 저장 → 새 대화 → 전송 → 스트리밍 → 기록·예산 반영. 네트워크·키체인 없음.
@MainActor
final class AppModelOpenAIFlowTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var transport: FakeAPITransport!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "condux-openai-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        transport = FakeAPITransport()
        transport.lines = OpenAIAPIClientTests.happyTurn
        model = AppModel(store: ConversationStore(directory: directory), defaults: defaults,
                         secrets: InMemorySecretStore(), apiTransport: transport)
    }

    override func tearDownWithError() throws {
        model.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "조건이 시간 안에 만족되지 않았습니다. 진행: \(model.progress.phase)")
    }

    func testOpenAITurnStreamsRecordsTranscriptAndSpend() async throws {
        XCTAssertEqual(model.openAIAPIModel, "gpt-6.1-sol")
        model.openAIAPIKeyDraft = "sk-openai-test-4321"
        model.commitPendingAPIKey()
        XCTAssertTrue(model.openAIAPIKeyPresent)
        XCTAssertFalse(model.claudeAPIKeyPresent)
        XCTAssertEqual(model.defaultNewConversationProvider, .openAIAPI)

        await model.newConversation(provider: .openAIAPI)
        XCTAssertEqual(model.selectedProvider, .openAIAPI)
        XCTAssertTrue(model.canSend)
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }

        XCTAssertEqual(model.entries.filter { $0.kind == .assistant }.map(\.text), ["안녕하세요"])
        XCTAssertEqual(model.entries.filter { $0.kind == .activity }.map(\.title), ["생각 정리"])
        XCTAssertEqual(model.openAIAPIServedModel, "gpt-6.1-sol")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai-test-4321")
        XCTAssertEqual(transport.requests.first?.url?.host, "api.openai.com")

        let conversation = try XCTUnwrap(model.selectedConversation)
        XCTAssertEqual(conversation.apiTranscript.count, 2)
        XCTAssertEqual(conversation.apiTranscript[0]["content"]?[0]?["type"]?.stringValue, "input_text")
        XCTAssertEqual(conversation.apiTranscript[1]["role"]?.stringValue, "assistant")
        XCTAssertEqual(conversation.apiTranscript[1]["content"]?[0]?["type"]?.stringValue, "output_text")
        XCTAssertEqual(conversation.apiTranscript[1]["content"]?[0]?["text"]?.stringValue, "안녕하세요")
        // gpt-6.1-sol: 비캐시 입력 20 × $2/M + 캐시 100 × $0.10/M + 출력 40 × $10/M = $0.00045
        XCTAssertEqual(conversation.apiSpentUSD, 0.00045, accuracy: 0.000001)
        XCTAssertTrue(model.apiCostSummary.hasPrefix("예상 비용 $0.000"), model.apiCostSummary)

        // 두 번째 턴은 이전 텍스트를 Responses 입력 형식으로 다시 보냅니다.
        model.draft = "또 안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed && self.transport.requests.count == 2 }
        let body = try XCTUnwrap(transport.lastBody)
        XCTAssertEqual(body["input"]?.arrayValue?.count, 3)
        XCTAssertEqual(body["input"]?[1]?["content"]?[0]?["type"]?.stringValue, "output_text")

        let saved = ConversationStore(directory: directory).load()
        XCTAssertEqual(saved.first?.provider, .openAIAPI)
        XCTAssertEqual(saved.first?.apiTranscript.count, 4)
    }

    func testOpenAIWebSearchShowsActivitySourcesAndCost() async throws {
        model.saveOpenAIAPIKey("sk-openai-test")
        model.openAIAPIModel = "gpt-6.1-sol"
        await model.newConversation(provider: .openAIAPI)
        transport.lines = FakeAPITransport.sse([
            ("response.created", #"{"type":"response.created","response":{"id":"r1","model":"gpt-6.1-sol"}}"#),
            ("response.web_search_call.searching", #"{"type":"response.web_search_call.searching","item_id":"ws1"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","item":{"type":"web_search_call","id":"ws1","status":"completed","action":{"type":"search","query":"오늘 날씨"}}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"맑습니다."}"#),
            ("response.output_text.done", #"{"type":"response.output_text.done"}"#),
            ("response.completed", #"{"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":50},"output":[{"type":"web_search_call"},{"type":"message","content":[{"type":"output_text","text":"맑습니다.","annotations":[{"type":"url_citation","url":"https://example.com/w","title":"날씨"}]}]}]}}"#),
        ])
        model.draft = "오늘 날씨"
        await model.send()
        let deadline = Date().addingTimeInterval(5)
        while model.progress.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(transport.lastBody?["tools"]?[0]?["type"]?.stringValue, "web_search")
        XCTAssertEqual(model.entries.first { $0.title == "웹 검색" }?.text, "오늘 날씨")
        XCTAssertTrue(model.entries.last { $0.kind == .assistant }?.text.contains("[날씨](https://example.com/w)") ?? false)
        // gpt-6.1-sol: (100 × $2 + 50 × $10)/M + 검색 1회 $0.01
        XCTAssertEqual(try XCTUnwrap(model.selectedConversation).apiSpentUSD, 0.0107, accuracy: 0.000001)
    }

    func testBudgetAndKeyGuardsApplyToOpenAI() async throws {
        await model.newConversation(provider: .openAIAPI)
        XCTAssertTrue(model.conversations.isEmpty, "키 없이는 대화를 만들지 않습니다")
        model.saveOpenAIAPIKey("sk-x")
        model.claudeAPIDefaultBudgetUSD = 0.0001
        await model.newConversation(provider: .openAIAPI)
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }
        XCTAssertTrue(model.apiBudgetExhausted)
        XCTAssertFalse(model.canSend)
        model.raiseAPIBudget(by: 1)
        XCTAssertTrue(model.canSend)
    }
}
