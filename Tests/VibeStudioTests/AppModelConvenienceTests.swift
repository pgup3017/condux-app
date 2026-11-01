import XCTest
@testable import Condux

/// 검색·이름 바꾸기·마크다운 내보내기·도구 결과 이미지 저장 (AI 호출 없음)
@MainActor
final class AppModelConvenienceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("condux-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "condux-conv-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        model = AppModel(store: ConversationStore(directory: directory.appendingPathComponent("store")), defaults: defaults,
                         secrets: InMemorySecretStore(), apiTransport: FakeAPITransport())
        let now = Date()
        model.conversations = [
            StoredConversation(id: "a", provider: .claude, title: "빌드 오류 고치기", createdAt: now, updatedAt: now, messages: [
                StoredMessage(id: "1", role: .user, text: "xcodebuild 가 실패해", attachmentNames: ["log.zip"]),
                StoredMessage(id: "2", role: .assistant, text: "원인은 **링커** 설정입니다.\n\n```swift\nlet x = 1\n```"),
                StoredMessage(id: "3", role: .activity, title: "생각 정리", text: ""),
                StoredMessage(id: "4", role: .approval, title: "승인 요청 · Edit", text: "a.swift", status: "허용됨"),
                StoredMessage(id: "5", role: .file, title: "report.md", text: "/tmp/report.md", status: "1 KB"),
            ], workspacePath: "/tmp/proj"),
            StoredConversation(id: "b", provider: .openAIAPI, title: "인사", createdAt: now, updatedAt: now, messages: [
                StoredMessage(id: "1", role: .user, text: "안녕"),
            ], apiBudgetUSD: 1, apiSpentUSD: 0.0123),
        ]
    }

    override func tearDownWithError() throws {
        model.flushAndDisconnect()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testSearchFiltersByTitleAndBody() {
        XCTAssertEqual(model.filteredConversations.map(\.id), ["a", "b"])
        model.searchText = "링커"
        XCTAssertEqual(model.filteredConversations.map(\.id), ["a"], "본문으로도 찾습니다")
        model.searchText = "인사"
        XCTAssertEqual(model.filteredConversations.map(\.id), ["b"])
        model.searchText = "없는말"
        XCTAssertTrue(model.filteredConversations.isEmpty)
    }

    func testRenameTrimsAndPersists() {
        model.beginRename("a")
        XCTAssertEqual(model.renameDraft, "빌드 오류 고치기")
        model.renameDraft = "  링커 수정  "
        model.commitRename()
        XCTAssertNil(model.renameTargetID)
        XCTAssertEqual(model.conversations[0].title, "링커 수정")
        XCTAssertEqual(ConversationStore(directory: directory.appendingPathComponent("store")).load().first?.title, "링커 수정")
        model.beginRename("a")
        model.renameDraft = "   "
        model.commitRename()
        XCTAssertEqual(model.conversations[0].title, "링커 수정", "빈 이름은 무시")
    }

    func testMarkdownExportIncludesMessagesAndSkipsEmptyThinking() {
        let markdown = model.conversationMarkdown("a")
        XCTAssertTrue(markdown.hasPrefix("# 빌드 오류 고치기\n"))
        XCTAssertTrue(markdown.contains("- 연결: Claude (구독)") || markdown.contains("- 연결: Claude"), markdown)
        XCTAssertTrue(markdown.contains("- 작업 폴더: /tmp/proj"))
        XCTAssertTrue(markdown.contains("## 나\n\nxcodebuild 가 실패해\n\n첨부: log.zip"))
        XCTAssertTrue(markdown.contains("```swift\nlet x = 1\n```"))
        XCTAssertFalse(markdown.contains("생각 정리"), "빈 생각 정리는 뺍니다")
        XCTAssertTrue(markdown.contains("> **승인 요청 · Edit** · 허용됨"))
        XCTAssertTrue(markdown.contains("> **받은 파일** · report.md · /tmp/report.md"))
        let api = model.conversationMarkdown("b")
        XCTAssertTrue(api.contains("- 예상 비용: $0.0123 / 예산 $1.00"), api)
    }

    func testWorkspaceCanBeAttachedToClaudeConversationOnly() {
        model.setConversationWorkspace("b", path: "/tmp/x")
        XCTAssertEqual(model.conversations[1].workspacePath, "", "API/Codex 대화는 지원하지 않음")
        XCTAssertTrue(model.notice?.contains("Claude 구독 대화에만") ?? false)
        model.setConversationWorkspace("a", path: nil)
        XCTAssertEqual(model.conversations[0].workspacePath, "")
        model.setConversationWorkspace("a", path: "/tmp/other")
        XCTAssertEqual(model.conversations[0].workspacePath, "/tmp/other")
        XCTAssertEqual(ConversationStore(directory: directory.appendingPathComponent("store")).load().first?.workspacePath, "/tmp/other")
    }

    func testAutoApproveOnlyInsideWorkspaceOrOutputs() {
        let roots = ["/tmp/proj", "/tmp/outputs/a"]
        XCTAssertTrue(AppModel.pathsAreInside(["/tmp/proj/Sources/A.swift", "/tmp/outputs/a/report.md"], roots: roots))
        XCTAssertFalse(AppModel.pathsAreInside(["/tmp/proj/../.zshrc"], roots: roots), "상위 폴더 탈출 차단")
        XCTAssertFalse(AppModel.pathsAreInside(["/tmp/project2/A.swift"], roots: roots), "이름만 비슷한 폴더 차단")
        XCTAssertFalse(AppModel.pathsAreInside(["/Users/x/.ssh/config"], roots: roots))
        XCTAssertFalse(AppModel.pathsAreInside([], roots: roots))
        XCTAssertFalse(AppModel.pathsAreInside(["/tmp/proj/A.swift", "/etc/hosts"], roots: roots), "하나라도 밖이면 전체 거부")
        let conversation = model.conversations[0]
        XCTAssertEqual(model.autoApproveRoots(for: conversation).first, "/tmp/proj")
        XCTAssertEqual(model.autoApproveRoots(for: conversation).count, 2)
    }

    func testSelectByIndexAndDeleteConfirmation() {
        model.selectConversation(at: 1)
        XCTAssertEqual(model.selectedID, "b")
        model.searchText = "빌드"
        model.selectConversation(at: 0)
        XCTAssertEqual(model.selectedID, "a", "필터된 목록 기준")
        model.selectConversation(at: 5)
        XCTAssertEqual(model.selectedID, "a", "범위 밖은 무시")
        model.confirmDelete("b")
        XCTAssertEqual(model.deleteTargetID, "b")
        XCTAssertEqual(model.conversations.count, 2, "확인 전에는 지우지 않음")
        model.deleteConversation("b")
        XCTAssertEqual(model.conversations.map(\.id), ["a"])
    }

    func testPreferredProviderIsUsedOnlyWhenReady() {
        model.saveClaudeAPIKey("sk-claude-test")
        model.saveOpenAIAPIKey("sk-openai-test")
        XCTAssertEqual(model.defaultNewConversationProvider, .claudeAPI, "자동: 준비된 것 중 먼저")
        model.preferredNewConversationProvider = .openAIAPI
        XCTAssertEqual(model.defaultNewConversationProvider, .openAIAPI)
        model.preferredNewConversationProvider = .codex
        XCTAssertEqual(model.defaultNewConversationProvider, .claudeAPI, "Codex 연결이 없으면 자동으로")
        XCTAssertEqual(defaults.string(forKey: "preferredNewConversationProvider"), "codex", "선택은 저장됨")
        model.preferredNewConversationProvider = nil
        XCTAssertEqual(model.defaultNewConversationProvider, .claudeAPI)
    }

    func testToolResultImagesAreSavedAsReceivedFiles() throws {
        let png = directory.appendingPathComponent("p.png")
        try TestFiles.png(at: png, size: 8)
        let base64 = try Data(contentsOf: png).base64EncodedString()
        let blocks: [JSONValue] = [
            ["type": "text", "text": "결과"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(base64)]],
            ["type": "image", "source": ["type": "base64", "media_type": "image/webp", "data": .string(base64)]],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "!!notbase64"]],
            ["type": "image", "data": .string(base64), "mimeType": "image/jpeg"], // MCP(Codex) 형식
        ]
        XCTAssertEqual(model.saveToolResultImages(blocks, conversationID: "a", toolName: "mcp__mobbin__search_screens"), 3)
        let files = model.attachmentStore.newReceivedFiles(for: "a", known: [])
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.allSatisfy { $0.name.hasPrefix("mcp__mobbin__search_screens-") })
        XCTAssertEqual(Set(files.map { ($0.name as NSString).pathExtension }), ["png", "webp", "jpg"])
    }
}
