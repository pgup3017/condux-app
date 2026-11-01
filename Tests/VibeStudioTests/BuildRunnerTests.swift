import XCTest
@testable import Condux

final class BuildRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("condux-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParserExtractsErrorsAndWarningsOnce() {
        let output = """
        Compiling A.swift
        /tmp/p/Sources/A.swift:12:9: error: cannot find 'foo' in scope
        /tmp/p/Sources/A.swift:12:9: error: cannot find 'foo' in scope
        /tmp/p/Sources/B.swift:3:1: warning: variable 'x' was never used
        ** BUILD FAILED **
        """
        let issues = BuildOutputParser.issues(in: output)
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues[0].severity, "error")
        XCTAssertEqual(issues[0].line, 12)
        XCTAssertEqual(issues[0].summary, "A.swift:12: cannot find 'foo' in scope")
        XCTAssertEqual(issues[1].severity, "warning")
    }

    func testDetectorPrefersWorkspaceThenProjectThenPackage() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let withProject = BuildCommandDetector.detect(in: root, listSchemes: { _ in ["AppScheme"] })
        XCTAssertEqual(withProject, "xcodebuild -project 'App.xcodeproj' -scheme 'AppScheme' build")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcworkspace"), withIntermediateDirectories: true)
        let withWorkspace = BuildCommandDetector.detect(in: root, listSchemes: { _ in [] })
        XCTAssertEqual(withWorkspace, "xcodebuild -workspace 'App.xcworkspace' -scheme 'App' build", "스킴을 못 읽으면 이름을 씁니다")
        try FileManager.default.removeItem(at: root.appendingPathComponent("App.xcworkspace"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("App.xcodeproj"))
        XCTAssertEqual(BuildCommandDetector.detect(in: root, listSchemes: { _ in [] }), "swift build")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(BuildCommandDetector.detect(in: empty, listSchemes: { _ in [] }))
    }

    func testRunnerCapturesOutputExitCodeAndIssues() async {
        let runner = BuildRunner()
        let script = "echo start; echo '/tmp/x/Sources/A.swift:4:2: error: boom' 1>&2; exit 3"
        var seen: [String] = []
        let result = await runner.run(command: script, in: root) { seen.append($0) }
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.errors.map(\.message), ["boom"])
        XCTAssertTrue(result.outputTail.contains("start"))
        XCTAssertTrue(seen.contains("start"))
        XCTAssertTrue(result.statusText.hasPrefix("실패 · 오류 1개"))

        let ok = await runner.run(command: "echo done", in: root)
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.statusText, "성공")
    }

    func testRunnerCanBeCancelled() async {
        let runner = BuildRunner()
        async let result = runner.run(command: "sleep 30; echo never", in: root)
        try? await Task.sleep(for: .milliseconds(300))
        runner.cancel()
        let r = await result
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.statusText, "중단됨")
        XCTAssertFalse(r.outputTail.contains("never"))
    }
}
