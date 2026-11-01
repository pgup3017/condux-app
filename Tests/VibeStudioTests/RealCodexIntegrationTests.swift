import XCTest
@testable import Condux

/// 설치된 진짜 Codex app-server 와 사용자의 ChatGPT 로그인으로 작업 폴더 모드(승인 → 파일 생성 → 되돌리기)를 한 번 돌려 봅니다.
/// 구독 사용량을 조금 쓰므로 기본으로는 건너뛰고, `CONDUX_REAL_CODEX=1` 일 때만 실행합니다.
@MainActor
final class RealCodexIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUX_REAL_CODEX"] == "1",
                          "CONDUX_REAL_CODEX=1 일 때만 실제 Codex 를 호출합니다")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("condux-real-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "condux-real-codex-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        model = AppModel(store: ConversationStore(directory: directory), defaults: defaults)
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
        XCTAssertTrue(condition(), "조건이 시간 안에 만족되지 않았습니다. 진행: \(model.progress.phase) / 알림: \(model.notice ?? "-") / 마지막: \(model.entries.last?.text.prefix(200) ?? "")")
    }

    /// 모델 호출 없음: 빈 스레드는 Codex 가 저장하지 않으므로 app-server 를 다시 띄우면 resume 이 실패하고, 앱이 새 스레드로 다시 열어야 합니다.
    func testRealEmptyThreadIsReopenedAfterServerRestart() async throws {
        await model.connect()
        guard model.connection.isConnected, model.isLoggedIn else { throw XCTSkip("Codex 연결/로그인 안 됨: \(model.connection.label)") }
        model.workspacePath = directory.path
        await model.newConversation(provider: .codex)
        let firstID = try XCTUnwrap(model.selectedID)
        model.disconnect()
        await model.connect()
        XCTAssertTrue(model.connection.isConnected)
        let secondID = try XCTUnwrap(model.selectedID)
        XCTAssertNotEqual(secondID, firstID, "빈 스레드는 새 ID 로 다시 열려야 합니다. 알림: \(model.notice ?? "-")")
        XCTAssertNil(model.notice, model.notice ?? "")
        print("REAL-CODEX-REKEY OK ·", firstID, "→", secondID)
    }

    /// MCP 서버를 `-c` 로 넘겨 app-server 를 띄우고 `mcpServerStatus/list` 로 상태를 읽는지 (모델 호출 없음).
    func testRealMCPServerStatusIsRead() async throws {
        model.addMCPServer(MCPServer.mobbin)
        await model.connect()
        guard model.connection.isConnected else { throw XCTSkip("Codex 연결 안 됨: \(model.connection.label)") }
        let status = model.codexMCPStatus["mobbin"]
        XCTAssertNotNil(status, "\(model.codexMCPStatus)")
        print("REAL-CODEX-MCP OK · mobbin:", status ?? "-")
    }

    /// 이미지는 localImage 로 전달되고, writableRoots 로 열어 둔 ‘받은 파일’ 폴더에 쓴 파일이 항목이 되는지.
    func testRealWorkspaceImageAndOutputsFolder() async throws {
        await model.connect()
        guard model.connection.isConnected, model.isLoggedIn else { throw XCTSkip("Codex 연결/로그인 안 됨: \(model.connection.label)") }
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let png = directory.appendingPathComponent("blue.png")
        try TestFiles.png(at: png, color: .blue, size: 120)
        model.workspacePath = workspace.path
        await model.newConversation(provider: .codex)
        model.addAttachments(urls: [png])
        model.draft = "첨부한 이미지가 무슨 색 한 가지로 채워져 있는지 한 단어로 답하고, 같은 단어를 사용자에게 줄 파일 폴더에 color.txt 로 저장해 줘. 설명은 한 문장만."
        await model.send()
        var approvals = 0
        for _ in 0..<6 {
            try await waitUntil(180) { self.model.hasPendingApproval || !self.model.progress.isBusy }
            guard model.hasPendingApproval, let approval = model.entries.last(where: { $0.kind == .approval && $0.isPendingApproval }) else { break }
            print("REAL-CODEX-ATTACH APPROVAL:", approval.title, "|", approval.text.prefix(200))
            model.approve(entryID: approval.id)
            approvals += 1
        }
        try await waitUntil(180) { !self.model.progress.isBusy }
        XCTAssertEqual(model.progress.state, .completed, model.progress.phase)
        let answer = model.entries.last { $0.kind == .assistant }?.text ?? ""
        print("REAL-CODEX-ATTACH ANSWER:", answer)
        XCTAssertTrue(answer.contains("파") || answer.lowercased().contains("blue"), answer)
        let received = model.selectedConversation?.receivedFiles ?? []
        XCTAssertEqual(received.map(\.name), ["color.txt"], model.entries.last?.text ?? "")
        let content = (try? String(contentsOfFile: received.first?.path ?? "")) ?? ""
        XCTAssertTrue(content.contains("파") || content.lowercased().contains("blue"), content)
        print("REAL-CODEX-ATTACH OK · 승인 \(approvals)회 ·", received.first?.path ?? "-")
    }

    func testRealWorkspaceFileChangeNeedsApprovalAndCanBeReverted() async throws {
        await model.connect()
        guard model.connection.isConnected, model.isLoggedIn else { throw XCTSkip("Codex 연결/로그인 안 됨: \(model.connection.label) / \(model.accountSummary)") }
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        model.workspacePath = workspace.path
        await model.newConversation(provider: .codex)
        XCTAssertTrue(model.selectedConversation?.hasWorkspace ?? false, model.notice ?? "")

        model.draft = "현재 작업 폴더에 hello.txt 파일을 만들고 내용은 정확히 hi 로 해 줘. 설명은 한 문장만."
        await model.send()
        try await waitUntil(180) { self.model.hasPendingApproval || !self.model.progress.isBusy }
        guard model.hasPendingApproval else {
            XCTFail("승인 요청이 오지 않았습니다. 진행: \(model.progress.phase) / 마지막: \(model.entries.last?.text ?? "")"); return
        }
        let approval = try XCTUnwrap(model.entries.last { $0.kind == .approval && $0.isPendingApproval })
        print("CODEX APPROVAL:", approval.title, "|", approval.text.prefix(300))
        let file = workspace.appendingPathComponent("hello.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "허용 전에는 파일이 생기면 안 됩니다")

        model.approve(entryID: approval.id)
        try await waitUntil(180) { !self.model.progress.isBusy && !self.model.hasPendingApproval }
        // 명령 실행으로 만들었을 수도 있고 파일 변경으로 만들었을 수도 있습니다. 어느 쪽이든 파일은 생겨야 합니다.
        XCTAssertEqual(model.progress.state, .completed, model.progress.phase)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "허용 후 파일이 생겨야 합니다")
        XCTAssertEqual(try String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines), "hi")

        if let record = model.selectedConversation?.changeRecords.first {
            model.revert(changeRecordID: record.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "파일 변경 승인이었으면 되돌리기가 지웁니다")
            print("REAL-CODEX-WORKSPACE OK · 파일 변경 승인 → 생성 → 되돌리기")
        } else {
            print("REAL-CODEX-WORKSPACE OK · 명령 실행 승인으로 생성 (되돌리기 대상 아님)")
        }
    }
}
