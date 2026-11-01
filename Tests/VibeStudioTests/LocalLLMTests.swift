import XCTest
import CryptoKit
@testable import Condux

final class LocalLLMTests: XCTestCase {
    private var root: URL!
    private var store: LocalModelStore!
    private let bytes = Data("fake model".utf8)
    private var fixture: LocalModelStore.File {
        .init(name: "model.safetensors", size: Int64(bytes.count),
              sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = LocalModelStore(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fetch(_ data: Data, status: Int = 200) -> LocalModelStore.Fetch {
        return { request in
            let url = request.url
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertTrue(url.path.contains(LocalModelStore.revision))
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testDownloadVerifiesInstallsAndDeletesOnlyOwnModel() async throws {
        XCTAssertFalse(store.isReady(files: [fixture]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let size = fixture.size
        try await store.download(files: [fixture], fetch: fetch(bytes)) { done, total in
            XCTAssertEqual(done, size); XCTAssertEqual(total, size)
        }
        XCTAssertTrue(store.isReady(files: [fixture]))
        try store.delete()
        XCTAssertFalse(store.isReady(files: [fixture]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCorruptDownloadDoesNotReplaceGoodInstallation() async throws {
        try await store.download(files: [fixture], fetch: fetch(bytes)) { _, _ in }
        do {
            try await store.download(files: [fixture], fetch: fetch(Data("bad bytes!".utf8))) { _, _ in }
            XCTFail("검증 실패여야 합니다")
        } catch { XCTAssertTrue(error is LocalLLMError) }
        XCTAssertTrue(store.isReady(files: [fixture]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("qwen3-1.7b-4bit.partial").path))
    }

    func testHTTPFailureDoesNotMarkModelReady() async throws {
        do {
            try await store.download(files: [fixture], fetch: fetch(bytes, status: 503)) { _, _ in }
            XCTFail("HTTP 실패여야 합니다")
        } catch { XCTAssertTrue(error is LocalLLMError) }
        XCTAssertFalse(store.isReady(files: [fixture]))
    }

    func testCancellationKeepsPartialForResumeAndDeleteClearsIt() async throws {
        let store = self.store!, fixture = self.fixture
        let task = Task {
            try await store.download(files: [fixture], fetch: { request in
                try Data("resume".utf8).write(to: request.resumeFile)
                try await Task.sleep(for: .seconds(30))
                throw LocalLLMError.downloadFailed
            }) { _, _ in }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { try await task.value; XCTFail("중단되어야 합니다") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(store.isReady(files: [fixture]))
        XCTAssertTrue(store.hasPartial, "이어받을 정보가 남아야 합니다")

        // 다시 받으면 이어받기 정보를 그대로 쓰고, 끝나면 설치됩니다.
        let good = bytes
        try await store.download(files: [fixture], fetch: { request in
            XCTAssertEqual(try? Data(contentsOf: request.resumeFile), Data("resume".utf8))
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try good.write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url, statusCode: 206, httpVersion: nil, headerFields: nil)!)
        }) { _, _ in }
        XCTAssertTrue(store.isReady(files: [fixture]))
        XCTAssertFalse(store.hasPartial)

        try store.delete()
        XCTAssertFalse(store.isReady(files: [fixture]))
    }

    func testAlreadyVerifiedFilesAreNotDownloadedAgain() async throws {
        let store = self.store!, good = bytes
        let other = Data("second file".utf8)
        let first = fixture
        let second = LocalModelStore.File(name: "config.json", size: Int64(other.count),
                                          sha256: SHA256.hash(data: other).map { String(format: "%02x", $0) }.joined())
        // 첫 파일만 받고 둘째에서 끊김
        do {
            try await store.download(files: [first, second], fetch: { request in
                guard request.url.lastPathComponent == first.name else { throw URLError(.networkConnectionLost) }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try good.write(to: temporary)
                return (temporary, HTTPURLResponse(url: request.url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }) { _, _ in }
            XCTFail("끊겨야 합니다")
        } catch {}
        XCTAssertTrue(store.hasPartial)
        // 다시 받으면 둘째 파일만 요청합니다.
        try await store.download(files: [first, second], fetch: { request in
            XCTAssertEqual(request.url.lastPathComponent, second.name, "검증된 파일은 다시 받지 않습니다")
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try other.write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }) { _, _ in }
        XCTAssertTrue(store.isReady(files: [first, second]))
    }

    func testRejectedResumeRestartsOnceAndOfflineKeepsResumeInfo() async throws {
        let store = self.store!, fixture = self.fixture, good = bytes
        let partial = root.appendingPathComponent("qwen3-1.7b-4bit.partial")
        let resume = partial.appendingPathComponent("model.safetensors.resume")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        // 인터넷 끊김: 이어받을 정보를 지우지 않습니다.
        try Data("resume".utf8).write(to: resume)
        do {
            try await store.download(files: [fixture], fetch: { _ in throw URLError(.notConnectedToInternet) }) { _, _ in }
            XCTFail("끊겨야 합니다")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: resume.path))

        // 서버가 이어받기를 거절(403): 정보를 지우고 처음부터 받습니다.
        try await store.download(files: [fixture], fetch: { request in
            let resuming = FileManager.default.fileExists(atPath: request.resumeFile.path)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try good.write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url, statusCode: resuming ? 403 : 200, httpVersion: nil, headerFields: nil)!)
        }) { _, _ in }
        XCTAssertTrue(store.isReady(files: [fixture]))
    }

    /// 실제 Hugging Face 로 끊고 이어받기를 확인합니다. 몇 MB 만 받으며 `CONDUX_REAL_DOWNLOAD=1` 일 때만 돕니다.
    func testRealDownloadCancelsAndResumes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUX_REAL_DOWNLOAD"] == "1", "CONDUX_REAL_DOWNLOAD=1 일 때만 네트워크를 씁니다")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 작은 파일: 전체 경로와 지문 검증
        let config = try XCTUnwrap(LocalModelStore.files.first { $0.name == "config.json" })
        try await store.download(files: [config]) { _, _ in }
        XCTAssertTrue(store.isReady(files: [config]))

        // 큰 파일: 3MB 받고 중단, 다시 시작하면 그 근처에서 이어져야 합니다.
        let url = URL(string: "https://huggingface.co/\(LocalModelStore.modelID)/resolve/\(LocalModelStore.revision)/model.safetensors")!
        let resumeFile = root.appendingPathComponent("big.resume")
        final class Seen: @unchecked Sendable {
            let lock = NSLock(); var first: Int64?; var last: Int64 = 0
            func add(_ v: Int64) { lock.withLock { if first == nil { first = v }; last = max(last, v) } }
        }
        func partialRun(until limit: Int64) async throws -> Seen {
            let seen = Seen()
            let task = Task { try await ModelFileDownloader.fetch(.init(url: url, resumeFile: resumeFile) { seen.add($0) }) }
            let deadline = Date().addingTimeInterval(60)
            while seen.lock.withLock({ seen.last }) < limit, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            task.cancel()
            do { _ = try await task.value; XCTFail("중단되어야 합니다") } catch is CancellationError {} catch { XCTFail("\(error)") }
            try await Task.sleep(for: .milliseconds(500)) // 이어받기 정보 쓰기 대기
            return seen
        }
        let run1 = try await partialRun(until: 3_000_000)
        XCTAssertGreaterThanOrEqual(run1.last, 3_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path), "이어받기 정보가 남아야 합니다")
        let run2 = try await partialRun(until: run1.last + 1_000_000)
        let first = try XCTUnwrap(run2.first)
        print("REAL-RESUME 1회차 \(run1.last) · 2회차 시작 \(first) · 끝 \(run2.last)")
        XCTAssertGreaterThan(first, 1_000_000, "처음부터가 아니라 이어서 받아야 합니다")
    }

    func testLongContextIsRejectedBeforeEngineLoads() async {
        do {
            try await MLXLocalLLMClient().stream(directory: root, history: [], prompt: String(repeating: "가", count: 8_001)) { _ in }
            XCTFail("긴 대화는 거부해야 합니다")
        } catch LocalLLMError.contextTooLong {} catch { XCTFail("\(error)") }
    }
}
