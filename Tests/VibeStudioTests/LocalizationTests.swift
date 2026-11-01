import AppKit
import XCTest
@testable import Condux

final class LocalizationTests: XCTestCase {
    override func tearDown() { Tr.set(.korean) }

    func testKoreanIsDefaultInTestsAndUnchanged() {
        XCTAssertEqual(tr("새 대화"), "새 대화")
        XCTAssertEqual(FriendlyText.activityTitle("도구 Bash"), "명령 실행 (Bash)")
    }

    func testEnglishExactPatternsAndSegments() {
        Tr.set(.english)
        XCTAssertEqual(tr("새 대화"), "New Conversation")
        XCTAssertEqual(tr("다운로드 중 412 MB / 1 GB (41%)"), "Downloading 412 MB / 1 GB (41%)")
        XCTAssertEqual(tr("릴레이 시작 · 구현 Claude API → 검토 OpenAI API · 최대 3회"),
                       "Relay started · implement Claude API → review OpenAI API · up to 3 rounds")
        XCTAssertEqual(tr("릴레이 완료 · 검토자 승인 (라운드 1)"), "Relay finished · Approved by the reviewer (round 1)")
        XCTAssertEqual(tr("빌드 결과 · 실패 · 오류 2개 · 종료코드 1 · 4초"), "Build result · Failed · 2 errors · exit code 1 · 4s")
        XCTAssertEqual(tr("구독 사용량 5시간 창 12% · 7일 창 62%"), "Subscription usage 5-hour window 12% · 7-day window 62%")
        XCTAssertEqual(tr("예상 비용 $0.0531 / 예산 $1.00"), "Estimated cost $0.0531 / budget $1.00")
        XCTAssertEqual(FriendlyText.activityTitle("승인 요청 · Edit"), "Allow? Edit a file (Edit)")
        XCTAssertEqual(tr(FriendlyText.activityTitle("도구 호출 시도 Bash")), "No tools · Run command (Bash)")
        XCTAssertEqual(FriendlyText.composerHint, "Enter to send · Shift+Enter for a new line · + or drag to attach · ⌘V to paste a copied image · ⌘? for help")
        XCTAssertEqual(tr("로컬 AI (MLX)"), Provider.localLLM.displayName)
        XCTAssertEqual(Provider.localLLM.displayName, "Local AI (MLX)")
    }

    func testEnglishLeavesUnknownAndAIContentAlone() {
        Tr.set(.english)
        XCTAssertEqual(tr("표에 없는 사용자 문장입니다"), "표에 없는 사용자 문장입니다", "없으면 원문 그대로")
        XCTAssertEqual(tr("No Korean here"), "No Korean here")
        XCTAssertEqual(tr(""), "")
    }

    func testEveryEnglishEntryHasNoKoreanAndKeepsPlaceholders() {
        for line in Translations.text.split(separator: "\n") {
            let parts = line.components(separatedBy: " ==> ")
            XCTAssertEqual(parts.count, 2, String(line))
            guard parts.count == 2 else { continue }
            let hangul = parts[1].unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
            XCTAssertFalse(hangul, "영어 칸에 한글: \(line)")
            XCTAssertEqual(parts[0].components(separatedBy: "{}").count, parts[1].components(separatedBy: "{}").count, "값 자리 수가 다름: \(line)")
        }
    }

    @MainActor
    func testRecommendedSettingsApplyAndLeaveKeysAlone() {
        let suite = "condux-reco-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConversationStore(directory: directory), defaults: defaults,
                             secrets: InMemorySecretStore(), apiTransport: FakeAPITransport())
        model.saveClaudeAPIKey("sk-claude-test")
        model.workspacePath = "/tmp/project"
        model.claudeAPIModel = "claude-opus-5-5"
        model.claudeEffort = "max"
        model.claudeAPIDefaultBudgetUSD = 5
        model.relayMaxRounds = 5
        model.relayAutoApproveEdits = true
        model.autoApproveEdits = true
        model.preferredNewConversationProvider = .codex
        XCTAssertFalse(model.usesRecommendedSettings)

