import Foundation

/// 빌드 출력에서 뽑은 오류·경고 한 줄.
struct BuildIssue: Equatable, Identifiable {
    var id: String { "\(file):\(line):\(column):\(message)" }
    var file: String
    var line: Int
    var column: Int
    var severity: String // "error" | "warning"
    var message: String

    var summary: String {
        let name = (file as NSString).lastPathComponent
        return "\(name):\(line): \(message)"
    }
}

struct BuildResult: Equatable {
    var command: String
    var exitCode: Int32
    var durationSeconds: Double
    /// 마지막 수백 줄만 보관합니다.
    var outputTail: String
    var issues: [BuildIssue]
    var cancelled = false

    var errors: [BuildIssue] { issues.filter { $0.severity == "error" } }
    var succeeded: Bool { exitCode == 0 && !cancelled }
    var statusText: String {
        if cancelled { return "중단됨" }
        if succeeded { return errors.isEmpty ? "성공" : "성공 (오류 \(errors.count)개 표시)" }
        return "실패 · 오류 \(errors.count)개 · 종료코드 \(exitCode)"
    }
}

/// GitHub CLI(`gh`) 연결 상태. 앱은 토큰을 읽지 않고, 로그인은 사용자가 터미널에서 합니다.
enum GitHubStatus: Equatable {
    case checking, missing, loggedOut
    case loggedIn(String)

    var isLoggedIn: Bool { if case .loggedIn = self { return true } else { return false } }

    /// `gh auth status --json hosts` 결과에서 활성 계정 이름만 꺼냅니다. `--show-token` 은 쓰지 않습니다.
    static func parse(_ data: Data) -> GitHubStatus {
        guard let json = try? JSONValue.parse(data), let accounts = json["hosts"]?["github.com"]?.arrayValue else { return .loggedOut }
        let active = accounts.first { $0["active"]?.boolValue == true && $0["state"]?.stringValue == "success" }
        return active?["login"]?.stringValue.map(GitHubStatus.loggedIn) ?? .loggedOut
    }

    static func check() async -> GitHubStatus {
        await Task.detached {
            let process = Process()
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"] + [env["PATH"] ?? ""]).joined(separator: ":")
            process.environment = env
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh", "auth", "status", "--json", "hosts"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return .missing }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 127 ? .missing : parse(data)
        }.value
    }
}

/// 작업 폴더에서 빌드 명령을 추정하고 실행합니다. 모든 명령은 사용자가 설정에서 바꿀 수 있습니다.
enum BuildCommandDetector {
    /// 폴더 바로 아래(1단계)에서 .xcworkspace → .xcodeproj → Package.swift 순으로 찾습니다.
    static func detect(in workspace: URL, listSchemes: (URL) -> [String] = BuildCommandDetector.schemes(of:)) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil) else { return nil }
        let names = items.map { $0.lastPathComponent }
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if let ws = names.first(where: { $0.hasSuffix(".xcworkspace") }) {
            let scheme = listSchemes(workspace.appendingPathComponent(ws)).first ?? (ws as NSString).deletingPathExtension
            return "xcodebuild -workspace \(quoted(ws)) -scheme \(quoted(scheme)) build"
        }
        if let proj = names.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = listSchemes(workspace.appendingPathComponent(proj)).first ?? (proj as NSString).deletingPathExtension
            return "xcodebuild -project \(quoted(proj)) -scheme \(quoted(scheme)) build"
        }
        if names.contains("Package.swift") { return "swift build" }
        return nil
    }

    /// `xcodebuild -list -json` 으로 스킴 이름을 읽습니다. 실패하면 빈 배열.
    static func schemes(of container: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        process.arguments = ["-list", "-json", flag, container.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONValue.parse(data) else { return [] }
        let root = json["workspace"] ?? json["project"] ?? .null
        return (root["schemes"]?.arrayValue ?? []).compactMap(\.stringValue)
    }
}

enum BuildOutputParser {
    /// `path:line:col: error: message` 형식(clang/swiftc/xcodebuild)을 뽑습니다. 중복은 하나로 합칩니다.
    static func issues(in output: String) -> [BuildIssue] {
        let pattern = #"^(.+?):(\d+):(\d+): (error|warning): (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var seen: Set<String> = []
        var result: [BuildIssue] = []
        let ns = output as NSString
        for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)) {
            let issue = BuildIssue(file: ns.substring(with: match.range(at: 1)),
                                   line: Int(ns.substring(with: match.range(at: 2))) ?? 0,
                                   column: Int(ns.substring(with: match.range(at: 3))) ?? 0,
                                   severity: ns.substring(with: match.range(at: 4)),
                                   message: ns.substring(with: match.range(at: 5)).trimmingCharacters(in: .whitespaces))
            if seen.insert(issue.id).inserted { result.append(issue) }
        }
        return result
    }
}

/// 빌드 명령을 작업 폴더에서 실행합니다. 한 번에 하나만 돌고, `cancel()` 로 끊을 수 있습니다.
final class BuildRunner {
    private var process: Process?
    private let lock = NSLock()

    var isRunning: Bool { process?.isRunning ?? false }

    func cancel() {
        let p = lock.withLock { process }
        if let p, p.isRunning { p.terminate() }
    }

    /// 로그인 셸로 실행해 사용자의 PATH(xcodebuild, swift 등)를 그대로 씁니다. 출력은 마지막 400줄만 보관합니다.
    func run(command: String, in workspace: URL, onLine: ((String) -> Void)? = nil) async -> BuildResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workspace
        var env = ProcessInfo.processInfo.environment
        env["NSUnbufferedIO"] = "YES"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        lock.withLock { self.process = process }

        var tail: [String] = []
        var full = ""
        let reader = Task.detached { () -> (String, [String]) in
            var buffer = Data()
            var lines: [String] = []
            var all = ""
            for try await byte in pipe.fileHandleForReading.bytes {
                buffer.append(byte)
                if byte == UInt8(ascii: "\n") {
                    let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .newlines)
                    buffer.removeAll(keepingCapacity: true)
                    lines.append(line)
                    if lines.count > 400 { lines.removeFirst(lines.count - 400) }
                    if all.count < 2_000_000 { all += line + "\n" }
                    onLine?(line)
                }
            }
            if !buffer.isEmpty { let line = String(decoding: buffer, as: UTF8.self); lines.append(line); all += line }
            return (all, lines)
        }
        do {
            try process.run()
        } catch {
            lock.withLock { self.process = nil }
            return BuildResult(command: command, exitCode: -1, durationSeconds: 0, outputTail: error.localizedDescription, issues: [])
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        if let (all, lines) = try? await reader.value { full = all; tail = lines }
        lock.withLock { self.process = nil }
        let cancelled = process.terminationReason == .uncaughtSignal
        return BuildResult(command: command, exitCode: process.terminationStatus,
                           durationSeconds: Date().timeIntervalSince(started),
                           outputTail: tail.joined(separator: "\n"),
                           issues: BuildOutputParser.issues(in: full), cancelled: cancelled)
    }
}
