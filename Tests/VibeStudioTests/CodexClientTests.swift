import XCTest
@testable import Condux

final class CodexClientTests: XCTestCase {
    private var directory: URL!
    private var executable: URL!
    private var client: CodexClient!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-codex")
        // No authentication, network or actual model calls: only exercise the JSON-lines transport.
        let fixture = #"""
        #!/bin/sh
        exec /usr/bin/python3 -u -c '
        import json, sys
        for line in sys.stdin:
            obj = json.loads(line)
            method = obj.get("method")
            if method == "silent":
                continue
            if method == "approval":
                kind = obj["params"]["kind"]
                print(json.dumps({"id": "approval-1", "method": kind, "params": {"threadId": "fake-thread"}}), flush=True)
                reply = json.loads(sys.stdin.readline())
                print(json.dumps({"id": obj["id"], "result": reply}), flush=True)
            else:
                print("non-JSON diagnostic line", flush=True)
                print(json.dumps({"id": obj["id"], "result": {"ok": True}}), flush=True)
        '
        """#
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = CodexClient()
        try client.start(executableOverride: executable.path)
    }

    override func tearDownWithError() throws {
        client.stop()
        try FileManager.default.removeItem(at: directory)
    }

    func testNonJSONOutputDoesNotBreakResponses() async throws {
        let response = try await client.request("ping", timeout: 2)
        XCTAssertEqual(response["ok"]?.boolValue, true)
    }

    func testUnresponsiveRequestTimesOutAndConnectionRemainsUsable() async throws {
        let started = Date()
        do {
            _ = try await client.request("silent", timeout: 0.1)
            XCTFail("A silent server must time out")
        } catch CodexError.timeout(let method) {
            XCTAssertEqual(method, "silent")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let response = try await client.request("ping", timeout: 2)
        XCTAssertEqual(response["ok"]?.boolValue, true)
    }

    func testCommandApprovalCancelsTurn() async throws {
        let response = try await client.request("approval", params: ["kind": "item/commandExecution/requestApproval"], timeout: 2)
        XCTAssertEqual(response["result"]?["decision"]?.stringValue, "cancel")
    }

    func testFileApprovalCancelsTurn() async throws {
        let response = try await client.request("approval", params: ["kind": "item/fileChange/requestApproval"], timeout: 2)
        XCTAssertEqual(response["result"]?["decision"]?.stringValue, "cancel")
    }

    func testWorkspaceModeForwardsApprovalAndAccepts() async throws {
        client.approvalsEnabled = true
        var received: (id: String, method: String)?
        let lock = NSLock()
        client.onEvent = { event in
            if case .approvalRequest(let id, let method, _) = event { lock.withLock { received = (id, method) } }
        }
        async let pending = client.request("approval", params: ["kind": "item/fileChange/requestApproval"], timeout: 5)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if lock.withLock({ received }) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let got = lock.withLock { received }
        let approval = try XCTUnwrap(got, "approvalsEnabled 이면 requestApproval 이 앱으로 와야 합니다")
        XCTAssertEqual(approval.method, "item/fileChange/requestApproval")
        client.respondApproval(requestID: approval.id, decision: "accept")
        let response = try await pending
        XCTAssertEqual(response["result"]?["decision"]?.stringValue, "accept")
    }

    func testUnknownServerRequestIsRejected() async throws {
        let response = try await client.request("approval", params: ["kind": "unknown/dangerousRequest"], timeout: 2)
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32601)
        XCTAssertNil(response["result"])
    }
}
