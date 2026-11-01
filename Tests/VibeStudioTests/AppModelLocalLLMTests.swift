import XCTest
@testable import Condux

private actor FakeLocalLLM: LocalLLMGenerating {
    nonisolated let isAvailable: Bool
    let slow: Bool
    let fails: Bool
    let output: String
    private(set) var requests: [([LocalLLMMessage], String)] = []
    init(available: Bool = true, slow: Bool = false, fails: Bool = false, output: String = " 답변") {
        isAvailable = available; self.slow = slow; self.fails = fails; self.output = output
    }
    func stream(directory: URL, history: [LocalLLMMessage], prompt: String,
                onDelta: @MainActor @Sendable (String) -> Void) async throws {
        requests.append((history, prompt))
        await onDelta("로컬")
        if slow { try await Task.sleep(for: .seconds(30)) }
        if fails { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsafe remote-looking error"]) }
        await onDelta(output)
    }
}

@MainActor
final class AppModelLocalLLMTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var model: AppModel!
    private var transport: FakeAPITransport!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "condux-local-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        transport = FakeAPITransport()
    }
    override func tearDownWithError() throws {
        model?.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func makeModel(_ engine: FakeLocalLLM, ready: Bool = true) throws -> AppModel {
        let store = ConversationStore(directory: directory)
        let local = LocalModelStore(root: directory.appendingPathComponent("Models"))
        if ready {
            try FileManager.default.createDirectory(at: local.directory, withIntermediateDirectories: true)
            // Sparse fixtures reserve file lengths without downloading or allocating real weights.
            for file in LocalModelStore.files {
                let url = local.directory.appendingPathComponent(file.name)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(file.size))
                try handle.close()
            }
            try LocalModelStore.revision.write(to: local.directory.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
        }
        return AppModel(store: store, defaults: defaults, secrets: InMemorySecretStore(), apiTransport: transport, localClient: engine)
    }
    private func waitForEnd() async throws {
        let deadline = Date().addingTimeInterval(3)
        while model.progress.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.progress.isBusy)
    }

    func testMissingModelAndUnavailableEngineCannotStartConversation() async throws {
        model = try makeModel(FakeLocalLLM(), ready: false)
        await model.newConversation(provider: .localLLM)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertTrue(model.notice?.contains("다운로드") == true)
        model = try makeModel(FakeLocalLLM(available: false))
        await model.newConversation(provider: .localLLM)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testStreamsPersistsAndRestoresConversationHistoryWithoutAPI() async throws {
        let engine = FakeLocalLLM()
        model = try makeModel(engine)
        await model.newConversation(provider: .localLLM)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(model.defaultNewConversationProvider, .localLLM)
        XCTAssertEqual(model.selectedConversation?.workspacePath, "")
        model.draft = "첫 질문"
        await model.send()
        try await waitForEnd()
        XCTAssertEqual(model.entries.last?.text, "로컬 답변")
        XCTAssertEqual(model.progress.state, .completed)
        XCTAssertEqual(model.selectedConversation?.apiSpentUSD, 0)
        XCTAssertEqual(model.apiCostSummary, "")
        model.flushAndDisconnect()
        model = try makeModel(engine)
        XCTAssertEqual(model.selectedProvider, .localLLM)
        model.draft = "두 번째 질문"
        await model.send()
        try await waitForEnd()
        let requests = await engine.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].0, [.init(role: .user, text: "첫 질문"), .init(role: .assistant, text: "로컬 답변")])
        XCTAssertEqual(requests[1].1, "두 번째 질문")
        XCTAssertEqual(ConversationStore(directory: directory).load().first?.provider, .localLLM)
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testInterruptKeepsPartialReply() async throws {
        model = try makeModel(FakeLocalLLM(slow: true))
        await model.newConversation(provider: .localLLM)
        model.draft = "시작"
        await model.send()
        let deadline = Date().addingTimeInterval(3)
        while !model.entries.contains(where: { $0.kind == .assistant }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await model.interrupt()
        try await waitForEnd()
        XCTAssertEqual(model.progress.state, .interrupted)
        XCTAssertEqual(model.entries.last?.text, "로컬")
        XCTAssertFalse(model.entries.contains { $0.isStreaming || $0.kind == .error })
    }

    func testFailureDoesNotFallBackToPaidAPIEvenWhenKeysExist() async throws {
        model = try makeModel(FakeLocalLLM(fails: true))
        model.saveClaudeAPIKey("sk-fake-local-no-fallback")
        model.saveOpenAIAPIKey("sk-fake-local-openai")
        model.preferredNewConversationProvider = .localLLM
        await model.newConversation(provider: .localLLM)
        model.draft = "실패 시험"
        await model.send()
        try await waitForEnd()
        XCTAssertEqual(model.progress.state, .failed)
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertFalse(model.entries.contains { $0.text.contains("unsafe remote-looking") })
        model.deleteLocalModel()
        XCTAssertEqual(model.defaultNewConversationProvider, .localLLM)
        let count = model.conversations.count
        await model.newConversation(provider: model.defaultNewConversationProvider)
        XCTAssertEqual(model.conversations.count, count, "모델이 없어도 API 대화로 전환하지 않습니다")
    }

    func testRejectsAttachmentsLongContextAndRelayBeforeInference() async throws {
        let engine = FakeLocalLLM()
        model = try makeModel(engine)
        await model.newConversation(provider: .localLLM)
        model.draft = String(repeating: "가", count: 8_001)
        await model.send()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.notice?.contains("8,000") == true)
        model.draft = "작업"
        await model.startRelay()
        XCTAssertFalse(model.relayIsActive)
        XCTAssertTrue(model.notice?.contains("릴레이") == true)
        let imageURL = directory.appendingPathComponent("test.png")
        try Data([1, 2]).write(to: imageURL)
        model.addAttachments(urls: [imageURL])
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertEqual(model.pasteAttachments(), 0)
        XCTAssertTrue(model.notice?.contains("글로만") == true)
        model.pendingAttachments = [Attachment(id: "fake", name: "test.png", kind: .png, path: imageURL.path, byteCount: 2)]
        await model.send()
        XCTAssertTrue(model.notice?.contains("첨부") == true)
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLocalReplyDoesNotCreateFilesFromFileBlocksAndDeletionPreservesChat() async throws {
        model = try makeModel(FakeLocalLLM(output: "\n```file: surprise.txt\nhello\n```"))
        await model.newConversation(provider: .localLLM)
        model.draft = "답변"
        await model.send()
        try await waitForEnd()
        XCTAssertTrue(model.selectedConversation?.receivedFiles.isEmpty == true)
        model.deleteLocalModel()
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.localModelReady)
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertTrue(model.entries.contains { $0.kind == .assistant })
    }
}
