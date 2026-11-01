import Foundation

/// 공식 Claude Code CLI(`claude -p --input-format stream-json --output-format stream-json`)에서 올라오는 이벤트.
/// 모두 메인 스레드에서 전달됩니다.
enum ClaudeEvent {
    /// CLI → 앱 메시지 한 줄. `type` 은 system / stream_event / assistant / user / rate_limit_event / result 등.
    case message(type: String, payload: JSONValue)
    /// CLI → 앱 제어 요청(예: 도구 사용 허가). 앱이 자동으로 답한 내용(autoReply)을 함께 전달합니다.
    case controlRequest(subtype: String, params: JSONValue?, autoReply: String)
    /// 작업 폴더 모드에서 CLI 가 도구 사용 허가를 기다리는 중. 앱이 `respondPermission` 으로 답해야 CLI 가 이어갑니다.
    case permissionRequest(requestID: String, toolName: String, input: JSONValue?, description: String)
    /// 로그 한 줄 (방향: "→" 앱이 보냄, "←" CLI 가 보냄, "!" stderr/시스템)
    case log(direction: String, text: String)
    /// 프로세스가 종료됨
    case exited(code: Int32)
}

enum ClaudeError: LocalizedError {
    case notRunning
    case timeout(String)
    case processExited(Int32, String)
    case control(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Claude Code 프로세스가 실행 중이 아닙니다."
        case .timeout(let what): return "'\(what)' 응답이 시간 안에 오지 않았습니다."
        case .processExited(let code, let detail):
            return "Claude Code 프로세스가 종료되었습니다 (코드 \(code)). \(detail)"
        case .control(let message): return "Claude Code 제어 오류: \(message)"
        case .malformed(let line): return "해석할 수 없는 메시지: \(line.prefix(200))"
        }
    }
}

/// `claude auth status --json` 결과. 토큰이나 인증 파일은 포함되지 않으며 앱도 읽지 않습니다.
struct ClaudeAuthStatus: Equatable {
    var loggedIn: Bool
    var authMethod: String      // 예: "claude.ai"
    var subscriptionType: String // 예: "max", "pro", ""(API 키 등)
    var email: String
    var version: String

    var summary: String {
        guard loggedIn else { return "Claude 로그인 필요" }
        var parts = ["Claude 로그인됨"]
        if authMethod == "claude.ai" {
            parts.append(subscriptionType.isEmpty ? "구독" : "\(subscriptionType) 구독")
        } else if !authMethod.isEmpty {
            parts.append(authMethod)
        }
        if !email.isEmpty { parts.append(email) }
        return parts.joined(separator: " · ")
    }

    static func parse(_ json: JSONValue, version: String) -> ClaudeAuthStatus {
        ClaudeAuthStatus(
            loggedIn: json["loggedIn"]?.boolValue ?? false,
            authMethod: json["authMethod"]?.stringValue ?? "",
            subscriptionType: json["subscriptionType"]?.stringValue ?? "",
            email: json["email"]?.stringValue ?? "",
            version: version)
    }
}

/// 공식 Claude Code 바이너리를 무수정 상태로 자식 프로세스로 띄우고 표준입출력(JSON 한 줄씩)으로 대화합니다.
/// 로그인은 Anthropic 자체 절차(`claude auth login`)로 사용자가 직접 하며,
/// 이 클래스는 인증 토큰·키체인·설정 파일을 절대 읽거나 저장하지 않습니다.
final class ClaudeClient {
    var onEvent: ((ClaudeEvent) -> Void)?

