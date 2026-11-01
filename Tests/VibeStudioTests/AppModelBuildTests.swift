import XCTest
@testable import Condux

/// 작업 폴더 대화에서 ‘빌드 실행’이 진짜 `swift build` 를 돌리고, 오류를 항목과 입력창에 넣는지 확인합니다.
/// AI 호출은 없고, 작은 Swift 패키지를 임시 폴더에 만들어 씁니다.
@MainActor
final class AppModelBuildTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("condux-buildtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "condux-build-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        model = AppModel(store: ConversationStore(directory: directory.appendingPathComponent("store")), defaults: defaults,
                         secrets: InMemorySecretStore(), apiTransport: FakeAPITransport())
    }

    override func tearDownWithError() throws {
        model.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makePackage(broken: Bool) throws -> URL {
        let pkg = directory.appendingPathComponent("Pkg")
        let sources = pkg.appendingPathComponent("Sources/Pkg")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Pkg", targets: [.target(name: "Pkg")])
        """.write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try (broken ? "let x: Int = \"문자열\"\n" : "let x: Int = 1\n").write(to: sources.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        return pkg
    }

    func testBuildDetectsCommandRunsAndFeedsErrorsToDraft() async throws {
        let pkg = try makePackage(broken: true)
        // 작업 폴더 대화를 흉내 냅니다 (CLI 없이 저장 모델만).
        model.workspacePath = pkg.path
        let now = Date()
        model.conversations = [StoredConversation(id: "ws-1", provider: .claude, title: "빌드", createdAt: now, updatedAt: now,
                                                  messages: [], workspacePath: pkg.path)]
        model.select("ws-1")

        await model.refreshBuildCommand()
        XCTAssertEqual(model.buildCommandDraft, "swift build")

        await model.runBuild()
        let result = try XCTUnwrap(model.lastBuildResult)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.errors.isEmpty, result.outputTail)
        XCTAssertTrue(result.errors.contains { $0.file.hasSuffix("A.swift") }, "오류 파일을 알아봐야 합니다")
        let entry = try XCTUnwrap(model.entries.last { $0.id.hasPrefix("build-") })
        XCTAssertEqual(entry.status, "실패")
        XCTAssertTrue(entry.title.contains("실패"))
        XCTAssertTrue(entry.text.contains("A.swift"))

        model.insertBuildErrorsIntoDraft()
        XCTAssertTrue(model.draft.hasPrefix("빌드가 실패했습니다."))
        XCTAssertTrue(model.draft.contains("A.swift"))
        XCTAssertTrue(model.draft.contains("(빌드 명령: swift build)"))
        XCTAssertEqual(defaults.string(forKey: "buildCommand:" + pkg.path), "swift build", "실행한 명령은 폴더별로 저장")

        // 고친 뒤 다시 빌드하면 성공으로 바뀝니다.
        _ = try makePackage(broken: false)
        await model.runBuild()
        XCTAssertTrue(model.lastBuildResult?.succeeded ?? false, model.lastBuildResult?.outputTail ?? "")
        XCTAssertEqual(model.entries.last { $0.id.hasPrefix("build-") }?.status, "성공")
    }
}
