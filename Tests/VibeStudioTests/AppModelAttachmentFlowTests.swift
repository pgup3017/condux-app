import XCTest
@testable import Condux

/// 첨부가 각 API 요청에 실려 가고, 답변의 ```file: 블록이 ‘받은 파일’ 항목이 되는지 (가짜 전송).
@MainActor
final class AppModelAttachmentFlowTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var transport: FakeAPITransport!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("condux-attach-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "condux-attach-flow-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        transport = FakeAPITransport()
        model = AppModel(store: ConversationStore(directory: directory.appendingPathComponent("store")), defaults: defaults,
                         secrets: InMemorySecretStore(), apiTransport: transport)
        model.saveClaudeAPIKey("sk-claude-test")
        model.saveOpenAIAPIKey("sk-openai-test")
    }

    override func tearDownWithError() throws {
        model.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "조건이 시간 안에 만족되지 않았습니다. 진행: \(model.progress.phase) / 알림: \(model.notice ?? "-")")
    }

    private func sendAndWait() async throws {
        await model.send()
        try await waitUntil { !self.model.progress.isBusy }
    }

    private static func claudeReply(_ text: String) -> [String] {
        let json = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return FakeAPITransport.sse([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":20,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(json)}}"),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":30}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
    }

    func testClaudeAPISendsImageBlockAndKeepsPlaceholderInTranscript() async throws {
        let png = directory.appendingPathComponent("shot.png")
        try TestFiles.png(at: png)
        transport.responseQueue = [FakeAPITransport.happyTurn, FakeAPITransport.happyTurn]
        await model.newConversation(provider: .claudeAPI)
        model.addAttachments(urls: [png])
        XCTAssertEqual(model.pendingAttachments.count, 1)
        model.draft = "이 그림 무슨 색이야?"
        try await sendAndWait()
        XCTAssertEqual(model.progress.state, .completed)
        XCTAssertTrue(model.pendingAttachments.isEmpty, "보낸 뒤 칩은 비워집니다")

        let body = try JSONValue.parse(try XCTUnwrap(transport.requests[0].httpBody))
        let content = try XCTUnwrap(body["messages"]?[0]?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["text"]?.stringValue, "이 그림 무슨 색이야?")
        XCTAssertEqual(content[1]["type"]?.stringValue, "image")
        XCTAssertEqual(content[1]["source"]?["data"]?.stringValue, try Data(contentsOf: png).base64EncodedString())
        // 전사본과 저장 파일에는 자리표시자만 (base64 없음)
        let transcript = try XCTUnwrap(model.selectedConversation?.apiTranscript)
        XCTAssertEqual(transcript[0]["content"]?[1]?["type"]?.stringValue, "condux_attachment")
        XCTAssertEqual(model.entries.first { $0.kind == .user }?.attachmentNames, ["shot.png"])
        XCTAssertEqual(model.entries.first { $0.kind == .user }?.attachmentPaths.count, 1, "미리보기용 복사본 경로를 함께 저장")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.entries.first { $0.kind == .user }?.attachmentPaths.first ?? ""))

        // 두 번째 턴에도 이미지가 다시 실려 갑니다.
        model.draft = "다시 말해 줘"
        try await sendAndWait()
        let body2 = try JSONValue.parse(try XCTUnwrap(transport.requests[1].httpBody))
        XCTAssertEqual(body2["messages"]?[0]?["content"]?[1]?["type"]?.stringValue, "image")
        XCTAssertEqual(body2["messages"]?.arrayValue?.count, 3)
    }

    func testOpenAISendsPDFAsInputFile() async throws {
        let pdf = directory.appendingPathComponent("spec.pdf")
        try TestFiles.pdf(at: pdf, text: "Spec v1")
        transport.responseQueue = [OpenAIAPIClientTests.happyTurn]
        await model.newConversation(provider: .openAIAPI)
        model.addAttachments(urls: [pdf])
        model.draft = ""
        try await sendAndWait()
        XCTAssertEqual(model.progress.state, .completed, model.progress.phase)
        let body = try JSONValue.parse(try XCTUnwrap(transport.requests[0].httpBody))
        let content = try XCTUnwrap(body["input"]?[0]?["content"]?.arrayValue)
        XCTAssertEqual(content[0]["text"]?.stringValue, "첨부한 파일을 확인해 주세요.", "빈 입력이면 기본 문장을 넣습니다")
        XCTAssertEqual(content[1]["type"]?.stringValue, "input_file")
        XCTAssertEqual(content[1]["filename"]?.stringValue, "spec.pdf")
        XCTAssertTrue(body["instructions"]?.stringValue?.contains("```file:") ?? false, "파일 블록 안내가 지시문에 들어갑니다")
    }

    func testFileBlockInReplyBecomesReceivedFile() async throws {
        transport.responseQueue = [Self.claudeReply("요청한 파일입니다.\n\n```file:hello.txt\n안녕하세요\n```\n")]
        await model.newConversation(provider: .claudeAPI)
        let id = try XCTUnwrap(model.selectedID)
        model.draft = "hello.txt 만들어 줘"
        try await sendAndWait()
        XCTAssertEqual(model.progress.state, .completed)

        let fileEntry = try XCTUnwrap(model.entries.last { $0.kind == .file })
        XCTAssertEqual(fileEntry.title, "hello.txt")
        XCTAssertEqual(try String(contentsOfFile: fileEntry.text), "안녕하세요\n")
        let outputs = model.attachmentStore.outputsDirectory(for: id).resolvingSymlinksInPath().path
        XCTAssertTrue(URL(fileURLWithPath: fileEntry.text).resolvingSymlinksInPath().path.hasPrefix(outputs), fileEntry.text)
        XCTAssertEqual(model.selectedConversation?.receivedFiles.map(\.name), ["hello.txt"])

        // 다시 읽어도 항목과 기록이 남습니다.
        let reloaded = ConversationStore(directory: directory.appendingPathComponent("store")).load()
        XCTAssertEqual(reloaded.first?.receivedFiles.first?.name, "hello.txt")
        XCTAssertEqual(reloaded.first?.messages.last?.role, .file)
        XCTAssertEqual(reloaded.first?.messages.first { $0.role == .user }?.attachmentNames, nil)
        XCTAssertEqual(reloaded.first?.messages.first { $0.role == .user }?.attachmentPaths, nil)
    }

    func testPasteFromPasteboardAttachesImageOrFile() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("condux-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        await model.newConversation(provider: .claudeAPI)

        // 1) 이미지(스크린샷을 복사한 경우)
        let png = directory.appendingPathComponent("shot.png")
        try TestFiles.png(at: png, size: 16)
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(contentsOf: png)!])
        XCTAssertEqual(model.pasteAttachments(from: pasteboard), 1)
        XCTAssertEqual(model.pendingAttachments.last?.kind, .png)
        XCTAssertTrue(model.pendingAttachments.last?.name.hasPrefix("붙여넣은 이미지") ?? false)
        XCTAssertNotNil(NSImage(contentsOfFile: model.pendingAttachments.last?.path ?? ""))

        // 2) 파일(Finder 에서 복사한 경우)
        let pdf = directory.appendingPathComponent("doc.pdf")
        try TestFiles.pdf(at: pdf, text: "x")
        pasteboard.clearContents()
        pasteboard.writeObjects([pdf as NSURL])
        XCTAssertEqual(model.pasteAttachments(from: pasteboard), 1)
        XCTAssertEqual(model.pendingAttachments.last?.kind, .pdf)

        // 3) 아무것도 없을 때
        pasteboard.clearContents()
        XCTAssertEqual(model.pasteAttachments(from: pasteboard), 0)
        XCTAssertTrue(model.notice?.contains("클립보드에 이미지나 파일이 없습니다") ?? false)
    }

    func testUnsupportedDropShowsNoticeAndKeepsOthers() async throws {
        let png = directory.appendingPathComponent("a.png")
        try TestFiles.png(at: png)
        let txt = directory.appendingPathComponent("b.txt")
        try "x".write(to: txt, atomically: true, encoding: .utf8)
        await model.newConversation(provider: .claudeAPI)
        model.addAttachments(urls: [png, txt])
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["a.png"])
        XCTAssertTrue(model.notice?.contains("b.txt") ?? false)
        model.removeAttachment(id: model.pendingAttachments[0].id)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
    }
}
