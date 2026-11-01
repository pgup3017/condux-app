import XCTest
@testable import Condux

final class WorkspaceBackupsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testBackupThenRevertRestoresOriginal() throws {
        let file = root.appendingPathComponent("main.swift")
        try "print(1)\n".write(to: file, atomically: true, encoding: .utf8)
        let backups = WorkspaceBackups(directory: root.appendingPathComponent("backups"))
        let record = try backups.backup(path: file.path, tool: "Edit")
        XCTAssertNotNil(record.backupPath)
        try "print(2)\n".write(to: file, atomically: true, encoding: .utf8) // AI 가 고쳤다고 치고
        try backups.revert(record)
        XCTAssertEqual(try String(contentsOf: file), "print(1)\n")
    }

    func testDiffTextForModifiedAndNewFiles() throws {
        let file = root.appendingPathComponent("main.swift")
        try "print(1)\nlet a = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let backups = WorkspaceBackups(directory: root.appendingPathComponent("backups"))
        let record = try backups.backup(path: file.path, tool: "Edit")
        try "print(2)\nlet a = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let diff = WorkspaceBackups.diffText(record)
        XCTAssertTrue(diff.hasPrefix("### 변경 \(file.path) (Edit)\n```diff\n"), diff)
        XCTAssertTrue(diff.contains("-print(1)") && diff.contains("+print(2)"), diff)
        XCTAssertTrue(diff.contains("이전/main.swift") && diff.contains("현재/main.swift"))

        let unchanged = try backups.backup(path: file.path, tool: "Edit")
        XCTAssertTrue(WorkspaceBackups.diffText(unchanged).contains("내용 변화 없음"))

        let fresh = root.appendingPathComponent("New.swift")
        let newRecord = try backups.backup(path: fresh.path, tool: "Write")
        try "struct New {}\n".write(to: fresh, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorkspaceBackups.diffText(newRecord), "### 새 파일 \(fresh.path)\n```\nstruct New {}\n\n```")

        var reverted = record
        reverted.reverted = true
        let combined = WorkspaceBackups.reviewDiffs([reverted, newRecord])
        XCTAssertFalse(combined.contains("print(2)"), "되돌린 기록은 제외")
        XCTAssertTrue(combined.contains("struct New"))
    }

    func testRevertOfNewFileDeletesIt() throws {
        let file = root.appendingPathComponent("New.swift")
        let backups = WorkspaceBackups(directory: root.appendingPathComponent("backups"))
        let record = try backups.backup(path: file.path, tool: "Write")
        XCTAssertNil(record.backupPath, "없던 파일은 백업이 없고 되돌리기는 삭제")
        try "new".write(to: file, atomically: true, encoding: .utf8)
        try backups.revert(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testApprovalSummaryForClaudeEditShowsDiffAndPaths() {
        let input: JSONValue = ["file_path": "/tmp/a.swift", "old_string": "let a = 1", "new_string": "let a = 2"]
        XCTAssertEqual(ApprovalSummary.claudeFilePaths(tool: "Edit", input: input), ["/tmp/a.swift"])
        let text = ApprovalSummary.claudeText(tool: "Edit", input: input)
        XCTAssertTrue(text.contains("- let a = 1"))
        XCTAssertTrue(text.contains("+ let a = 2"))
        XCTAssertEqual(ApprovalSummary.claudeFilePaths(tool: "Bash", input: ["command": "rm -rf x"]), [])
        XCTAssertTrue(ApprovalSummary.claudeText(tool: "Bash", input: ["command": "swift build"]).hasPrefix("$ swift build"))
        let codex: JSONValue = ["changes": [["path": "Sources/A.swift", "kind": "update", "diff": "-x\n+y"]]]
        XCTAssertEqual(ApprovalSummary.codexFilePaths(params: codex), ["Sources/A.swift"])
        XCTAssertTrue(ApprovalSummary.codexText(method: "item/fileChange/requestApproval", params: codex).contains("+y"))
    }
}
