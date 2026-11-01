import XCTest
@testable import Condux

/// 설치된 진짜 Claude Code CLI 와 사용자의 구독으로 AppModel 전체 흐름을 한 번 돌려 봅니다.
/// 구독 사용량을 조금 쓰므로 기본으로는 건너뛰고, `CONDUX_REAL_CLAUDE=1` 일 때만 실행합니다.
/// 실제 설정·기록 파일은 건드리지 않습니다(임시 폴더·임시 UserDefaults 사용).
@MainActor
final class RealClaudeIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUX_REAL_CLAUDE"] == "1",
                          "CONDUX_REAL_CLAUDE=1 일 때만 실제 Claude Code 를 호출합니다")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("condux-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "condux-real-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        model = AppModel(store: ConversationStore(directory: directory), defaults: defaults)
        model.claudeModel = "haiku" // 가장 가벼운 모델로 구독 사용을 최소화
        model.claudeEffort = "low"
    }

    override func tearDownWithError() throws {
        guard model != nil else { return }
        model.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ timeout: TimeInterval = 90, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "조건이 시간 안에 만족되지 않았습니다. 진행: \(model.progress.phase) / 알림: \(model.notice ?? "-")")
    }

    func testRealTurnInterruptAndResume() async throws {
        await model.refreshClaudeAuth()
        guard model.claudeAuth.isLoggedIn else { throw XCTSkip("Claude 에 로그인되어 있지 않습니다: \(model.claudeAuth.label)") }

        await model.newConversation(provider: .claude)
        let id = try XCTUnwrap(model.selectedID)

        // 1) 짧은 답변
        model.draft = "내 암호 단어는 '노란우산'이야. '알겠어'라고만 답해."
        await model.send()
        try await waitUntil { self.model.progress.state == .completed || self.model.progress.state == .failed }
        XCTAssertEqual(model.progress.state, .completed, model.entries.last?.text ?? "")
        let firstAnswer = model.entries.last { $0.kind == .assistant }?.text ?? ""
        XCTAssertFalse(firstAnswer.isEmpty)
        XCTAssertTrue(model.conversations.first?.claudeSessionReady ?? false)
        XCTAssertFalse(model.claudeUsageSummary.isEmpty, "rate_limit_event 로 사용량이 와야 합니다")

        // 2) 긴 답변 중 중단
        model.draft = "1부터 400까지 숫자를 한 줄에 하나씩 전부 써 줘."
        await model.send()
        try await waitUntil(60) { self.model.entries.last?.kind == .assistant && !(self.model.entries.last?.text.isEmpty ?? true) }
        await model.interrupt()
        try await waitUntil(60) { !self.model.progress.isBusy }
        XCTAssertEqual(model.progress.state, .interrupted, model.progress.phase)

        // 3) 다른 대화로 갔다가 돌아와(프로세스 재시작, --resume) 이전 내용을 기억하는지
        model.select(nil)
        model.select(id)
        model.draft = "내 암호 단어가 뭐였지? 단어만 답해."
        await model.send()
        try await waitUntil { self.model.progress.state == .completed || self.model.progress.state == .failed }
        XCTAssertEqual(model.progress.state, .completed, model.entries.last?.text ?? "")
        let recalled = model.entries.last { $0.kind == .assistant }?.text ?? ""
        XCTAssertTrue(recalled.contains("노란우산"), "이어가기 뒤 답변: \(recalled)")
        print("REAL-CLAUDE OK · 모델 \(model.claudeModelName) · \(model.claudeUsageSummary) · \(model.tokenSummary)")
    }

    /// 작업 폴더 모드: 진짜 CLI 가 파일을 만들려 할 때 승인 카드가 뜨고, 허용하면 파일이 생기며, 되돌리면 지워지는지.
    /// Figma 원격 서버: 사용자가 터미널에서 로그인한 뒤 앱이 넘긴 설정으로 connected 가 되는지 (도구 호출 없음).
    func testRealFigmaMCPIsConnectedAfterTerminalLogin() async throws {
        await model.refreshClaudeAuth()
        guard model.claudeAuth.isLoggedIn else { throw XCTSkip("Claude 에 로그인되어 있지 않습니다") }
        model.addMCPServer(MCPServer.figmaRemote)
        await model.newConversation(provider: .claude)
        model.draft = "사용할 수 있는 figma 도구 이름을 쉼표로만 나열해. 도구를 호출하지는 마."
        await model.send()
        try await waitUntil(120) { !self.model.progress.isBusy }
        XCTAssertEqual(model.progress.state, .completed, model.entries.last?.text ?? "")
        print("REAL-FIGMA 상태:", model.claudeMCPStatus, "· 답:", (model.entries.last { $0.kind == .assistant }?.text ?? "").prefix(300))
        XCTAssertEqual(model.claudeMCPStatus["figma"], "connected", "\(model.claudeMCPStatus) / 알림: \(model.notice ?? "-")")
    }

    /// 이 Mac 의 Claude Code 에 Mobbin 로그인이 돼 있다는 전제에서: 텍스트 대화에서 MCP 도구를 승인 없이(자동 허용) 호출하는지.
    func testRealMobbinMCPToolInTextConversation() async throws {
        await model.refreshClaudeAuth()
        guard model.claudeAuth.isLoggedIn else { throw XCTSkip("Claude 에 로그인되어 있지 않습니다") }
        model.addMCPServer(MCPServer.mobbin)
        await model.newConversation(provider: .claude)
        model.draft = "mobbin 의 search_screens 도구를 꼭 한 번 호출해서 login 화면을 1개만 검색하고, 결과에서 앱 이름 하나만 말해. 다른 설명은 하지 마."
        await model.send()
        try await waitUntil(150) { !self.model.progress.isBusy }
        XCTAssertEqual(model.progress.state, .completed, model.entries.last?.text ?? "")
        XCTAssertEqual(model.claudeMCPStatus["mobbin"], "connected", "\(model.claudeMCPStatus)")
        XCTAssertFalse(model.entries.contains { $0.kind == .approval }, "자동 허용 서버는 승인 카드가 없어야 합니다")
        XCTAssertTrue(model.entries.contains { $0.kind == .activity && $0.title.contains("mcp__mobbin__search_screens") },
                      model.entries.map(\.title).joined(separator: " | "))
        let answer = model.entries.last { $0.kind == .assistant }?.text ?? ""
        let received = model.selectedConversation?.receivedFiles ?? []
        XCTAssertFalse(received.isEmpty, "Mobbin 검색 결과의 스크린샷 이미지가 받은 파일로 저장돼야 합니다")
        XCTAssertTrue(model.entries.contains { $0.kind == .file }, "받은 파일 항목(미리보기)이 생겨야 합니다")
        print("REAL-MCP OK · 상태:", model.claudeMCPStatus, "· 답:", answer.prefix(80), "· 받은 파일:", received.map(\.name))
    }

    /// 텍스트 전용 대화에 PNG(image 블록)와 PDF(document 블록)를 붙여 CLI 가 그대로 전달하는지.
    func testRealTextOnlyTurnSeesImageAndPDF() async throws {
        await model.refreshClaudeAuth()
        guard model.claudeAuth.isLoggedIn else { throw XCTSkip("Claude 에 로그인되어 있지 않습니다") }
        let png = directory.appendingPathComponent("red.png")
        try TestFiles.png(at: png, color: .red, size: 120)
        let pdf = directory.appendingPathComponent("memo.pdf")
        try TestFiles.pdf(at: pdf, text: "Password word: BANANA77")
        await model.newConversation(provider: .claude)
        model.addAttachments(urls: [png, pdf])
        XCTAssertEqual(model.pendingAttachments.count, 2, model.notice ?? "")
        model.draft = "첨부한 이미지는 무슨 색 한 가지로 채워져 있어? 그리고 PDF 에 적힌 Password word 는 뭐야? 두 답만 짧게."
        await model.send()
        try await waitUntil(120) { !self.model.progress.isBusy }
        XCTAssertEqual(model.progress.state, .completed, model.entries.last?.text ?? "")
        let answer = model.entries.last { $0.kind == .assistant }?.text ?? ""
        print("REAL-ATTACH ANSWER:", answer)
        XCTAssertTrue(answer.contains("빨") || answer.lowercased().contains("red"), answer)
        XCTAssertTrue(answer.contains("BANANA77"), answer)
    }

    /// 작업 폴더 대화에서 ZIP 은 경로로 전달되고, ‘받은 파일’ 폴더에 쓴 파일이 항목으로 나타나는지.
    func testRealWorkspaceReceivesFileFromOutputsFolder() async throws {
        await model.refreshClaudeAuth()
        guard model.claudeAuth.isLoggedIn else { throw XCTSkip("Claude 에 로그인되어 있지 않습니다") }
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let zip = directory.appendingPathComponent("bundle.zip")
        try TestFiles.zip(at: zip, files: ["notes.txt": "secret code 4242"])
        model.workspacePath = workspace.path
        await model.newConversation(provider: .claude)
        let id = try XCTUnwrap(model.selectedID)
        model.addAttachments(urls: [zip])
        model.draft = "첨부한 ZIP 안 notes.txt 의 secret code 를 읽어서, 사용자에게 줄 파일 폴더에 answer.md 라는 파일로 그 코드만 써서 저장해 줘. Write 도구를 쓰고 설명은 한 문장만."
        await model.send()
        var approvals = 0
        for _ in 0..<6 {
            try await waitUntil(120) { self.model.hasPendingApproval || !self.model.progress.isBusy }
            guard model.hasPendingApproval, let approval = model.entries.last(where: { $0.kind == .approval && $0.isPendingApproval }) else { break }
            print("REAL-ATTACH APPROVAL:", approval.title)
            model.approve(entryID: approval.id)
            approvals += 1
        }
        try await waitUntil(120) { !self.model.progress.isBusy }
        XCTAssertEqual(model.progress.state, .completed, model.progress.phase)
        let received = model.selectedConversation?.receivedFiles ?? []
        XCTAssertEqual(received.map(\.name), ["answer.md"], model.entries.last?.text ?? "")
        let content = (try? String(contentsOfFile: received.first?.path ?? "")) ?? ""
        XCTAssertTrue(content.contains("4242"), content)
        XCTAssertEqual(model.entries.last { $0.kind == .file }?.title, "answer.md")
        XCTAssertTrue(received.first?.path.contains(model.attachmentStore.outputsDirectory(for: id).lastPathComponent) ?? false)
        print("REAL-ATTACH-WORKSPACE OK · 승인 \(approvals)회 · 받은 파일:", received.first?.path ?? "-")
    }

    func testRealWorkspaceWriteNeedsApprovalAndCanBeReverted() async throws {
        await model.refreshClaudeAuth()
        guard model.claudeAuth.isLoggedIn else { throw XCTSkip("Claude 에 로그인되어 있지 않습니다") }
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        model.workspacePath = workspace.path
        await model.newConversation(provider: .claude)
        XCTAssertTrue(model.selectedConversation?.hasWorkspace ?? false)

        model.draft = "현재 작업 폴더에 hello.txt 파일을 만들고 내용은 정확히 hi 로 해 줘. Write 도구를 써. 설명은 한 문장만."
        await model.send()
        try await waitUntil(120) { self.model.hasPendingApproval || !self.model.progress.isBusy }
        guard model.hasPendingApproval else {
            XCTFail("승인 요청이 오지 않았습니다. 진행: \(model.progress.phase) / 마지막: \(model.entries.last?.text ?? "")"); return
        }
        let approval = try XCTUnwrap(model.entries.last { $0.kind == .approval && $0.isPendingApproval })
        XCTAssertTrue(approval.title.contains("Write") || approval.title.contains("Edit"), approval.title)
        let file = workspace.appendingPathComponent("hello.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "허용 전에는 파일이 생기면 안 됩니다")

        model.approve(entryID: approval.id)
        try await waitUntil(120) { !self.model.progress.isBusy }
        XCTAssertEqual(model.progress.state, .completed, model.progress.phase)
        XCTAssertEqual(try String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines), "hi")

        let record = try XCTUnwrap(model.selectedConversation?.changeRecords.first)
        XCTAssertNil(record.backupPath, "새 파일이므로 백업 없음")
        model.revert(changeRecordID: record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "되돌리기는 새 파일을 지웁니다")
        print("REAL-WORKSPACE OK · 승인 → 파일 생성 → 되돌리기")
    }
}