    /// 현재 프로세스가 담당하는 Claude 세션 ID (앱이 만든 UUID 또는 이어가는 세션).
    private(set) var sessionID: String?
    /// 작업 폴더 모드 여부. true 면 can_use_tool 요청을 앱에 넘기고 답을 기다립니다.
    private(set) var toolsEnabled = false
    /// 아직 답하지 않은 도구 허가 요청 ID
    private var pendingPermissionIDs: Set<String> = []

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var lastStderrLines: [String] = []
    private var nextControlID = 1
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "condux.claude.write")

    var isRunning: Bool { process?.isRunning ?? false }

    /// 앱에서 시작한 대화에 공통으로 거는 안전장치. 모두 공식 CLI 플래그이며 바이너리는 수정하지 않습니다.
    /// - `--safe-mode`: 사용자 환경의 플러그인/훅/MCP/CLAUDE.md 를 이 세션에서만 끕니다. 인증은 그대로 둡니다.
    /// - `--tools ""`: 내장 도구(파일·셸 등)를 모두 뺍니다. 텍스트 대화만 합니다.
    /// - `--strict-mcp-config`: 명령줄로 넘긴 MCP 서버만 사용(없음).
    /// - `--permission-prompts none`: 그래도 승인이 필요한 요청은 자동 거절.
    static let safetyArguments: [String] = baseArguments + textOnlyArguments

    /// 두 모드 공통 플래그.
    static let baseArguments: [String] = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--safe-mode",
        "--strict-mcp-config",
    ]
    /// 텍스트 전용 모드: 도구 없음, 승인 요청은 자동 거절.
    static let textOnlyArguments: [String] = ["--tools", "", "--permission-prompts", "none"]
    /// 글 대화에서 켜는 웹 읽기 도구
    static let webTools = ["WebSearch", "WebFetch"]
    /// 작업 폴더 모드: 기본 도구 사용, 수정·명령은 앱(host)이 승인. 자동 허용 모드는 쓰지 않습니다.
    static let workspaceArguments: [String] = [
        "--tools", "default",
        "--permission-mode", "manual",
        "--permission-prompts", "host",
        "--permission-prompt-tool", "stdio", // 승인 질문을 stdio control_request(can_use_tool) 로 앱에 보냄 (Agent SDK 와 같은 방식)
    ]

    // MARK: 실행 파일 찾기

    /// - Parameter executableOverride: 사용자가 설정한 claude 실행 파일 경로. 비어 있으면 PATH 에서 찾습니다.
    private static func configure(_ process: Process, executableOverride: String, arguments: [String]) {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin",
                          "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.npm-global/bin"]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let override = executableOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            process.executableURL = URL(fileURLWithPath: override)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude"] + arguments
        }
    }

    // MARK: 로그인 상태 확인 (읽기 전용)

    /// `claude auth status --json` 과 `claude --version` 을 실행해 상태만 읽습니다. 로그인/로그아웃은 하지 않습니다.
    static func authStatus(executableOverride: String, timeout: TimeInterval = 20) async throws -> ClaudeAuthStatus {
        let version = (try? await runOnce(executableOverride: executableOverride, arguments: ["--version"], timeout: timeout))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let output = try await runOnce(executableOverride: executableOverride, arguments: ["auth", "status", "--json"], timeout: timeout)
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else {
            throw ClaudeError.malformed(output)
        }
        let json = try JSONValue.parse(String(output[start...end]))
        return ClaudeAuthStatus.parse(json, version: version)
    }

    /// 짧은 명령 한 번 실행. 표준출력을 돌려주고, 종료 코드가 0이 아니면 오류로 던집니다.
    private static func runOnce(executableOverride: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        configure(process, executableOverride: executableOverride, arguments: arguments)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let state = NSLock()
            var finished = false
            // stderr 는 따로 읽습니다. 한쪽 파이프가 차서 자식이 멈추는 일을 막습니다.
            let errorBox = NSLock()
            var errorData = Data()
            let errorGroup = DispatchGroup()
            errorGroup.enter()
            DispatchQueue.global().async {
                let read = stderr.fileHandleForReading.readDataToEndOfFile()
                errorBox.lock(); errorData = read; errorBox.unlock()
                errorGroup.leave()
            }
            DispatchQueue.global().async {
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                _ = errorGroup.wait(timeout: .now() + 2)
                errorBox.lock(); let errorText = String(decoding: errorData, as: UTF8.self); errorBox.unlock()
                state.lock(); defer { state.unlock() }
                guard !finished else { return }
                finished = true
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ClaudeError.processExited(process.terminationStatus, detail.isEmpty ? String(decoding: output, as: UTF8.self).prefix(200).description : detail))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.lock(); defer { state.unlock() }
                guard !finished else { return }
                finished = true
                if process.isRunning { process.terminate() }
                continuation.resume(throwing: ClaudeError.timeout(arguments.joined(separator: " ")))
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 프로세스 시작/종료

    /// 한 세션(=한 대화)마다 프로세스 하나를 띄웁니다.
    /// - Parameters:
    ///   - sessionID: 앱이 만든 UUID. `resume` 이 false 면 `--session-id`, true 면 `--resume` 으로 넘깁니다.
    ///   - workingDirectory: Claude 의 작업 폴더. 빈 폴더지만 홈 디렉터리 격리가 아닙니다 (도구를 모두 뺐으므로 읽을 수단도 없습니다).
    ///   - systemPromptAppendix: 기본 시스템 프롬프트 뒤에 붙일 안내.
    ///   - model: `--model` 값(별칭 또는 전체 이름). 비우면 사용자 계정의 기본 모델.
    ///   - effort: `--effort` 값(low/medium/high/xhigh/max). 비우면 기본.
    ///   - toolsEnabled: true 면 작업 폴더 모드(도구 사용 가능, 수정·명령은 승인 필요).
    ///   - additionalDirectories: `--add-dir` 로 작업 폴더에 더할 폴더(첨부·받은 파일 폴더).
    func start(executableOverride: String, sessionID: String, resume: Bool,
               workingDirectory: URL, systemPromptAppendix: String,
               model: String = "", effort: String = "", toolsEnabled: Bool = false,
               additionalDirectories: [URL] = [], mcpConfigJSON: String = "", mcpToolNames: [String] = [],
               allowedTools: [String] = [], webToolsEnabled: Bool = false) throws {
        stop()
        let mcpEnabled = !mcpConfigJSON.isEmpty && !mcpToolNames.isEmpty
        // MCP 도구 호출도 can_use_tool 로 오므로 승인 처리를 켭니다.
        self.toolsEnabled = toolsEnabled || mcpEnabled

        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        var arguments = Self.baseArguments
        // 작업 폴더 모드는 기본 도구를 쓰고 승인을 받으므로 따로 더하지 않습니다.
        let textWebTools = webToolsEnabled && !toolsEnabled ? Self.webTools : []
        if mcpEnabled {
            // --safe-mode 는 --mcp-config 서버까지 꺼 버립니다(실측). 대신 설정 파일·훅을 따로 끕니다.
            // --strict-mcp-config 는 그대로: 사용자 전역 MCP 설정은 쓰지 않고 앱이 넘긴 서버만 씁니다.
            arguments.removeAll { $0 == "--safe-mode" }
            arguments += ["--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#, "--mcp-config", mcpConfigJSON]
        }
        if toolsEnabled {
            arguments += Self.workspaceArguments
        } else if mcpEnabled {
            // 텍스트 대화 + MCP: 내장 도구 없이 MCP 서버 도구만 켭니다. 승인은 작업 폴더 모드와 같이 앱이 받습니다.
            arguments += ["--tools", (mcpToolNames + textWebTools).joined(separator: ",")] + Self.workspaceArguments.dropFirst(2)
        } else if webToolsEnabled {
            // 웹 읽기만 허용합니다. 파일·명령 도구는 여전히 없고, 그 밖의 승인 요청은 자동 거절됩니다.
            arguments += ["--tools", Self.webTools.joined(separator: ",")] + Self.textOnlyArguments.dropFirst(2)
        } else {
            arguments += Self.textOnlyArguments
        }
        let autoAllowed = allowedTools + textWebTools
        if !autoAllowed.isEmpty { arguments += ["--allowedTools", autoAllowed.joined(separator: ",")] }
        arguments += [resume ? "--resume" : "--session-id", sessionID]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty { arguments += ["--model", trimmedModel] }
        let trimmedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEffort.isEmpty { arguments += ["--effort", trimmedEffort] }
        if !systemPromptAppendix.isEmpty { arguments += ["--append-system-prompt", systemPromptAppendix] }
        for directory in additionalDirectories { arguments += ["--add-dir", directory.path] }
        Self.configure(process, executableOverride: executableOverride, arguments: arguments)
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeStdout(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeStderr(data)
        }
        process.terminationHandler = { [weak self] proc in
            self?.handleTermination(code: proc.terminationStatus)
        }

        self.process = process
        self.stdinPipe = stdin
        self.sessionID = sessionID
        stdoutBuffer = Data()
        stderrBuffer = Data()
        lastStderrLines = []

        try process.run()
        emit(.log(direction: "!", text: "claude 시작 (pid \(process.processIdentifier), \(resume ? "resume" : "new") \(sessionID.prefix(8)))"))
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminationHandler = nil
            // 표준입력을 닫으면 CLI 가 스스로 끝납니다. 끝나지 않으면 terminate.
            try? stdinPipe?.fileHandleForWriting.close()
            process.terminate()
        }
        self.process = nil
        stdinPipe = nil
        sessionID = nil
        failAllPending(with: ClaudeError.notRunning)
    }

    // MARK: 보내기

    /// 사용자 메시지 한 개를 보냅니다. 답은 이벤트로 올라옵니다.
    func sendUserMessage(_ text: String) throws {
        try sendUserMessage(content: [["type": "text", "text": .string(text)]])
    }

    /// 내용 블록(text·image·document)을 그대로 담아 보냅니다 (Anthropic Messages 형식).
    func sendUserMessage(content: [JSONValue]) throws {
        try write([
            "type": "user",
            "message": ["role": "user", "content": .array(content)],
        ])
    }

    /// 진행 중인 턴을 중단합니다. 턴 ID 가 필요 없고, CLI 가 control_response 로 답합니다.
    func interrupt(timeout: TimeInterval = 20) async throws {
        _ = try await controlRequest(["subtype": "interrupt"], timeout: timeout)
    }

    private func controlRequest(_ request: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard isRunning else { throw ClaudeError.notRunning }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let id = "condux-\(nextControlID)"
            nextControlID += 1
            pending[id] = continuation
            lock.unlock()
            let work = DispatchWorkItem { [weak self] in
                self?.finish(id, with: .failure(ClaudeError.timeout(request["subtype"]?.stringValue ?? "control")))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            do {
                try write(["type": "control_request", "request_id": .string(id), "request": request])
            } catch {
                finish(id, with: .failure(error))
            }
        }
    }

    private func finish(_ id: String, with result: Result<JSONValue, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func write(_ value: JSONValue) throws {
        guard let stdinPipe, isRunning else { throw ClaudeError.notRunning }
        let line = try value.compactJSON()
        let data = Data((line + "\n").utf8)
        var writeError: Error?
        writeQueue.sync {
            do { try stdinPipe.fileHandleForWriting.write(contentsOf: data) } catch { writeError = error }
        }
        if let writeError { throw writeError }
        emit(.log(direction: "→", text: line))
    }

    // MARK: 받은 데이터 처리

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrBuffer.append(data)
        while let newline = stderrBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stderrBuffer[stderrBuffer.startIndex..<newline]
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            guard !line.isEmpty else { continue }
            lock.lock()
            lastStderrLines.append(line)
            if lastStderrLines.count > 20 { lastStderrLines.removeFirst() }
            lock.unlock()
            emit(.log(direction: "!", text: line))
        }
    }

    private func handleLine(_ line: String) {
        emit(.log(direction: "←", text: line))
        guard let message = try? JSONValue.parse(line) else {
            emit(.log(direction: "!", text: "JSON 아님: \(line.prefix(200))"))
            return
        }
        guard let type = message["type"]?.stringValue else {
            emit(.log(direction: "!", text: "type 없는 메시지: \(line.prefix(200))"))
            return
        }
        switch type {
        case "control_response":
            let response = message["response"] ?? .null
            guard let id = response["request_id"]?.stringValue else { return }
            if response["subtype"]?.stringValue == "error" {
                finish(id, with: .failure(ClaudeError.control(response["error"]?.stringValue ?? "알 수 없는 오류")))
            } else {
                finish(id, with: .success(response["response"] ?? .null))
            }
        case "control_request":
            handleControlRequest(message)
        default:
            emit(.message(type: type, payload: message))
        }
    }

    /// 작업 폴더 모드에서 도구 허가 요청에 답합니다. allow 면 입력을 그대로 돌려줍니다.
    func respondPermission(requestID: String, allow: Bool, input: JSONValue?, message: String = "") {
        lock.lock()
        let known = pendingPermissionIDs.remove(requestID) != nil
        lock.unlock()
        guard known else { return }
        let response: JSONValue = allow
            ? ["behavior": "allow", "updatedInput": input ?? [:]]
            : ["behavior": "deny", "message": .string(message.isEmpty ? "사용자가 거부했습니다." : message)]
        try? write(["type": "control_response", "response": [
            "subtype": "success", "request_id": .string(requestID), "response": response,
        ]])
    }

    /// CLI 가 앱에게 무언가를 물어볼 때. 텍스트 모드는 도구 사용을 모두 거절하고, 작업 폴더 모드는 앱에 넘깁니다.
    private func handleControlRequest(_ message: JSONValue) {
        let id = message["request_id"] ?? .null
        let request = message["request"] ?? .null
        let subtype = request["subtype"]?.stringValue ?? "unknown"
        let reply: String
        if subtype == "can_use_tool", toolsEnabled, let requestID = id.stringValue {
            lock.lock(); pendingPermissionIDs.insert(requestID); lock.unlock()
            emit(.permissionRequest(requestID: requestID,
                                    toolName: request["tool_name"]?.stringValue ?? "?",
                                    input: request["input"],
                                    description: request["description"]?.stringValue ?? request["display"]?.stringValue ?? ""))
            return
        }
        if subtype == "can_use_tool" {
            try? write(["type": "control_response", "response": [
                "subtype": "success", "request_id": id,
                "response": ["behavior": "deny", "message": "Condux 실험 모드는 도구 사용을 허용하지 않습니다."],
            ]])
            reply = "도구 사용 거절(deny)"
        } else {
            try? write(["type": "control_response", "response": [
                "subtype": "error", "request_id": id,
                "error": .string("Condux 가 지원하지 않는 요청입니다: \(subtype)"),
            ]])
            reply = "지원 안 함"
        }
        emit(.controlRequest(subtype: subtype, params: request, autoReply: reply))
    }

    private func handleTermination(code: Int32) {
        lock.lock()
        let detail = lastStderrLines.suffix(3).joined(separator: " / ")
        lock.unlock()
        process = nil
        stdinPipe = nil
        sessionID = nil
        lock.lock(); pendingPermissionIDs.removeAll(); lock.unlock()
        failAllPending(with: ClaudeError.processExited(code, detail))
        emit(.exited(code: code))
    }

    private func failAllPending(with error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in all { continuation.resume(throwing: error) }
    }

    private func emit(_ event: ClaudeEvent) {
        DispatchQueue.main.async { [onEvent] in onEvent?(event) }
    }
}
