import Foundation

/// 파일 수정을 승인하기 직전에 원본을 복사해 두고, 나중에 되돌립니다.
/// git 에 의존하지 않고 사용자의 기존 수정도 그대로 보존합니다. 명령(Bash)으로 바뀐 파일은 대상이 아닙니다.
struct WorkspaceBackups {
    let directory: URL

    /// 파일을 백업하고 기록을 돌려줍니다. 파일이 없으면 backupPath 가 nil 인 기록(새 파일)을 만듭니다.
    func backup(path: String, tool: String) throws -> ChangeRecord {
        let id = UUID().uuidString
        let source = URL(fileURLWithPath: path)
        var record = ChangeRecord(id: id, path: path, backupPath: nil, tool: tool, date: Date())
        guard FileManager.default.fileExists(atPath: path) else { return record }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: record.date).replacingOccurrences(of: ":", with: "-")
        let target = directory.appendingPathComponent("\(stamp)-\(id.prefix(8))-\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: target)
        record.backupPath = target.path
        return record
    }

    /// 검토자에게 보낼 변경 내용: 백업과 현재 파일의 unified diff(`/usr/bin/diff -u`), 새 파일은 내용 전체(상한까지).
    static func diffText(_ record: ChangeRecord, limit: Int = 8_000) -> String {
        let name = (record.path as NSString).lastPathComponent
        guard let backupPath = record.backupPath else {
            guard let data = FileManager.default.contents(atPath: record.path) else { return "### 새 파일 \(record.path)\n(지금은 없음)" }
            guard let text = String(data: data, encoding: .utf8) else { return "### 새 파일 \(record.path)\n(이진 파일, \(data.count)바이트)" }
            return "### 새 파일 \(record.path)\n```\n\(clip(text, limit))\n```"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", "--label", "이전/\(name)", "--label", "현재/\(name)", backupPath, record.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "### 변경 \(record.path)\n(diff 실행 실패)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? "(이진 파일)"
        if process.terminationStatus == 0 { return "### 변경 \(record.path)\n(내용 변화 없음)" }
        return "### 변경 \(record.path) (\(record.tool))\n```diff\n\(clip(output, limit))\n```"
    }

    /// 여러 기록을 합쳐 상한 안에서 돌려줍니다. 되돌린 기록은 뺍니다.
    static func reviewDiffs(_ records: [ChangeRecord], totalLimit: Int = 24_000) -> String {
        var pieces: [String] = []
        var budget = totalLimit
        for record in records where !record.reverted && budget > 0 {
            let piece = diffText(record, limit: min(8_000, budget))
            pieces.append(piece)
            budget -= piece.count
        }
        return pieces.joined(separator: "\n\n")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…(생략, \(text.count - limit)자)" : text
    }

    /// 백업으로 되돌립니다. 새 파일이었다면 지웁니다.
    func revert(_ record: ChangeRecord) throws {
        let target = URL(fileURLWithPath: record.path)
        if let backupPath = record.backupPath {
            let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } else if FileManager.default.fileExists(atPath: record.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}

/// 승인 카드에 보여 줄 요약을 만듭니다 (Claude Code 도구 입력과 Codex 승인 파라미터).
enum ApprovalSummary {
    /// Claude Code 도구 입력에서 영향을 받는 파일 경로들
    static func claudeFilePaths(tool: String, input: JSONValue?) -> [String] {
        switch tool {
        case "Edit", "Write", "MultiEdit":
            return [input?["file_path"]?.stringValue].compactMap { $0 }
        case "NotebookEdit":
            return [input?["notebook_path"]?.stringValue].compactMap { $0 }
        default:
            return []
        }
    }

    static func claudeText(tool: String, input: JSONValue?) -> String {
        func clip(_ s: String, _ n: Int = 1500) -> String { s.count > n ? String(s.prefix(n)) + "\n…(생략)" : s }
        switch tool {
        case "Bash":
            return "$ " + (input?["command"]?.stringValue ?? "") + (input?["description"]?.stringValue.map { "\n# \($0)" } ?? "")
        case "Edit":
            let path = input?["file_path"]?.stringValue ?? ""
            let old = input?["old_string"]?.stringValue ?? ""
            let new = input?["new_string"]?.stringValue ?? ""
            let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map { "- " + $0 }.joined(separator: "\n")
            let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ " + $0 }.joined(separator: "\n")
            return clip("\(path)\n\(oldLines)\n\(newLines)")
        case "MultiEdit":
            let path = input?["file_path"]?.stringValue ?? ""
            let edits = (input?["edits"]?.arrayValue ?? []).map { edit -> String in
                "- \(edit["old_string"]?.stringValue ?? "")\n+ \(edit["new_string"]?.stringValue ?? "")"
            }.joined(separator: "\n---\n")
            return clip("\(path)\n\(edits)")
        case "Write":
            let path = input?["file_path"]?.stringValue ?? ""
            return clip("\(path) (새로 쓰기)\n" + (input?["content"]?.stringValue ?? ""))
        default:
            return clip(input?.prettyJSON() ?? "")
        }
    }

    static func codexFilePaths(params: JSONValue?) -> [String] {
        (params?["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
    }

    static func codexText(method: String, params: JSONValue?) -> String {
        if method.contains("commandExecution") {
            let command = params?["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
                ?? params?["command"]?.displayString ?? ""
            let cwd = params?["cwd"]?.stringValue.map { "\n(폴더: \($0))" } ?? ""
            return "$ \(command)\(cwd)" + (params?["reason"]?.stringValue.map { "\n# \($0)" } ?? "")
        }
        let changes = (params?["changes"]?.arrayValue ?? []).map { change -> String in
            let path = change["path"]?.stringValue ?? "?"
            let kind = change["kind"]?.displayString ?? ""
            let diff = change["diff"]?.stringValue ?? change["unifiedDiff"]?.stringValue ?? ""
            return "\(path) \(kind)\n\(diff)"
        }.joined(separator: "\n\n")
        return changes.isEmpty ? (params?.prettyJSON() ?? "") : (changes.count > 3000 ? String(changes.prefix(3000)) + "\n…(생략)" : changes)
    }
}
