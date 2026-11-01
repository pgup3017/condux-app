import XCTest
@testable import Condux

/// AppModel 이 가짜 Claude CLI 의 이벤트를 화면 항목·진행 상태·저장으로 올바르게 바꾸는지 확인합니다.
/// 실제 Claude Code, 로그인, 네트워크, 실제 설정/기록 파일은 건드리지 않습니다.
@MainActor
final class AppModelClaudeFlowTests: XCTestCase {
    private var directory: URL!
    private var executable: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-claude")
        let fixture = #"""
        #!/bin/sh
        printf '%s\n' "$@" > "$(dirname "$0")/args.txt"
        if [ "$1" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
        if [ "$1" = "auth" ]; then echo '{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max", "email": "x@example.com"}'; exit 0; fi
        exec /usr/bin/python3 -u -c '
        import json, sys
        sid = None
        argv = open(sys.argv[1]).read().split("\n")
        for i, a in enumerate(argv):
            if a in ("--session-id", "--resume"): sid = argv[i+1]
        def out(o): print(json.dumps(o, ensure_ascii=False), flush=True)
        out({"type":"system","subtype":"init","session_id":sid,"model":"fake-model","tools":[],"mcp_servers":[]})
        for line in sys.stdin:
            obj = json.loads(line)
            if obj.get("type") == "user":
                text = obj["message"]["content"][0]["text"]
                out({"type":"system","subtype":"status","status":"requesting","session_id":sid})
                out({"type":"stream_event","session_id":sid,"api_message_id":"msg_1","event":{"type":"message_start"}})
                out({"type":"stream_event","session_id":sid,"api_message_id":"msg_1","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"생각…"}}})
                out({"type":"stream_event","session_id":sid,"api_message_id":"msg_1","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"답"}}})
                if text == "long":
                    nxt = json.loads(sys.stdin.readline())
                    out({"type":"control_response","response":{"subtype":"success","request_id":nxt["request_id"],"response":{}}})
                    out({"type":"result","subtype":"error_during_execution","is_error":True,"terminal_reason":"aborted_streaming","session_id":sid,"result":None})
                    continue
                out({"type":"stream_event","session_id":sid,"api_message_id":"msg_1","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"변"}}})
                out({"type":"assistant","session_id":sid,"message":{"id":"msg_1","role":"assistant","usage":{"input_tokens":4,"cache_read_input_tokens":2,"output_tokens":3},"content":[{"type":"thinking","thinking":"생각…"},{"type":"text","text":"답변"}]}})
                out({"type":"rate_limit_event","session_id":sid,"rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.25},"seven_day":{"utilization":0.5}}}})
                out({"type":"result","subtype":"success","is_error":False,"terminal_reason":"completed","session_id":sid,"result":"답변","usage":{"input_tokens":10,"cache_read_input_tokens":5,"output_tokens":3},"modelUsage":{"fake-model":{"contextWindow":200000}}})
        ' "$(dirname "$0")/args.txt"
        """#
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        suiteName = "condux-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        model = AppModel(store: ConversationStore(directory: directory.appendingPathComponent("store")), defaults: defaults)
        model.claudePathOverride = executable.path
    }

    override func tearDownWithError() throws {
        model.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "조건이 시간 안에 만족되지 않았습니다")
    }

    private func args() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("args.txt")).split(separator: "\n").map(String.init)
    }

    func testClaudeConversationStreamsAndPersists() async throws {
        await model.refreshClaudeAuth()
        XCTAssertTrue(model.claudeAuth.isLoggedIn)
        XCTAssertEqual(model.claudeAuth.label, "Claude 로그인됨 · max 구독 · x@example.com")

        await model.newConversation(provider: .claude)
        XCTAssertEqual(model.selectedProvider, .claude)
        XCTAssertTrue(model.canSend)
        let id = try XCTUnwrap(model.selectedID)

        model.draft = "안녕"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }

        let assistant = model.entries.filter { $0.kind == .assistant }
        XCTAssertEqual(assistant.map(\.text), ["답변"])
        XCTAssertFalse(assistant[0].isStreaming)
        let thinking = model.entries.filter { $0.kind == .activity }
        XCTAssertEqual(thinking.map(\.title), ["생각 정리"])
        XCTAssertEqual(thinking[0].text, "생각…")
        XCTAssertEqual(model.claudeUsageSummary, "구독 사용량 5시간 창 25% · 7일 창 50%")
        XCTAssertEqual(model.tokenSummary, "토큰 입력 15 · 출력 3")
        XCTAssertEqual(model.selectedUsage, ConversationUsage(contextTokens: 9, contextWindow: 200_000, totalInputTokens: 15, totalOutputTokens: 3),
                       "컨텍스트는 턴 합계가 아니라 마지막 메시지 기준")
        XCTAssertEqual(model.usageChipText, "컨텍스트 1%")
        XCTAssertEqual(model.subscriptionUsageSummary, model.claudeUsageSummary)
        XCTAssertEqual(model.claudeModelName, "fake-model")
        XCTAssertEqual(model.conversations.first?.title, "안녕")
        XCTAssertTrue(model.conversations.first?.claudeSessionReady ?? false)
        XCTAssertTrue(try args().contains("--session-id"))

        // 저장 파일에도 provider 와 세션 준비 상태가 남습니다.
        let saved = ConversationStore(directory: directory.appendingPathComponent("store")).load()
        XCTAssertEqual(saved.first?.id, id)
        XCTAssertEqual(saved.first?.provider, .claude)
        XCTAssertEqual(saved.first?.usage.totalInputTokens, 15, "사용량도 저장됩니다")
        XCTAssertTrue(saved.first?.claudeSessionReady ?? false)
        XCTAssertEqual(saved.first?.messages.filter { $0.role == .assistant }.first?.text, "답변")
    }

    func testMacControlConversationUsesOwnFolderAndNeedsApprovals() async throws {
        await model.refreshClaudeAuth()
        model.workspacePath = ""
        model.startMacControlConversation()
        let folder = try XCTUnwrap(model.selectedConversation?.workspacePath)
        XCTAssertTrue(folder.hasSuffix("/mac-control"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder))
        XCTAssertEqual(model.workspacePath, "", "다음 새 대화에는 따라가지 않습니다")

        model.draft = "Chrome 열어 줘"
        await model.send()
        try await waitUntil { !self.model.progress.isBusy }
        let args = try args()
        let tools = try XCTUnwrap(args.firstIndex(of: "--tools"))
        XCTAssertEqual(args[tools + 1], "default")
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "manual", "명령은 자동으로 허용하지 않습니다")
        XCTAssertFalse(args.joined(separator: " ").contains("Bash"), "셸 명령을 미리 허용하지 않습니다")
    }

    func testModelChangeRestartsWithResumeAndModelFlags() async throws {
        await model.refreshClaudeAuth()
        await model.newConversation(provider: .claude)
        model.draft = "첫 번째"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }
        XCTAssertFalse(try args().contains("--model"))

        model.claudeModel = "sonnet"
        model.claudeEffort = "high"
        model.draft = "두 번째"
        await model.send()
        try await waitUntil { self.model.progress.state == .completed }
        let args = try args()
        XCTAssertTrue(args.contains("--resume"), "두 번째 턴부터는 --resume 으로 이어가야 합니다")
        XCTAssertFalse(args.contains("--session-id"))
        if let i = args.firstIndex(of: "--model") { XCTAssertEqual(args[i + 1], "sonnet") } else { XCTFail("--model 없음") }
        if let i = args.firstIndex(of: "--effort") { XCTAssertEqual(args[i + 1], "high") } else { XCTFail("--effort 없음") }
        XCTAssertEqual(model.entries.filter { $0.kind == .assistant }.count, 2)
        XCTAssertEqual(defaults.string(forKey: "claudeModel"), "sonnet")
    }

    func testInterruptMarksTurnInterrupted() async throws {
        await model.refreshClaudeAuth()
        await model.newConversation(provider: .claude)
        model.draft = "long"
        await model.send()
        try await waitUntil { self.model.entries.contains { $0.kind == .assistant } }
        await model.interrupt()
        try await waitUntil { self.model.progress.state == .interrupted }
        XCTAssertEqual(model.progress.phase, "중단됨")
        XCTAssertFalse(model.entries.contains { $0.isStreaming })
        XCTAssertFalse(model.entries.contains { $0.kind == .error }, "사용자 중단은 오류로 표시하지 않습니다")
    }

    /// MCP 서버를 켜면 safe-mode 대신 mcp-config·설정 차단 인수로 띄우고, 텍스트 대화는 MCP 도구만 켭니다.
    func testMCPServersChangeLaunchArguments() async throws {
        await model.refreshClaudeAuth()
        model.addMCPServer(MCPServer.mobbin)
        var figma = MCPServer.figmaRemote
        figma.autoAllow = false
        model.addMCPServer(figma)
        await model.newConversation(provider: .claude)
        model.draft = "hi"
        await model.send()
        try await waitUntil { !self.model.progress.isBusy }
        let args = try self.args()
        XCTAssertFalse(args.contains("--safe-mode"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        let configIndex = try XCTUnwrap(args.firstIndex(of: "--mcp-config"))
        let config = try JSONValue.parse(args[configIndex + 1])
        XCTAssertEqual(config["mcpServers"]?["mobbin"]?["url"]?.stringValue, "https://api.mobbin.com/mcp")
        XCTAssertEqual(config["mcpServers"]?["figma"]?["type"]?.stringValue, "http")
        let toolsIndex = try XCTUnwrap(args.firstIndex(of: "--tools"))
        XCTAssertEqual(args[toolsIndex + 1], "mcp__mobbin,mcp__figma,WebSearch,WebFetch")
        XCTAssertTrue(args.contains("--permission-prompt-tool"), "MCP 도구 승인은 앱이 받습니다")
        let allowedIndex = try XCTUnwrap(args.firstIndex(of: "--allowedTools"))
        XCTAssertEqual(args[allowedIndex + 1], "mcp__mobbin,WebSearch,WebFetch", "자동 허용 서버와 웹 읽기만")
        XCTAssertTrue(args.contains("--setting-sources"), "사용자 설정 파일을 읽지 않습니다 (빈 값은 가짜 CLI 기록에서 빈 줄로 사라집니다)")
        XCTAssertTrue(args.contains(#"{"disableAllHooks":true}"#))
        XCTAssertEqual(model.progress.state, .completed)

        // 서버를 끄면 다음 전송은 예전 인수(safe-mode, 도구 없음)로 다시 띄웁니다.
        model.setMCPServer(id: model.mcpServers[0].id, enabled: false)
        model.setMCPServer(id: model.mcpServers[1].id, enabled: false)
        model.draft = "again"
        await model.send()
        try await waitUntil { !self.model.progress.isBusy }
        let args2 = try self.args()
        XCTAssertTrue(args2.contains("--safe-mode"))
        XCTAssertFalse(args2.contains("--mcp-config"))
        XCTAssertTrue(args2.contains("--resume"))
        // 설정은 UserDefaults 에 남습니다.
        XCTAssertEqual(MCPServerList.load(from: defaults).map(\.name), ["mobbin", "figma"])
    }

    /// 텍스트 대화에 작업 폴더를 나중에 붙이면 다음 전송은 --resume + 도구 인수로 다시 띄웁니다.
    func testAttachingWorkspaceLaterRestartsWithTools() async throws {
        await model.refreshClaudeAuth()
        await model.newConversation(provider: .claude)
        let id = try XCTUnwrap(model.selectedID)
        model.draft = "hi"
        await model.send()
        try await waitUntil { !self.model.progress.isBusy }
        XCTAssertTrue(try self.args().contains("--session-id"))
        XCTAssertFalse(try self.args().contains("--permission-prompt-tool"))

        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        model.setConversationWorkspace(id, path: workspace.path)
        XCTAssertTrue(model.selectedConversation?.hasWorkspace ?? false)
        model.draft = "다시"
        await model.send()
        try await waitUntil { !self.model.progress.isBusy }
        let args = try self.args()
        XCTAssertTrue(args.contains("--resume"), "이전 세션을 이어갑니다")
        XCTAssertTrue(args.contains("--permission-prompt-tool"), "도구가 켜집니다")
        XCTAssertTrue(args.contains("--add-dir"))
        XCTAssertEqual(model.progress.state, .completed)
    }

    func testNewClaudeConversationRequiresLogin() async {
        XCTAssertFalse(model.claudeAuth.isLoggedIn)
        await model.newConversation(provider: .claude)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertNotNil(model.notice)
    }
}
