import XCTest
@testable import Condux

/// 예전 저장 파일(provider 필드 없음)이 그대로 읽히고, 새 필드가 함께 저장되는지 확인합니다.
final class ConversationStoreTests: XCTestCase {
    func testLegacyFileWithoutProviderDecodesAsCodex() throws {
        let legacy = """
        [{"id":"thread-1","title":"예전 대화","createdAt":"2026-10-30T10:00:00Z","updatedAt":"2026-10-30T10:05:00Z",
          "messages":[{"id":"m1","role":"user","title":"","text":"안녕","status":""},{"id":"m2","role":"assistant","title":"","text":"안녕하세요","status":""}]}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conversations = try decoder.decode([StoredConversation].self, from: Data(legacy.utf8))
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].provider, .codex)
        XCTAssertFalse(conversations[0].claudeSessionReady)
        XCTAssertEqual(conversations[0].messages.count, 2)
    }

    /// 모르는 연결이 든 대화가 있어도 나머지는 살리고, 저장으로 덮어쓰기 전에 원본을 따로 보관합니다.
    func testUnreadableConversationDoesNotWipeHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConversationStore(directory: folder)
        let original = """
        [{"id":"good","title":"살아남을 대화","createdAt":"2026-10-30T10:00:00Z","updatedAt":"2026-10-30T10:05:00Z","messages":[]},
         {"id":"future","provider":"futureProvider","title":"미래 버전 대화","createdAt":"2026-10-30T10:00:00Z","updatedAt":"2026-10-30T10:05:00Z","messages":[]}]
        """
        try Data(original.utf8).write(to: store.fileURL)

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.id), ["good"])
        XCTAssertTrue(store.loadWarning?.contains("대화 1개를 읽지 못했습니다") ?? false, store.loadWarning ?? "-")

        func rescued() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("conversations.unreadable-") }
        }
        XCTAssertEqual(try rescued().count, 1)
        store.save(loaded)
        let copy = try Data(contentsOf: folder.appendingPathComponent(try rescued()[0]))
        XCTAssertEqual(copy, Data(original.utf8), "덮어써도 원본이 남아야 합니다")
        XCTAssertNil({ _ = store.load(); return store.loadWarning }(), "저장 후 다시 읽으면 안내가 사라집니다")

        // 파일 전체가 깨져도 지우지 않습니다.
        try Data("깨진 파일".utf8).write(to: store.fileURL)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(store.loadWarning?.contains("대화 기록을 읽지 못했습니다") ?? false)
        XCTAssertEqual(try rescued().count, 2)
    }

    func testDailySnapshotKeepsLastSeven() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConversationStore(directory: folder)
        let history = folder.appendingPathComponent("conversation-history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        for day in 1...8 { try Data("[]".utf8).write(to: history.appendingPathComponent("conversations-2026-01-0\(day).json")) }
        store.save([StoredConversation(id: "a", title: "t", createdAt: Date(), updatedAt: Date(), messages: [])])
        XCTAssertEqual(store.load().count, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: history.path).sorted()
        XCTAssertEqual(names.count, 7)
        XCTAssertFalse(names.contains("conversations-2026-01-01.json"), "오래된 것부터 지웁니다")
        XCTAssertTrue(names.last?.contains("2026-01") == false, "오늘 것이 있어야 합니다")

        // 비어 있는 기록은 복사하지 않습니다.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: empty) }
        let emptyStore = ConversationStore(directory: empty)
        emptyStore.save([])
        XCTAssertTrue(emptyStore.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.appendingPathComponent("conversation-history").path))
    }

    func testClaudeConversationRoundTrips() throws {
        let original = StoredConversation(id: "11111111-2222-3333-4444-555555555555", provider: .claude, title: "Claude 대화",
                                          createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                                          messages: [], claudeSessionReady: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let copy = try decoder.decode(StoredConversation.self, from: try encoder.encode(original))
        XCTAssertEqual(copy.provider, .claude)
        XCTAssertTrue(copy.claudeSessionReady)
        XCTAssertEqual(copy.id, original.id)
    }
}
