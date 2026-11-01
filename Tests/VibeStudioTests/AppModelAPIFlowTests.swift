import XCTest
@testable import Condux

/// AppModel 의 Claude API 흐름: 키 저장 → 새 대화 → 전송 → 스트리밍 → 기록·예산 반영. 네트워크·키체인 없음.
private final class FailingSecretStore: SecretStore {
    func read(_ key: String) -> String? { nil }
    func delete(_ key: String) {}
    func write(_ key: String, value: String) throws {
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "저장 실패 \(value)\nAuthorization: Bearer header-secret\nx-api-key: api-secret"])
    }
}

@MainActor
final class AppModelAPIFlowTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var transport: FakeAPITransport!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "condux-api-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        transport = FakeAPITransport()
        transport.lines = FakeAPITransport.happyTurn
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

    func testPendingKeyIsSavedWhenSheetClosesWithoutPressingSaveKey() {
        model.claudeAPIKeyDraft = " sk-test-draft-9999 "
        XCTAssertFalse(model.claudeAPIKeyPresent)
        model.commitPendingAPIKey() // ‘닫기’ 또는 ‘저장’ 버튼이 호출
        XCTAssertTrue(model.claudeAPIKeyPresent)
        XCTAssertEqual(model.claudeAPIKeyDraft, "")
        XCTAssertTrue(model.claudeAPIKeyStatus.hasPrefix("저장됨"))
        XCTAssertFalse(model.claudeAPIKeyStatus.contains("9999"), "키 끝자리도 표시하지 않습니다")
        XCTAssertFalse(model.claudeAPIKeyStatus.contains("sk-test-draft"))
        model.commitPendingAPIKey() // 비어 있으면 아무것도 안 함
        XCTAssertTrue(model.claudeAPIKeyPresent)
    }

    private func startClaudeConversation() async {
        model.saveClaudeAPIKey("sk-test-123")
        model.claudeAPIModel = "claude-opus-5-5"
        await model.newConversation(provider: .claudeAPI)
    }

    func testWebSearchTurnKeepsBlocksForReplayShowsSourcesAndCounts() async throws {
        await startClaudeConversation()
        transport.lines = FakeAPITransport.webSearchTurn()
        model.draft = "오늘 날씨 알려 줘"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }

        let sent = try XCTUnwrap(transport.lastBody)
        XCTAssertEqual(sent["tools"]?[0]?["type"]?.stringValue, "web_search_20250305")
        XCTAssertEqual(sent["tools"]?[1]?["type"]?.stringValue, "web_fetch_20250910")
        XCTAssertFalse(sent["system"]?.stringValue?.contains("도구 없이") ?? true, "웹을 쓸 수 있다고 알립니다")

        let activity = try XCTUnwrap(model.entries.first { $0.title == "웹 검색" })
        XCTAssertEqual(activity.text, "오늘 날씨")
        let answer = try XCTUnwrap(model.entries.last { $0.kind == .assistant })
        XCTAssertTrue(answer.text.hasPrefix("찾아보겠습니다. 맑습니다."))
        XCTAssertTrue(answer.text.contains("- [날씨 속보](https://example.com/w)"), "출처 링크, 제목의 괄호는 뺍니다: \(answer.text)")

        // opus 5.5: (100 × $4 + 50 × $20)/M + 검색 1회 $0.01
        let conversation = try XCTUnwrap(model.selectedConversation)
        XCTAssertEqual(conversation.apiSpentUSD, 0.0114, accuracy: 0.000001)

        // 다음 턴에는 받은 블록을 그대로 돌려보내고, 화면용 출처 줄은 보내지 않습니다.
        transport.lines = FakeAPITransport.happyTurn
        model.draft = "고마워"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed && self.transport.requests.count == 2 }
        let replay = try XCTUnwrap(transport.lastBody?["messages"]?[1]?["content"])
        XCTAssertEqual(replay[1]?["input"]?["query"]?.stringValue, "오늘 날씨")
        XCTAssertEqual(replay[2]?["content"]?[0]?["encrypted_content"]?.stringValue, "ENC123")
        XCTAssertEqual(replay[3]?["citations"]?[0]?["encrypted_index"]?.stringValue, "IDX1")
        XCTAssertEqual(replay[3]?["text"]?.stringValue, "맑습니다.")
        XCTAssertFalse(try replay.compactJSON().contains("출처"))
    }

    func testPauseTurnResumesWithoutExtraUserMessage() async throws {
        await startClaudeConversation()
        transport.responseQueue = [FakeAPITransport.webSearchTurn(stop: "pause_turn"), FakeAPITransport.happyTurn]
        model.draft = "찾아 줘"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed && self.transport.requests.count == 2 }

        let messages = try XCTUnwrap(transport.lastBody?["messages"]?.arrayValue)
        XCTAssertEqual(messages.map { $0["role"]?.stringValue }, ["user", "assistant"], "이어 달라는 사용자 메시지를 더하지 않습니다")
        let transcript = try XCTUnwrap(model.selectedConversation?.apiTranscript)
        XCTAssertEqual(transcript.count, 2, "이어 받은 답은 한 메시지로 합칩니다")
        XCTAssertEqual(try XCTUnwrap(model.selectedConversation).apiSpentUSD, 0.0114 + 0.00108, accuracy: 0.000001)
    }

    func testAccountWithoutWebSearchFallsBackToPlainAnswer() async throws {
        await startClaudeConversation()
        transport.statusQueue = [400, 200]
        transport.responseQueue = [[#"{"type":"error","error":{"type":"invalid_request_error","message":"web search is not enabled for this organization"}}"#],
                                   FakeAPITransport.happyTurn]
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed && self.transport.requests.count == 2 }
        XCTAssertNil(transport.lastBody?["tools"])
        XCTAssertTrue(transport.lastBody?["system"]?.stringValue?.contains("도구 없이") ?? false)
        XCTAssertEqual(model.entries.filter { $0.kind == .assistant }.map(\.text), ["안녕하세요"])
        XCTAssertTrue(model.notice?.contains("웹 검색 없이") ?? false)
        XCTAssertTrue(model.entries.filter { $0.kind == .error }.isEmpty)
    }

    func testOtherBadRequestIsNotRetriedAndWebSearchCanBeTurnedOff() async throws {
        await startClaudeConversation()
        transport.status = 400
        transport.lines = [#"{"type":"error","error":{"type":"invalid_request_error","message":"messages: too long"}}"#]
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .failed }
        XCTAssertEqual(transport.requests.count, 1)

        transport.status = 200
        transport.lines = FakeAPITransport.happyTurn
        model.webSearchEnabled = false
        model.draft = "다시"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }
        XCTAssertNil(transport.lastBody?["tools"])
        XCTAssertEqual(defaults.object(forKey: "webSearchEnabled") as? Bool, false)
    }

    func testCancelledSearchDoesNotLeaveDanglingToolCall() {
        var assembler = ClaudeAPIBlockAssembler()
        assembler.apply(.rawBlock(index: 0, block: ["type": "server_tool_use", "id": "s1", "name": "web_search"]))
        assembler.apply(.inputDelta(index: 0, partialJSON: #"{"query":"q"}"#))
        assembler.apply(.blockStopped(index: 0))
        XCTAssertTrue(assembler.completedContent.isEmpty, "결과 없는 호출은 다음 요청에서 뺍니다")
        XCTAssertEqual(assembler.resumableContent.count, 1, "pause_turn 때는 남깁니다")
        XCTAssertEqual(assembler.serverTool(at: 0)?.detail, "q")
    }

    func testNewAPIConversationRequiresKey() async {
        XCTAssertFalse(model.claudeAPIKeyPresent)
        await model.newConversation(provider: .claudeAPI)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertNotNil(model.notice)
    }

    func testTurnStreamsRecordsTranscriptAndSpend() async throws {
        model.saveClaudeAPIKey(" sk-test-123 ")
        XCTAssertTrue(model.claudeAPIKeyPresent)
        model.claudeAPIDefaultBudgetUSD = 2.0
        await model.newConversation(provider: .claudeAPI)
        XCTAssertEqual(model.selectedProvider, .claudeAPI)
        XCTAssertEqual(model.selectedConversation?.apiBudgetUSD, 2.0)
        XCTAssertTrue(model.canSend)

        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }

        XCTAssertEqual(model.entries.filter { $0.kind == .assistant }.map(\.text), ["안녕하세요"])
        XCTAssertEqual(model.entries.filter { $0.kind == .activity }.map(\.title), ["생각 정리"])
        XCTAssertEqual(model.claudeAPIServedModel, "claude-opus-5-5")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "x-api-key"), "sk-test-123")

        let conversation = try XCTUnwrap(model.selectedConversation)
        XCTAssertEqual(conversation.apiTranscript.count, 2, "user + assistant")
        XCTAssertEqual(conversation.apiTranscript[1]["content"]?[0]?["type"]?.stringValue, "thinking")
        XCTAssertEqual(conversation.apiTranscript[1]["content"]?[1]?["text"]?.stringValue, "안녕하세요")
        // opus 5.5: 입력 20 토큰 × $4/M + 출력 50 × $20/M = $0.00108
        XCTAssertEqual(conversation.apiSpentUSD, 0.00108, accuracy: 0.000001)
        XCTAssertTrue(model.apiCostSummary.hasPrefix("예상 비용 $0.0011 / 예산 $2.00"))
        XCTAssertTrue(model.tokenSummary.contains("출력 50"))
        XCTAssertEqual(conversation.usage, ConversationUsage(contextTokens: 70, contextWindow: 1_000_000, totalInputTokens: 20, totalOutputTokens: 50))
        XCTAssertEqual(model.usageChipText, "컨텍스트 1%")

        // 두 번째 턴은 이전 기록(thinking 포함)을 통째로 다시 보냅니다.
        model.draft = "또 안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed && self.transport.requests.count == 2 }
        let body = try XCTUnwrap(transport.lastBody)
        XCTAssertEqual(body["messages"]?.arrayValue?.count, 3)
        XCTAssertEqual(body["messages"]?[1]?["content"]?[0]?["signature"]?.stringValue, "sig123")
        XCTAssertEqual(model.entries.filter { $0.kind == .assistant }.count, 2)
        XCTAssertEqual(model.selectedConversation?.usage.totalInputTokens, 40, "주고받은 토큰은 쌓입니다")
        XCTAssertEqual(model.selectedConversation?.usage.contextTokens, 70, "컨텍스트는 마지막 턴 값입니다")

        // 저장 파일에도 남습니다.
        let saved = ConversationStore(directory: directory).load()
        XCTAssertEqual(saved.first?.provider, .claudeAPI)
        XCTAssertEqual(saved.first?.apiTranscript.count, 4)
        XCTAssertEqual(saved.first?.apiBudgetUSD, 2.0)
    }

    func testBudgetExhaustionBlocksSendUntilRaised() async throws {
        model.saveClaudeAPIKey("sk-test")
        model.claudeAPIDefaultBudgetUSD = 0.001 // 한 턴($0.00108)으로 소진
        await model.newConversation(provider: .claudeAPI)
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }
        XCTAssertTrue(model.apiBudgetExhausted)
        XCTAssertFalse(model.canSend)

        model.draft = "더"
        await model.send()
        XCTAssertEqual(transport.requests.count, 1, "예산이 끝나면 요청을 보내지 않습니다")
        XCTAssertTrue(model.notice?.contains("예산") ?? false)

        model.raiseAPIBudget(by: 1)
        XCTAssertFalse(model.apiBudgetExhausted)
        XCTAssertTrue(model.canSend)
        await model.send()
        try await waitUntil { self.transport.requests.count == 2 && self.model.progress.state == .completed }
        XCTAssertEqual(model.selectedConversation?.apiBudgetUSD, 1.001)
    }

    func testMaxTokensShrinksWithRemainingBudget() async throws {
        model.saveClaudeAPIKey("sk-test")
        model.claudeAPIDefaultBudgetUSD = 0.05 // opus 출력 $20/M → 2,500 토큰
        await model.newConversation(provider: .claudeAPI)
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }
        XCTAssertEqual(transport.lastBody?["max_tokens"]?.intValue, 2_500)
    }

    func testHTTPErrorShowsAsErrorEntry() async throws {
        transport.status = 429
        transport.lines = [#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#]
        model.saveClaudeAPIKey("sk-test")
        await model.newConversation(provider: .claudeAPI)
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .failed }
        XCTAssertTrue(model.entries.last?.text.contains("429") ?? false)
        XCTAssertEqual(model.selectedConversation?.apiTranscript.count, 1, "실패한 턴의 답변은 기록하지 않습니다")
    }

    func testInterruptCancelsAndKeepsPartialText() async throws {
        transport.neverFinish = true
        transport.lines = Array(FakeAPITransport.happyTurn.prefix(24)) // 텍스트 첫 조각까지, 끝나지 않음
        model.saveClaudeAPIKey("sk-test")
        await model.newConversation(provider: .claudeAPI)
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.entries.contains { $0.kind == .assistant && $0.text == "안녕" } }
        await model.interrupt()
        try await waitUntil { self.model.progress.state == .interrupted }
        XCTAssertFalse(model.entries.contains { $0.isStreaming })
        XCTAssertFalse(model.entries.contains { $0.kind == .error })
        XCTAssertEqual(model.selectedConversation?.apiTranscript.count, 2, "완료된 thinking 블록만 돌려보낼 수 있습니다")
    }
    func testAPIDiagnosticsAreSafeInEventLogAndSavedConversation() async throws {
        let key = "fixture-app-key-1234"
        model.saveClaudeAPIKey(key)
        model.saveOpenAIAPIKey(key)
        for provider: Provider in [.claudeAPI, .openAIAPI] {
            let body: JSONValue = ["type": "error", "error": ["type": .string(key), "code": .string(key),
                "message": .string("요청 오류 \(key)\nAuthorization: Bearer header-secret\nx-api-key: api-secret")]]
            transport.lines = ["data: \(key) Authorization: Bearer malformed-secret"]
                + FakeAPITransport.sse([("error", try body.compactJSON())])
            await model.newConversation(provider: provider)
            model.draft = "안녕"
            await model.send()
            try await waitUntil { self.model.progress.state == .failed }
            let error = try XCTUnwrap(model.entries.last { $0.kind == .error })
            XCTAssertTrue(error.text.contains("[가림]"))
            let saved = try String(contentsOf: ConversationStore(directory: directory).fileURL)
            let diagnostic = model.eventLog.map(\.text).joined() + model.entries.map(\.text).joined() + saved
            for secret in [key, "header-secret", "api-secret", "malformed-secret"] {
                XCTAssertFalse(diagnostic.contains(secret))
            }
        }
    }

    func testRefusalCategoryIsRedactedBeforeSaving() async throws {
        let key = "fixture-refusal-key"
        model.saveClaudeAPIKey(key)
        let body: JSONValue = ["type": "message_delta", "delta": ["stop_reason": "refusal",
            "stop_details": ["category": .string("\(key) Authorization: Bearer header-secret")]]]
        transport.lines = FakeAPITransport.sse([("message_delta", try body.compactJSON())])
        await model.newConversation(provider: .claudeAPI)
        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .failed }
        let error = try XCTUnwrap(model.entries.last { $0.kind == .error })
        XCTAssertTrue(error.text.contains("안전 정책"))
        let saved = try String(contentsOf: ConversationStore(directory: directory).fileURL)
        for secret in [key, "header-secret"] { XCTAssertFalse((error.text + saved).contains(secret)) }
    }

    func testTransportErrorIsSafeInSavedConversationForBothProviders() async throws {
        let key = "fixture-app-transport-key"
        for provider: Provider in [.claudeAPI, .openAIAPI] {
            model.flushAndDisconnect()
            model = AppModel(store: ConversationStore(directory: directory), defaults: defaults,
                secrets: InMemorySecretStore(), apiTransport: FailingAPITransport(error:
                    NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(key) Authorization: Bearer secret"])))
            model.saveClaudeAPIKey(key)
            model.saveOpenAIAPIKey(key)
            await model.newConversation(provider: provider)
            model.draft = "안녕"
            await model.send()
            try await waitUntil { self.model.progress.state == .failed }
            let error = try XCTUnwrap(model.entries.last { $0.kind == .error })
            XCTAssertTrue(error.text.contains("API 연결에 실패했습니다"))
            let saved = try String(contentsOf: ConversationStore(directory: directory).fileURL)
            XCTAssertFalse((error.text + saved).contains(key))
            XCTAssertFalse((error.text + saved).contains("secret"))
        }
    }

    func testSavingEitherAPIKeyDoesNotDisplayItsSuffix() {
        let claudeKey = "fixture-claude-key-9876"
        let openAIKey = "fixture-openai-key-5432"
        model.saveClaudeAPIKey(claudeKey)
        model.saveOpenAIAPIKey(openAIKey)
        XCTAssertTrue(model.claudeAPIKeyPresent)
        XCTAssertTrue(model.openAIAPIKeyPresent)
        let diagnostic = model.claudeAPIKeyStatus + model.openAIAPIKeyStatus + (model.notice ?? "")
        for secret in [claudeKey, openAIKey, "9876", "5432"] { XCTAssertFalse(diagnostic.contains(secret)) }
        XCTAssertTrue(model.claudeAPIKeyStatus.hasPrefix("저장됨"))
        XCTAssertTrue(model.openAIAPIKeyStatus.hasPrefix("저장됨"))
    }

    func testKeyStorageErrorsDoNotExposeKeysInStatusOrNotice() {
        model.flushAndDisconnect()
        model = AppModel(store: ConversationStore(directory: directory), defaults: defaults,
                         secrets: FailingSecretStore(), apiTransport: transport)
        let key = "fixture-keychain-key"
        model.saveClaudeAPIKey(key)
        XCTAssertFalse(model.claudeAPIKeyPresent)
        let claudeNotice = model.notice ?? ""
        model.saveOpenAIAPIKey(key)
        XCTAssertFalse(model.openAIAPIKeyPresent)
        XCTAssertTrue(model.claudeAPIKeyStatus.hasPrefix("저장 실패"))
        XCTAssertTrue(model.openAIAPIKeyStatus.hasPrefix("저장 실패"))
        let diagnostic = model.claudeAPIKeyStatus + claudeNotice + model.openAIAPIKeyStatus + (model.notice ?? "")
        for secret in [key, "header-secret", "api-secret"] { XCTAssertFalse(diagnostic.contains(secret)) }
        XCTAssertTrue(diagnostic.contains("[가림]"))
    }

}
