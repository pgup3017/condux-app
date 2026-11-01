import Foundation

/// app-server 에서 올라오는 이벤트. 모두 메인 스레드에서 전달됩니다.
enum CodexEvent {
    /// 서버 → 앱 알림 (예: turn/started, item/agentMessage/delta)
    case notification(method: String, params: JSONValue?)
    /// 서버 → 앱 요청. 앱이 자동으로 답한 내용(autoReply)을 함께 전달합니다.
    case serverRequest(method: String, params: JSONValue?, autoReply: String)
    /// 작업 폴더 모드에서 서버가 승인(명령 실행/파일 변경)을 기다리는 중. `respondApproval` 로 답해야 턴이 이어집니다.
    case approvalRequest(requestID: String, method: String, params: JSONValue?)
    /// 로그 한 줄 (방향: "→" 앱이 보냄, "←" 서버가 보냄, "!" stderr/시스템)
    case log(direction: String, text: String)
    /// 프로세스가 종료됨
    case exited(code: Int32)
}

enum CodexError: LocalizedError {
    case notRunning
    case timeout(String)
    case processExited(Int32, String)
    case rpc(code: Int?, message: String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Codex app-server 가 실행 중이 아닙니다."
        case .timeout(let method): return "'\(method)' 응답이 시간 안에 오지 않았습니다."
        case .processExited(let code, let detail):
            return "Codex 프로세스가 종료되었습니다 (코드 \(code)). \(detail)"
        case .rpc(let code, let message):
            return "Codex 오류\(code.map { " [\($0)]" } ?? ""): \(message)"
        case .malformed(let line): return "해석할 수 없는 메시지: \(line.prefix(200))"
        }
    }
}

/// `codex app-server` 를 자식 프로세스로 띄우고 표준입출력(JSON 한 줄씩)으로 대화합니다.
/// 인증 토큰은 Codex 자신이 관리하며 이 클래스는 절대 읽지 않습니다.
final class CodexClient {
    var onEvent: ((CodexEvent) -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var lastStderrLines: [String] = []
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "vibestudio.codex.write")

    var isRunning: Bool { process?.isRunning ?? false }

    /// true 면 requestApproval 을 자동 취소하지 않고 앱에 넘깁니다 (앱이 대화별로 판단).
    var approvalsEnabled = false
    private var pendingApprovals: [String: JSONValue] = [:]

    /// 승인 요청에 답합니다. decision: "accept" / "decline" / "cancel"
    func respondApproval(requestID: String, decision: String) {
        lock.lock()
        let id = pendingApprovals.removeValue(forKey: requestID)
        lock.unlock()
        guard let id else { return }
        respond(id: id, result: ["decision": .string(decision)])
    }

    // MARK: 프로세스 시작/종료

    /// - Parameter executableOverride: 사용자가 설정한 codex 실행 파일 경로. 비어 있으면 PATH 에서 찾습니다.
    /// - Parameter extraArguments: `app-server` 앞에 넣을 인수 (`-c key=value` 설정 덮어쓰기 등)
    func start(executableOverride: String, extraArguments: [String] = []) throws {
        stop()

        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin",
                          "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.npm-global/bin"]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let override = executableOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            process.executableURL = URL(fileURLWithPath: override)
            process.arguments = extraArguments + ["app-server"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex"] + extraArguments + ["app-server"]
        }
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
        stdoutBuffer = Data()
        stderrBuffer = Data()
        lastStderrLines = []

        try process.run()
        emit(.log(direction: "!", text: "codex app-server 시작 (pid \(process.processIdentifier))"))
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        self.process = nil
        stdinPipe = nil
        failAllPending(with: CodexError.notRunning)
    }

    // MARK: 요청/알림 보내기

    func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        guard isRunning else { throw CodexError.notRunning }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let id = nextID
            nextID += 1
            pending[id] = continuation
            lock.unlock()
            if let timeout {
                let work = DispatchWorkItem { [weak self] in
                    self?.finish(id, with: .failure(CodexError.timeout(method)))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            }
            var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method)]
            if let params { message["params"] = params }
            do { try write(.object(message)) }
            catch { finish(id, with: .failure(error)) }
        }
    }

    private func finish(_ id: Int, with result: Result<JSONValue, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    func notify(_ method: String, params: JSONValue? = nil) {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params { message["params"] = params }
        try? write(.object(message))
    }

    private func respond(id: JSONValue, result: JSONValue) {
        try? write(.object(["id": id, "result": result]))
    }

    private func respondError(id: JSONValue, code: Int, message: String) {
        try? write(.object(["id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    private func write(_ value: JSONValue) throws {
        guard let stdinPipe, isRunning else { throw CodexError.notRunning }
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
        let method = message["method"]?.stringValue
        let id = message["id"]

        if let method {
            if let id, !id.isNull {
                handleServerRequest(id: id, method: method, params: message["params"])
            } else {
                emit(.notification(method: method, params: message["params"]))
            }
            return
        }

        guard let idNumber = id?.intValue else {
            emit(.log(direction: "!", text: "id 없는 응답: \(line.prefix(200))"))
            return
        }
        lock.lock()
        let continuation = pending.removeValue(forKey: idNumber)
        lock.unlock()
        guard let continuation else { return }

        if let error = message["error"], !error.isNull {
            let text = error["message"]?.stringValue ?? error.displayString
            continuation.resume(throwing: CodexError.rpc(code: error["code"]?.intValue, message: text))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    /// 서버가 앱에게 무언가를 물어볼 때. 이 앱은 파일 수정과 명령 실행을 모두 거절합니다.
    private func handleServerRequest(id: JSONValue, method: String, params: JSONValue?) {
        let reply: String
        if method.hasSuffix("requestApproval"), approvalsEnabled {
            let key = id.displayString
            lock.lock(); pendingApprovals[key] = id; lock.unlock()
            emit(.approvalRequest(requestID: key, method: method, params: params))
            return
        }
        if method.hasSuffix("requestApproval") {
            respond(id: id, result: ["decision": "cancel"])
            reply = "거절 및 턴 중단(cancel)"
        } else if method.hasSuffix("requestPermissions") || method.contains("permissions") {
            respondError(id: id, code: -32000, message: "VibeStudio 는 권한 상승을 허용하지 않습니다.")
            reply = "권한 요청 거절"
        } else if method.hasSuffix("requestUserInput") {
            respond(id: id, result: ["answers": [:]])
            reply = "빈 답변"
        } else {
            respondError(id: id, code: -32601, message: "VibeStudio 가 지원하지 않는 요청입니다: \(method)")
            reply = "지원 안 함"
        }
        emit(.serverRequest(method: method, params: params, autoReply: reply))
    }

    private func handleTermination(code: Int32) {
        lock.lock()
        let detail = lastStderrLines.suffix(3).joined(separator: " / ")
        lock.unlock()
        process = nil
        stdinPipe = nil
        lock.lock(); pendingApprovals.removeAll(); lock.unlock()
        failAllPending(with: CodexError.processExited(code, detail))
        emit(.exited(code: code))
    }

    private func failAllPending(with error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in all { continuation.resume(throwing: error) }
    }

    private func emit(_ event: CodexEvent) {
        DispatchQueue.main.async { [onEvent] in onEvent?(event) }
    }
}
