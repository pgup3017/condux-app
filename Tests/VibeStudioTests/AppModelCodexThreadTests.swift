import XCTest
@testable import Condux

/// 앱을 다시 띄운 뒤, 턴이 없던 Codex 대화(서버에 저장되지 않음)를 보내려 할 때
/// thread/resume 실패 → 새 thread/start 로 같은 대화를 다시 여는지 가짜 app-server 로 확인합니다.
@MainActor
final class AppModelCodexThreadTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("condux-codex-thread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex")
        // resume 은 항상 실패, thread/start 는 매번 새 ID, turn/start 는 바로 완료 알림을 보냅니다.
        let fixture = #"""
        #!/bin/sh
        exec /usr/bin/python3 -u -c '
        import json, sys, os
        counter = 0
        for line in sys.stdin:
            obj = json.loads(line)
            method = obj.get("method"); rid = obj.get("id")
            if rid is None:
                continue
            if method == "initialize":
                print(json.dumps({"id": rid, "result": {"userAgent": "fake app-server"}}), flush=True)
            elif method == "account/read":
                print(json.dumps({"id": rid, "result": {"account": {"type": "chatgpt", "email": "t@example.com", "planType": "plus"}}}), flush=True)
            elif method == "thread/start":
                counter += 1
                print(json.dumps({"id": rid, "result": {"thread": {"id": "thread-%d-%d" % (os.getpid(), counter)}}}), flush=True)
            elif method == "thread/resume":
                print(json.dumps({"id": rid, "error": {"code": -32000, "message": "no rollout found for thread " + obj["params"]["threadId"]}}), flush=True)
            elif method == "turn/start":
                tid = obj["params"]["threadId"]
                print(json.dumps({"id": rid, "result": {"turn": {"id": "turn-1"}}}), flush=True)
                print(json.dumps({"method": "item/completed", "params": {"threadId": tid, "turnId": "turn-1", "item": {"id": "m1", "type": "agentMessage", "text": "답: " + tid}}}), flush=True)
                print(json.dumps({"method": "turn/completed", "params": {"threadId": tid, "turn": {"id": "turn-1", "status": "completed"}}}), flush=True)
            else:
                print(json.dumps({"id": rid, "result": {}}), flush=True)
        '
        """#
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        suiteName = "condux-codex-thread-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        model = AppModel(store: ConversationStore(directory: directory.appendingPathComponent("store")), defaults: defaults,
                         secrets: InMemorySecretStore(), apiTransport: FakeAPITransport())
        model.codexPathOverride = executable.path
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

    func testEmptyConversationIsReopenedAsNewThreadAfterRestart() async throws {
        await model.connect()
        XCTAssertTrue(model.connection.isConnected, model.connection.label)
        model.workspacePath = directory.path
        await model.newConversation(provider: .codex)
        let firstID = try XCTUnwrap(model.selectedID)
        XCTAssertTrue(firstID.hasPrefix("thread-"))

        // 앱 재시작을 흉내: 연결을 끊었다 다시 맺으면 서버는 빈 스레드를 모릅니다.
        model.disconnect()
        await model.connect()
        let secondID = try XCTUnwrap(model.selectedID)
        XCTAssertNotEqual(secondID, firstID, "빈 대화는 새 스레드로 다시 열려야 합니다")
        XCTAssertEqual(model.conversations[0].id, secondID)
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertEqual(model.conversations[0].workspacePath, directory.path, "작업 폴더는 유지")
        XCTAssertNil(model.notice, "조용히 다시 열리고 오류 띠는 없어야 합니다")

        model.draft = "안녕"
        await model.send()
        try await waitUntil { !self.model.progress.isBusy }
        XCTAssertEqual(model.progress.state, .completed, model.progress.phase)
        XCTAssertEqual(model.entries.last?.text, "답: \(secondID)")
        XCTAssertEqual(model.conversations[0].messages.filter { $0.role == .user }.count, 1)
    }

    func testConversationWithTurnsKeepsIDAndShowsRealError() async throws {
        await model.connect()
        model.workspacePath = directory.path
        await model.newConversation(provider: .codex)
        model.draft = "안녕"
        await model.send()
        try await waitUntil { !self.model.progress.isBusy }
        let firstID = try XCTUnwrap(model.selectedID)

        model.disconnect()
        await model.connect()
        XCTAssertEqual(model.selectedID, firstID, "턴이 있던 대화는 ID 를 바꾸지 않습니다")
        XCTAssertTrue(model.notice?.contains("no rollout found") ?? false, model.notice ?? "-")

        model.draft = "또"
        await model.send()
        XCTAssertFalse(model.progress.isBusy)
        XCTAssertTrue(model.notice?.contains("no rollout found") ?? false, "실제 원인이 다른 문구로 덮이면 안 됩니다: \(model.notice ?? "-")")
    }
}
