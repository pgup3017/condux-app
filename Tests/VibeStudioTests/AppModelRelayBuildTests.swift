import XCTest
@testable import Condux

/// 작업 폴더 릴레이: 구현(가짜 Claude CLI) 턴이 끝나면 진짜 `swift build` 를 돌리고,
/// 실패하면 검토자(API) 없이 오류를 바로 수정 요청으로 보내는지.
@MainActor
final class AppModelRelayBuildTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var transport: FakeAPITransport!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("condux-relay-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-claude")
        try TestFiles.fakeClaudeCLI(at: executable)
        suiteName = "condux-relay-build-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        transport = FakeAPITransport()
        model = AppModel(store: ConversationStore(directory: directory.appendingPathComponent("store")), defaults: defaults,
                         secrets: InMemorySecretStore(), apiTransport: transport)
        model.claudePathOverride = executable.path
        model.saveOpenAIAPIKey("sk-openai-test")
    }

    override func tearDownWithError() throws {
        model.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ timeout: TimeInterval = 120, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition(), "조건이 시간 안에 만족되지 않았습니다. 릴레이: \(model.relay?.statusText ?? "-") / 진행: \(model.progress.phase) / 알림: \(model.notice ?? "-") / 인증: \(model.claudeAuth.label) / 대화: \(model.selectedID ?? "-")")
    }

    /// 기계가 바쁠 때 가짜 CLI 의 상태 확인이 늦어질 수 있어 세 번까지 시도합니다.
    private func logIn() async {
        for _ in 0..<3 where !model.claudeAuth.isLoggedIn { await model.refreshClaudeAuth() }
    }

    private func makePackage(broken: Bool) throws -> URL {
        let pkg = directory.appendingPathComponent("Pkg")
        let sources = pkg.appendingPathComponent("Sources/Pkg")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Pkg", targets: [.target(name: "Pkg")])
        """.write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try (broken ? "let x: Int = \"문자열\"\n" : "let x: Int = 1\n").write(to: sources.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        return pkg
    }

    func testBuildFailureSkipsReviewerAndFeedsErrorsBack() async throws {
        let pkg = try makePackage(broken: true)
        await logIn()
        model.workspacePath = pkg.path
        model.relayReviewer = .openAIAPI
        model.relayMaxRounds = 2
        model.relayAutoBuild = true
        await model.newConversation(provider: .claude)
        model.draft = "빌드가 되게 고쳐 줘"
        await model.startRelay()
        try await waitUntil { self.model.relay?.phase == .done || self.model.relay?.phase == .stopped }

        let state = try XCTUnwrap(model.relay)
        XCTAssertEqual(state.phase, .done, state.summary)
        XCTAssertTrue(state.summary.contains("빌드 실패"), state.summary)
        XCTAssertEqual(transport.requests.count, 0, "빌드가 실패하면 검토자를 부르지 않습니다")
        XCTAssertEqual(model.entries.filter { $0.title.hasPrefix("빌드 결과") }.count, 2, "라운드마다 빌드")
        let failures = model.entries.filter { $0.title.hasPrefix("릴레이 · 빌드 실패") }
        XCTAssertEqual(failures.count, 2, "라운드마다 실패 항목")
        XCTAssertTrue(failures[0].title.contains("→ 수정 요청"), failures[0].title)
        XCTAssertTrue(failures[1].title.contains("마지막"), failures[1].title)
        let fixRequest = try XCTUnwrap(model.entries.filter { $0.kind == .user }.dropFirst().first)
        XCTAssertTrue(fixRequest.text.hasPrefix("빌드가 실패했습니다."), fixRequest.text)
        XCTAssertTrue(fixRequest.text.contains("A.swift"))
    }

    func testBuildSuccessGoesToReviewer() async throws {
        let pkg = try makePackage(broken: false)
        transport.responseQueue = [OpenAIAPIClientTests.happyTurn]
        await logIn()
        model.workspacePath = pkg.path
        model.relayReviewer = .openAIAPI
        model.relayMaxRounds = 1
        await model.newConversation(provider: .claude)
        XCTAssertNotNil(model.selectedID, "대화 생성 실패: \(model.notice ?? "-") / \(model.claudeAuth.label)")
        model.draft = "확인만 해 줘"
        await model.startRelay()
        XCTAssertNotNil(model.relay, "릴레이 시작 실패: \(model.notice ?? "-")")
        try await waitUntil { self.model.relay?.phase == .done || self.model.relay?.phase == .stopped }
        XCTAssertEqual(transport.requests.count, 1, "빌드가 성공하면 검토자에게 갑니다")
        let body = try JSONValue.parse(try XCTUnwrap(transport.requests[0].httpBody))
        let reviewText = body["input"]?[0]?["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(reviewText.contains("빌드 결과 · 성공"), reviewText)
    }
}