        model.applyRecommendedSettings()
        XCTAssertTrue(model.usesRecommendedSettings)
        XCTAssertEqual(model.claudeAPIModel, "claude-sonnet-5-5")
        XCTAssertEqual(model.claudeEffort, "")
        XCTAssertEqual(model.claudeAPIDefaultBudgetUSD, 1)
        XCTAssertEqual(model.relayMaxRounds, 3)
        XCTAssertFalse(model.autoApproveEdits, "파일 수정 자동 허용은 끕니다")
        XCTAssertFalse(model.relayAutoApproveEdits)
        XCTAssertNil(model.preferredNewConversationProvider)
        XCTAssertEqual(model.relayReviewer, .claudeAPI, "키가 있는 연결을 검토자로")
        XCTAssertTrue(model.claudeAPIKeyPresent, "키는 그대로")
        XCTAssertEqual(model.workspacePath, "/tmp/project", "폴더는 그대로")
        XCTAssertEqual(defaults.string(forKey: "claudeAPIModel"), "claude-sonnet-5-5", "저장됩니다")
    }

    func testGitHubStatusReadsOnlyActiveLogin() {
        let signedIn = #"{"hosts":{"github.com":[{"state":"success","active":false,"login":"old"},{"state":"success","active":true,"login":"pgup3017","tokenSource":"keyring"}]}}"#
        XCTAssertEqual(GitHubStatus.parse(Data(signedIn.utf8)), .loggedIn("pgup3017"))
        XCTAssertEqual(GitHubStatus.parse(Data(#"{"hosts":{}}"#.utf8)), .loggedOut)
        XCTAssertEqual(GitHubStatus.parse(Data(#"{"hosts":{"github.com":[{"state":"failure","active":true,"login":"x"}]}}"#.utf8)), .loggedOut)
        XCTAssertEqual(GitHubStatus.parse(Data("oops".utf8)), .loggedOut)
        Tr.set(.english)
        XCTAssertEqual(tr("pgup3017 로 로그인됨 · 폴더 대화에서 AI 가 승인을 받고 git·gh 를 씁니다"),
                       "Signed in as pgup3017 · In folder conversations, the AI uses git and gh with your approval")
    }

    func testClipboardDecidesBetweenAttachmentAndText() {
        let board = NSPasteboard(name: NSPasteboard.Name("condux-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        let tiff = image.tiffRepresentation!

        board.clearContents()
        board.setString("그냥 글", forType: .string)
        XCTAssertFalse(ClipboardContent.isAttachable(board), "글은 글로 붙입니다")

        board.clearContents()
        board.setData(tiff, forType: .tiff)
        XCTAssertTrue(ClipboardContent.isAttachable(board), "스크린샷")

        board.clearContents()
        board.declareTypes([.tiff, .string], owner: nil)
        board.setData(tiff, forType: .tiff)
        board.setString("표 내용 A B", forType: .string)
        XCTAssertFalse(ClipboardContent.isAttachable(board), "엑셀처럼 글과 그림이 같이 있으면 글")

        board.clearContents()
        board.declareTypes([.tiff, .string], owner: nil)
        board.setData(tiff, forType: .tiff)
        board.setString("https://example.com/a.png", forType: .string)
        XCTAssertTrue(ClipboardContent.isAttachable(board), "브라우저 이미지 복사는 주소가 같이 옵니다")

        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a.png") as NSURL])
        XCTAssertTrue(ClipboardContent.isAttachable(board), "Finder 파일 복사")
    }

    @MainActor
    func testUsageFromCodexEventsAndOldFilesAndEnglish() throws {
        let suite = "condux-usage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConversationStore(directory: directory), defaults: defaults,
                             secrets: InMemorySecretStore(), apiTransport: FakeAPITransport())
        let now = Date()
        model.conversations = [StoredConversation(id: "t1", provider: .codex, title: "대화", createdAt: now, updatedAt: now, messages: [])]
        model.select("t1")
        XCTAssertEqual(model.usageChipText, "사용량", "아직 값이 없을 때")

        model.handleNotification("thread/tokenUsage/updated", [
            "threadId": "t1",
            "tokenUsage": ["modelContextWindow": 500_000,
                           "last": ["totalTokens": 50_000], "total": ["totalTokens": 90_000, "inputTokens": 80_000, "outputTokens": 10_000]],
        ])
        XCTAssertEqual(model.selectedUsage, ConversationUsage(contextTokens: 50_000, contextWindow: 500_000, totalInputTokens: 80_000, totalOutputTokens: 10_000))
        XCTAssertEqual(model.usageChipText, "컨텍스트 10%")

        model.handleNotification("account/rateLimits/updated", [
            "rateLimits": ["primary": ["usedPercent": 12, "windowDurationMins": 300], "secondary": ["usedPercent": 62, "windowDurationMins": 10080]],
        ])
        XCTAssertEqual(model.subscriptionUsageSummary, "구독 사용량 5시간 창 12% · 7일 창 62%")

        // 사용량이 없는 예전 저장 파일도 읽힙니다.
        let old = #"{"id":"x","title":"예전","createdAt":0,"updatedAt":0,"messages":[]}"#
        let decoded = try JSONDecoder().decode(StoredConversation.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.usage, ConversationUsage())

        XCTAssertNil(ModelContextWindow.tokens(for: "모르는-모델"), "모르면 비율을 만들지 않습니다")
        XCTAssertNil(ConversationUsage(contextTokens: 10).contextPercent)
        XCTAssertEqual(ConversationUsage(contextTokens: 2_000_000, contextWindow: 1_000_000).contextPercent, 100)

        Tr.set(.english)
        XCTAssertEqual(tr("컨텍스트 10%"), "Context 10%")
        XCTAssertEqual(tr("184,200 / 1,000,000 토큰 (19%)"), "184,200 / 1,000,000 tokens (19%)")
        XCTAssertEqual(tr("보냄 1,000 · 받음 20"), "Sent 1,000 · Received 20")
        XCTAssertEqual(tr("50 토큰 · 이 모델의 한도는 알 수 없습니다"), "50 tokens · This model's limit is unknown")
    }

    @MainActor
    func testAppearanceDefaultsToDarkTogglesAndPersists() {
        let suite = "condux-look-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory)
        let model = AppModel(store: store, defaults: defaults, secrets: InMemorySecretStore(), apiTransport: FakeAPITransport())
        XCTAssertEqual(model.appAppearance, .dark, "처음에는 어두운 화면")
        XCTAssertTrue(model.isDarkAppearance)
        model.toggleAppearance()
        XCTAssertEqual(model.appAppearance, .light)
        XCTAssertFalse(model.isDarkAppearance)
        XCTAssertEqual(defaults.string(forKey: AppAppearance.defaultsKey), "light", "저장됩니다")
        let reopened = AppModel(store: store, defaults: defaults, secrets: InMemorySecretStore(), apiTransport: FakeAPITransport())
        XCTAssertEqual(reopened.appAppearance, .light, "다시 켜도 유지됩니다")
    }

    @MainActor
    func testFreshConversationIsCreatedOnFirstSend() async throws {
        let suite = "condux-fresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeAPITransport()
        transport.lines = FakeAPITransport.happyTurn
        let model = AppModel(store: ConversationStore(directory: directory), defaults: defaults,
                             secrets: InMemorySecretStore(), apiTransport: transport)
        model.saveClaudeAPIKey("sk-claude-test")

        model.startFreshConversation(provider: .claudeAPI)
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.conversations.isEmpty, "눌렀다고 빈 대화가 생기지 않습니다")
        XCTAssertEqual(model.composerProvider, .claudeAPI)
        XCTAssertFalse(model.composerCanSend, "입력이 없으면 못 보냅니다")

        model.draft = "안녕"
        XCTAssertTrue(model.composerCanSend)
        await model.sendFromComposer()
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertEqual(model.conversations[0].provider, .claudeAPI)
        XCTAssertNil(model.startProvider, "한 번 쓰면 비웁니다")
        let deadline = Date().addingTimeInterval(5)
        while model.progress.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(model.progress.state, .completed)
    }
}
