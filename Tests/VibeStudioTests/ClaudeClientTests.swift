import XCTest
@testable import Condux

/// 실제 Claude Code, 로그인, 네트워크, 모델 호출 없이 가짜 CLI 로 JSON-lines 통신만 검사합니다.
@MainActor
final class ClaudeClientTests: XCTestCase {
    private var directory: URL!
    private var executable: URL!
    private var client: ClaudeClient!
    private var events: [ClaudeEvent] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-claude")
        // 실제 2.1.314 가 보낸 메시지 모양을 그대로 흉내 냅니다. 인수를 기록해 두어 플래그도 검사합니다.
        let fixture = #"""
        #!/bin/sh
        printf '%s\n' "$@" > "$(dirname "$0")/args.txt"
        if [ "$1" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
        if [ "$1" = "auth" ]; then
          echo '{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max", "email": "someone@example.com"}'
          exit 0
        fi
        exec /usr/bin/python3 -u -c '
        import json, sys
        sid = "11111111-2222-3333-4444-555555555555"
        def out(o): print(json.dumps(o), flush=True)
        out({"type":"system","subtype":"init","session_id":sid,"model":"fake-model","tools":[],"mcp_servers":[]})
        for line in sys.stdin:
            obj = json.loads(line)
            t = obj.get("type")
            if t == "user":
                text = obj["message"]["content"][0]["text"]
                out({"type":"system","subtype":"status","status":"requesting","session_id":sid})
                if text == "ask-tool":
                    out({"type":"control_request","request_id":"srv-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}})
                    reply = json.loads(sys.stdin.readline())
                    out({"type":"result","subtype":"success","is_error":False,"terminal_reason":"completed","session_id":sid,"result":json.dumps(reply)})
                    continue
                if text == "long":
                    out({"type":"stream_event","session_id":sid,"api_message_id":"msg_1","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"1 2 3"}}})
                    nxt = json.loads(sys.stdin.readline())
                    if nxt.get("type") == "control_request" and nxt["request"]["subtype"] == "interrupt":
                        out({"type":"control_response","response":{"subtype":"success","request_id":nxt["request_id"],"response":{"still_queued":[]}}})
                        out({"type":"result","subtype":"error_during_execution","is_error":True,"terminal_reason":"aborted_streaming","session_id":sid,"result":None})
                    continue
                out({"type":"stream_event","session_id":sid,"api_message_id":"msg_1","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"안"}}})
                out({"type":"stream_event","session_id":sid,"api_message_id":"msg_1","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"녕"}}})
                out({"type":"assistant","session_id":sid,"message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"안녕"}]}})
                out({"type":"rate_limit_event","session_id":sid,"rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.02},"seven_day":{"utilization":0.6}}}})
                out({"type":"result","subtype":"success","is_error":False,"terminal_reason":"completed","session_id":sid,"result":"안녕","usage":{"input_tokens":2,"output_tokens":5}})
            elif t == "control_request":
                out({"type":"control_response","response":{"subtype":"error","request_id":obj["request_id"],"error":"nothing running"}})
        '
        """#
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = ClaudeClient()
        events = []
        client.onEvent = { [weak self] event in self?.events.append(event) }
    }

    override func tearDownWithError() throws {
        client.stop()
        try FileManager.default.removeItem(at: directory)
    }

    private func startClient(resume: Bool = false, toolsEnabled: Bool = false) throws {
        try client.start(executableOverride: executable.path, sessionID: "11111111-2222-3333-4444-555555555555",
                         resume: resume, workingDirectory: directory, systemPromptAppendix: "텍스트로만 답하세요.",
                         toolsEnabled: toolsEnabled)
    }

    func testWorkspaceModeRoutesPermissionRequestToHostAndAllows() async throws {
        try startClient(toolsEnabled: true)
        try client.sendUserMessage("ask-tool")
        let deadline = Date().addingTimeInterval(5)
        var request: (id: String, tool: String, input: JSONValue?)?
        while request == nil, Date() < deadline {
            for event in events { if case .permissionRequest(let id, let tool, let input, _) = event { request = (id, tool, input) } }
            try await Task.sleep(for: .milliseconds(20))
        }
        let req = try XCTUnwrap(request, "작업 폴더 모드에서는 can_use_tool 이 앱으로 와야 합니다")
        XCTAssertEqual(req.id, "srv-1")
        XCTAssertEqual(req.tool, "Bash")
        XCTAssertEqual(req.input?["command"]?.stringValue, "ls")
        XCTAssertTrue(messages(ofType: "result").isEmpty, "앱이 답하기 전에는 CLI 가 기다립니다")

        client.respondPermission(requestID: req.id, allow: true, input: req.input)
        let result = try await waitForResult()
        let echoed = try JSONValue.parse(result["result"]?.stringValue ?? "")
        XCTAssertEqual(echoed["response"]?["response"]?["behavior"]?.stringValue, "allow")
        XCTAssertEqual(echoed["response"]?["response"]?["updatedInput"]?["command"]?.stringValue, "ls")

        let args = try String(contentsOf: directory.appendingPathComponent("args.txt")).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains("--permission-mode") && args.contains("manual"))
        XCTAssertTrue(args.contains("host"), "--permission-prompts host")
        if let i = args.firstIndex(of: "--tools") { XCTAssertEqual(args[i + 1], "default") } else { XCTFail("--tools 없음") }
        XCTAssertFalse(args.contains("bypassPermissions"))
    }

    func testWorkspaceModeDenyIsForwarded() async throws {
        try startClient(toolsEnabled: true)
        try client.sendUserMessage("ask-tool")
        let deadline = Date().addingTimeInterval(5)
        var requestID: String?
        while requestID == nil, Date() < deadline {
            for event in events { if case .permissionRequest(let id, _, _, _) = event { requestID = id } }
            try await Task.sleep(for: .milliseconds(20))
        }
        client.respondPermission(requestID: try XCTUnwrap(requestID), allow: false, input: nil, message: "사용자가 거부")
        let result = try await waitForResult()
        let echoed = try JSONValue.parse(result["result"]?.stringValue ?? "")
        XCTAssertEqual(echoed["response"]?["response"]?["behavior"]?.stringValue, "deny")
        XCTAssertEqual(echoed["response"]?["response"]?["message"]?.stringValue, "사용자가 거부")
    }

    private func waitForResult(timeout: TimeInterval = 5) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for event in events {
                if case .message(let type, let payload) = event, type == "result" { return payload }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("result 메시지가 오지 않았습니다")
        throw ClaudeError.timeout("result")
    }

    private func messages(ofType type: String) -> [JSONValue] {
        events.compactMap { if case .message(let t, let payload) = $0, t == type { return payload } else { return nil } }
    }

    func testAuthStatusIsParsedWithoutTouchingCredentials() async throws {
        let status = try await ClaudeClient.authStatus(executableOverride: executable.path, timeout: 5)
        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.authMethod, "claude.ai")
        XCTAssertEqual(status.subscriptionType, "max")
        XCTAssertEqual(status.version, "9.9.9 (Claude Code)")
        XCTAssertTrue(status.summary.contains("max 구독"))
    }

    func testTextTurnStreamsDeltasThenResult() async throws {
        try startClient()
        try client.sendUserMessage("안녕")
        let result = try await waitForResult()
        XCTAssertEqual(result["subtype"]?.stringValue, "success")
        let deltas = messages(ofType: "stream_event").compactMap { $0["event"]?["delta"]?["text"]?.stringValue }
        XCTAssertEqual(deltas.joined(), "안녕")
        XCTAssertEqual(messages(ofType: "assistant").count, 1)
        XCTAssertEqual(messages(ofType: "rate_limit_event").first?["rate_limit_info"]?["unifiedWindows"]?["seven_day"]?["utilization"]?.doubleValue, 0.6)

        // 새 세션은 --session-id, 안전 플래그는 모두 포함되어야 합니다.
        let args = try String(contentsOf: directory.appendingPathComponent("args.txt")).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains("--session-id"))
        XCTAssertFalse(args.contains("--resume"))
        for flag in ["-p", "--safe-mode", "--tools", "--strict-mcp-config", "--permission-prompts", "--include-partial-messages"] {
            XCTAssertTrue(args.contains(flag), "\(flag) 플래그가 없습니다")
        }
        XCTAssertTrue(args.contains("텍스트로만 답하세요."))
    }

    func testResumeUsesResumeFlag() throws {
        try startClient(resume: true)
        let expectation = XCTestExpectation(description: "args written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        let args = try String(contentsOf: directory.appendingPathComponent("args.txt")).split(separator: "\n").map(String.init)
        XCTAssertTrue(args.contains("--resume"))
        XCTAssertFalse(args.contains("--session-id"))
    }

    func testInterruptGetsControlResponseAndAbortedResult() async throws {
        try startClient()
        try client.sendUserMessage("long")
        // 첫 글자가 올 때까지 기다린 뒤 중단합니다.
        let deadline = Date().addingTimeInterval(5)
        while messages(ofType: "stream_event").isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await client.interrupt(timeout: 5)
        let result = try await waitForResult()
        XCTAssertEqual(result["terminal_reason"]?.stringValue, "aborted_streaming")
        XCTAssertEqual(result["is_error"]?.boolValue, true)
    }

    func testInterruptWhenNothingRunningSurfacesControlError() async throws {
        try startClient()
        do {
            try await client.interrupt(timeout: 5)
            XCTFail("오류 응답은 throw 되어야 합니다")
        } catch ClaudeError.control(let message) {
            XCTAssertEqual(message, "nothing running")
        }
    }

    func testToolPermissionRequestIsDenied() async throws {
        try startClient()
        try client.sendUserMessage("ask-tool")
        let result = try await waitForResult()
        let echoed = try JSONValue.parse(result["result"]?.stringValue ?? "")
        XCTAssertEqual(echoed["type"]?.stringValue, "control_response")
        XCTAssertEqual(echoed["response"]?["request_id"]?.stringValue, "srv-1")
        XCTAssertEqual(echoed["response"]?["response"]?["behavior"]?.stringValue, "deny")
        let blocked = events.contains { if case .controlRequest(let subtype, _, _) = $0 { return subtype == "can_use_tool" } else { return false } }
        XCTAssertTrue(blocked)
    }

    func testMissingExecutableIsReportedNotCrashing() async {
        do {
            _ = try await ClaudeClient.authStatus(executableOverride: directory.appendingPathComponent("does-not-exist").path, timeout: 5)
            XCTFail("없는 실행 파일은 오류여야 합니다")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
