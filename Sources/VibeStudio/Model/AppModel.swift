import Foundation
import AppKit
import Observation

struct LogLine: Identifiable {
    let id = UUID()
    let time = Date()
    let direction: String
    let text: String
}

struct TurnProgress: Equatable {
    enum State: String { case idle, requesting, running, completed, failed, interrupted }
    var state: State = .idle
    var turnID: String?
    var phase: String = "대기 중"
    var startedAt: Date?
    var isBusy: Bool { state == .requesting || state == .running }
}

@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case disconnected, starting, connected(String), failed(String)
        var label: String {
            switch self {
            case .disconnected: return "연결 안 됨"
            case .starting: return "연결 중…"
            case .connected(let ua): return "연결됨 · \(ua)"
            case .failed(let why): return "연결 실패: \(why)"
            }
        }
        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    var connection: Connection = .disconnected
    var accountSummary = "확인 전"
    var isLoggedIn = false
    var conversations: [StoredConversation] = []
    var selectedID: String?
    var entries: [ChatEntry] = []
    var progress = TurnProgress()
    var turnStartIndex: Int?
    var tokenSummary = ""
    var eventLog: [LogLine] = []
    var draft = ""
    var notice: String?
    var showInspector = false
    var showSettings = false
    var codexPathOverride: String {
        didSet { defaults.set(codexPathOverride, forKey: "codexPathOverride") }
    }
    var claudePathOverride: String {
        didSet { defaults.set(claudePathOverride, forKey: "claudePathOverride") }
    }

    /// Claude Code CLI 로그인 상태. 앱은 상태만 읽고 토큰은 다루지 않습니다.
    enum ClaudeAuthState: Equatable {
        case unknown, checking, unavailable(String), status(ClaudeAuthStatus)
        var label: String {
            switch self {
            case .unknown: return "Claude 확인 전"
            case .checking: return "Claude 확인 중…"
            case .unavailable(let why): return why
            case .status(let status): return status.summary
            }
        }
        var isLoggedIn: Bool { if case .status(let s) = self { return s.loggedIn }; return false }
        var version: String { if case .status(let s) = self { return s.version }; return "" }
    }
    /// Claude 모델 선택. 비우면 계정 기본 모델. CLI 의 `--model` 로 그대로 넘깁니다(별칭 haiku/sonnet/opus/fable 또는 전체 이름).
    var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: "claudeModel") }
    }
    /// Claude 노력 수준. 비우면 기본. CLI 의 `--effort` 로 넘깁니다.
    var claudeEffort: String {
        didSet { defaults.set(claudeEffort, forKey: "claudeEffort") }
    }
    static let claudeModelChoices: [(value: String, label: String)] = [
        ("", "계정 기본값"), ("haiku", "Haiku (빠르고 가벼움)"), ("sonnet", "Sonnet (균형)"),
        ("opus", "Opus (높은 품질)"), ("fable", "Fable (최상위)"),
    ]
    static let claudeEffortChoices: [(value: String, label: String)] = [
        ("", "기본"), ("low", "낮음"), ("medium", "중간"), ("high", "높음"), ("xhigh", "매우 높음"), ("max", "최대"),
    ]
    // MARK: Claude API (사용자 API 키, 구독과 별개)
    var claudeAPIModel: String {
        didSet { defaults.set(claudeAPIModel, forKey: "claudeAPIModel") }
    }
    var claudeAPIEffort: String {
        didSet { defaults.set(claudeAPIEffort, forKey: "claudeAPIEffort") }
    }
    /// 새 API 대화에 적용할 기본 작업 예산(달러). 기본 1달러.
    var claudeAPIDefaultBudgetUSD: Double {
        didSet { defaults.set(claudeAPIDefaultBudgetUSD, forKey: "claudeAPIDefaultBudgetUSD") }
    }
    var claudeAPIKeyPresent = false
    /// 설정 창에 입력 중인 키. 어떤 버튼으로 창을 닫아도 저장되도록 모델이 들고 있습니다.
    var claudeAPIKeyDraft = ""
    /// 설정 창 안에 바로 보여 줄 키 저장 결과.
    var claudeAPIKeyStatus = ""
    /// 마지막 API 답변을 실제로 만든 모델 (message_start 의 model)
    var claudeAPIServedModel = ""
    static let claudeAPIModelChoices: [(value: String, label: String)] = [
        ("claude-opus-5-5", "Opus 5.5 · 기본 (입력 $4 / 출력 $20 per 1M)"),
        ("claude-sonnet-5-5", "Sonnet 5.5 ($2 / $10)"),
        ("claude-haiku-5-5", "Haiku 5.5 ($0.10 / $0.50)"),
        ("claude-fable-5-1", "Fable 5.1 ($10 / $50)"),
    ]
    private static let claudeAPIKeyName = "claude-api-key"

    // MARK: OpenAI API (사용자 API 키, Responses API)
    var openAIAPIModel: String {
        didSet { defaults.set(openAIAPIModel, forKey: "openAIAPIModel") }
    }
    var openAIAPIEffort: String {
        didSet { defaults.set(openAIAPIEffort, forKey: "openAIAPIEffort") }
    }
    var openAIAPIKeyPresent = false
    var openAIAPIKeyDraft = ""
    var openAIAPIKeyStatus = ""
    var openAIAPIServedModel = ""
    static let openAIAPIModelChoices: [(value: String, label: String)] = [
        ("gpt-6.1-sol", "GPT-6.1 Sol · 기본 (입력 $2 / 출력 $10 per 1M)"),
        ("gpt-6.1-terra", "GPT-6.1 Terra ($1 / $5)"),
        ("gpt-6-luna", "GPT-6 Luna ($0.10 / $0.50)"),
        ("gpt-6-astra", "GPT-6 Astra ($10 / $50)"),
        ("gpt-5.4", "GPT-5.4 ($2.50 / $15)"),
        ("gpt-5.4-mini", "GPT-5.4 mini ($0.75 / $4.50)"),
    ]
    static let openAIEffortChoices: [(value: String, label: String)] = [
        ("", "기본"), ("low", "낮음"), ("medium", "중간"), ("high", "높음"),
    ]
    private static let openAIAPIKeyName = "openai-api-key"

    // MARK: 로컬 AI (직접 설치판, Apple Silicon, 텍스트 전용)
    private(set) var localModelReady = false
    var localModelStatus = "모델 다운로드 전 · 약 1GB"
    private var localDownloadTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private let localClient: LocalLLMGenerating
    let localModelStore: LocalModelStore
    var localLLMAvailable: Bool { !Self.isAppStoreBuild && localClient.isAvailable }
    var localModelDownloading: Bool { localDownloadTask != nil }
    /// 다운로드 진행률 0~1. 받는 중이 아니면 nil.
    private(set) var localDownloadFraction: Double?
    /// 중단했거나 끊겨서 이어받을 수 있는 파일이 있는지
    private(set) var localModelHasPartial = false

    func downloadLocalModel() {
        guard localLLMAvailable, !localModelDownloading, !progress.isBusy else { return }
        localModelStatus = "다운로드를 시작합니다. 인터넷 연결이 필요합니다."
        localDownloadFraction = 0
        localDownloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.localDownloadTask = nil
                self.localDownloadFraction = nil
                self.localModelHasPartial = self.localModelStore.hasPartial
            }
            do {
                try await self.localModelStore.download { [weak self] done, total in
                    guard let self, self.localModelDownloading, total > 0 else { return }
                    let fraction = max(self.localDownloadFraction ?? 0, Double(done) / Double(total))
                    self.localDownloadFraction = fraction
                    let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                    self.localModelStatus = "다운로드 중 \(size(Int64(fraction * Double(total)))) / \(size(total)) (\(Int(fraction * 100))%)"
                }
                self.localModelReady = self.localModelStore.isReady()
                self.localModelStatus = "모델 준비됨 · 다운로드 후에는 인터넷 없이 대화할 수 있습니다."
            } catch is CancellationError {
                self.localModelStatus = "다운로드를 중단했습니다. 다시 누르면 받은 곳부터 이어받습니다."
            } catch let error as URLError where error.code == .cancelled {
                self.localModelStatus = "다운로드를 중단했습니다. 다시 누르면 받은 곳부터 이어받습니다."
            } catch {
                self.localModelStatus = (error as? LocalLLMError)?.localizedDescription ?? LocalLLMError.downloadFailed.localizedDescription
            }
        }
    }

    func cancelLocalModelDownload() {
        localModelStatus = "다운로드 중단 요청 중…"
        localDownloadTask?.cancel()
    }

    func deleteLocalModel() {
        guard !progress.isBusy, !localModelDownloading else { return }
        do {
            try localModelStore.delete()
            localModelReady = false
            localModelHasPartial = false
            localModelStatus = "모델을 삭제했습니다. 대화 기록은 남아 있습니다."
        } catch { localModelStatus = "모델을 삭제하지 못했습니다. 저장 공간 접근 권한을 확인해 주세요." }
    }

    // MARK: 작업 폴더 모드 (구독판 전용)
    /// 새 대화에 적용할 작업 폴더. 비우면 텍스트 대화만. 대화를 만든 뒤에는 바꿀 수 없습니다.
    var workspacePath: String {
        didSet { defaults.set(workspacePath, forKey: "workspacePath") }
    }
    struct PendingApproval {
        let entryID: String
        let provider: Provider
        let requestID: String
        let tool: String
        let input: JSONValue?
        let filePaths: [String]
    }
    /// 아직 답하지 않은 승인 요청 (entryID → 요청)
    private(set) var pendingApprovals: [String: PendingApproval] = [:]
    var hasPendingApproval: Bool { !pendingApprovals.isEmpty }

    // MARK: 편의 기능
    /// 작업 폴더 대화에서 파일 수정(Write/Edit/패치) 승인 카드를 항상 자동 허용. 명령 실행은 계속 묻습니다. 백업·되돌리기는 그대로.
    var autoApproveEdits: Bool {
        didSet { defaults.set(autoApproveEdits, forKey: "autoApproveEdits") }
    }
    /// 사이드바 검색어 (제목·본문)
    var searchText = ""
    var filteredConversations: [StoredConversation] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return conversations }
        return conversations.filter { c in
            c.title.lowercased().contains(query) || c.messages.contains { $0.text.lowercased().contains(query) }
        }
    }
    /// 이름 바꾸기 창 상태
    var renameTargetID: String?
    var renameDraft = ""
    /// 도움말 ▸ 빠른 안내 창
    var showQuickGuide = false
    /// 연결 관리 창
    var showConnections = false
    /// 밝은·어두운 화면
    var appAppearance: AppAppearance {
        didSet {
            defaults.set(appAppearance.rawValue, forKey: AppAppearance.defaultsKey)
            appAppearance.apply()
        }
    }
    /// 지금 어두운 화면인지 (시스템 따르기 포함)
    var isDarkAppearance: Bool {
        switch appAppearance {
        case .dark: return true
        case .light: return false
        case .system: return (NSApp as NSApplication?)?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
    /// 도구 막대 버튼: 밝게 ↔ 어둡게
    func toggleAppearance() { appAppearance = isDarkAppearance ? .light : .dark }
    /// 화면 언어. 바꾸면 창 전체를 다시 그립니다.
    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: "appLanguage")
            Tr.set(appLanguage)
        }
    }
    /// 새 대화 화면에서 고른 연결. 첫 메시지를 보낼 때 씁니다. 없으면 기본 연결.
    var startProvider: Provider?

    // MARK: MCP 서버 (구독판)
    var mcpServers: [MCPServer] {
        didSet { MCPServerList.save(mcpServers, to: defaults) }
    }
    /// Claude CLI `system/init` 이 알려 준 서버 상태 (이름 → connected/needs-auth/failed/pending)
    var claudeMCPStatus: [String: String] = [:]
    /// Codex `mcpServerStatus/list` 결과 (이름 → 상태 문구)
    var codexMCPStatus: [String: String] = [:]
    var showMCPAddSheet = false
    var enabledMCPServers: [MCPServer] { Self.isAppStoreBuild ? [] : mcpServers.filter { $0.enabled && $0.isValid } }

    // MARK: 첨부 파일 / 받은 파일
    let attachmentStore: AttachmentStore
    /// 다음 메시지에 붙일 첨부 (입력창 위 칩)
    var pendingAttachments: [Attachment] = []
    /// 지금 보내는 턴의 첨부 (beginTurn 에서 옮겨 둠)
    private(set) var turnAttachments: [Attachment] = []

    // MARK: 자동 릴레이 (구현 → 검토 → 수정 순환)
    var relay: RelayState?
    var relayReviewer: Provider {
        didSet { defaults.set(relayReviewer.rawValue, forKey: "relayReviewer") }
    }
    var relayMaxRounds: Int {
        didSet { defaults.set(relayMaxRounds, forKey: "relayMaxRounds") }
    }
    /// 릴레이 중 파일 수정 승인을 자동으로 허용(백업은 그대로). 명령 실행은 항상 사용자가 승인합니다.
    var relayAutoApproveEdits: Bool {
        didSet { defaults.set(relayAutoApproveEdits, forKey: "relayAutoApproveEdits") }
    }
    /// 끄면 검토 의견을 입력창에만 넣고 릴레이를 끝냅니다(검토만 받기). 기본은 자동 수정.
    var relayAutoFix: Bool {
        didSet { defaults.set(relayAutoFix, forKey: "relayAutoFix") }
    }
    /// 제거 확인 창 대상
    var deleteTargetID: String?
    /// 작업 폴더 대화에서 구현 턴이 끝날 때마다 빌드를 돌려, 실패하면 검토자 없이 바로 수정 요청을 보냅니다.
    var relayAutoBuild: Bool {
        didSet { defaults.set(relayAutoBuild, forKey: "relayAutoBuild") }
    }
    private var relayReviewTask: Task<Void, Never>?
    var relayIsActive: Bool { relay?.isActive ?? false }

    // MARK: 빌드 실행 (작업 폴더 모드)
    private let buildRunner = BuildRunner()
    var buildRunning = false
    var lastBuildResult: BuildResult?
    /// 현재 선택한 대화의 작업 폴더에 쓸 빌드 명령 (폴더별로 UserDefaults 에 저장, 비우면 자동 감지)
    var buildCommandDraft = ""
    var buildCommandDetecting = false

    var claudeAuth: ClaudeAuthState = .unknown
    /// rate_limit_event 로 받은 구독 사용량. 달러 비용은 지어내지 않고 창별 사용률만 보여줍니다.
    var claudeUsageSummary = ""
    /// GitHub CLI 연결 상태
    var githubStatus: GitHubStatus = .checking
    /// 이번 API 턴에 인용된 출처
    private var apiTurnSources: [(title: String, url: String)] = []
    /// API 대화에서 웹 검색·웹 페이지 읽기를 쓸지. 끄면 예전처럼 글로만 답합니다.
    var webSearchEnabled: Bool {
        didSet { defaults.set(webSearchEnabled, forKey: "webSearchEnabled") }
    }
    /// 입력창에 포커스가 있는지. Shift+Enter 와 붙여넣기를 입력창에서만 다루는 데 씁니다.
    var composerIsFocused = false
    /// account/rateLimits 로 받은 Codex 구독 사용량. 형식은 Claude 와 같습니다.
    var codexUsageSummary = ""
    /// Claude CLI 가 이번 턴에 마지막으로 보고한 메시지의 컨텍스트 토큰 수
    private var claudeLastContextTokens = 0

    /// 선택한 대화의 사용량
    var selectedUsage: ConversationUsage { selectedConversation?.usage ?? ConversationUsage() }
    /// 선택한 대화의 연결에 해당하는 구독 사용량
    var subscriptionUsageSummary: String {
        switch selectedProvider {
        case .claude: return claudeUsageSummary
        case .codex: return codexUsageSummary
        default: return ""
        }
    }
    /// 입력창 위 사용량 버튼 글자
    var usageChipText: String {
        let usage = selectedUsage
        if let percent = usage.contextPercent { return "컨텍스트 \(percent)%" }
        return "사용량"
    }
    var claudeModelName = ""
    static let claudeLoginCommand = "claude auth login"

    private let client = CodexClient()
    private let claude = ClaudeClient()
    private let store: ConversationStore
    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let apiClient: ClaudeAPIClient
    private let openAIClient: OpenAIAPIClient
    private var apiTask: Task<Void, Never>?
    private var claudeLaunchSignature = ""
    /// 턴마다 바뀌는 꼬리표. 메시지 ID 가 같거나 없어도 다른 턴의 답변과 섞이지 않게 합니다.
    private var claudeTurnTag = ""
    private var readyThreads: Set<String> = []
    private var stopRequested = false
    private var interruptSent = false
    private var persistenceTask: Task<Void, Never>?

    /// 앱에서 시작한 대화에 공통으로 거는 안전장치.
    /// - sandbox read-only: 파일 쓰기 불가
    /// - approvalPolicy untrusted: 안전 목록 밖 명령은 반드시 물어보게 → 앱이 전부 거절
    /// 읽기 전용은 전체 도구 비활성화가 아닙니다. 승인 요청은 취소합니다.
    /// 모든 연결 공통: 파일로 줄 내용은 ```file:이름 블록으로. 앱이 ‘받은 파일’로 저장해 보여줍니다.
    static let fileBlockInstructions =
        "사용자에게 파일로 전달할 텍스트 결과물(코드·문서·데이터)은 ```file:이름.확장자 로 시작하고 ``` 로 끝나는 코드 블록에 넣으세요. " +
        "앱이 그 블록을 파일로 저장해 사용자에게 보여줍니다. 이름에 경로는 넣지 마세요."

    private static let developerInstructions =
        "이 대화는 Condux 실험 앱에서 시작되었습니다. 파일을 수정하거나 명령을 실행할 수 없습니다. " +
        "셸 명령, 파일 편집, 패치 적용을 시도하지 말고 텍스트로만 답하세요. 사용자가 쓴 언어로 답하세요. " + fileBlockInstructions

    private var threadSafetyParams: [String: JSONValue] {
        [
            "approvalPolicy": "untrusted",
            "sandbox": "read-only",
            "developerInstructions": .string(Self.developerInstructions),
            "cwd": .string(store.sandboxDirectory.path),
        ]
    }

    /// 작업 폴더 모드 안내. 경계는 Codex 의 workspace-write 샌드박스와 앱의 승인 카드가 맡습니다.
    private static let workspaceInstructions =
        "이 대화는 Condux 앱의 작업 폴더 모드입니다. 작업 폴더 안의 파일만 다루고, 파일 수정과 명령 실행은 사용자가 앱에서 승인해야 실행됩니다. " +
        "변경 전에 무엇을 왜 바꾸는지 짧게 설명하고, 한 번에 너무 많은 파일을 바꾸지 마세요. 사용자가 쓴 언어로 답하세요. " + fileBlockInstructions

    /// 작업 폴더 모드에서 첨부·받은 파일 폴더를 알려 주는 문장.
    private func fileFolderHint(for conversationID: String) -> String {
        "사용자가 첨부한 파일은 \(attachmentStore.attachmentsDirectory(for: conversationID).path) 에 있습니다. " +
        "텍스트가 아닌 파일 결과물(이미지·문서 등)을 사용자에게 주려면 \(attachmentStore.outputsDirectory(for: conversationID).path) 폴더에 저장하세요. 앱이 사용자에게 보여줍니다."
    }

    private func codexThreadParams(workspace: String) -> [String: JSONValue] {
        guard !workspace.isEmpty else { return threadSafetyParams }
        return [
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
            "developerInstructions": .string(Self.workspaceInstructions),
            "cwd": .string(workspace),
        ]
    }

    private func codexTurnParams(workspace: String, conversationID: String = "") -> [String: JSONValue] {
        guard !workspace.isEmpty else {
            return ["approvalPolicy": "untrusted", "sandboxPolicy": ["type": "readOnly"], "cwd": .string(store.sandboxDirectory.path)]
        }
        var roots: [JSONValue] = [.string(workspace)]
        if !conversationID.isEmpty {
            let outputs = attachmentStore.outputsDirectory(for: conversationID)
            try? FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
            roots.append(.string(outputs.path))
        }
        return ["approvalPolicy": "on-request", "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": .array(roots)], "cwd": .string(workspace)]
    }

    /// 작업 폴더를 고릅니다 (구독판). 새 대화부터 적용됩니다.
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("이 폴더에서 작업")
        panel.message = tr("AI 가 읽고 (승인 후) 고칠 수 있는 프로젝트 폴더를 고르세요. 새 대화부터 적용됩니다.")
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
            notice = "작업 폴더: \(url.path) — 이제 만드는 새 대화는 이 폴더에서 도구를 쓸 수 있습니다(수정·명령은 승인 필요)."
        }
    }

    func clearWorkspace() {
        workspacePath = ""
        notice = "작업 폴더를 해제했습니다. 새 대화는 텍스트 대화로 만들어집니다."
    }

    /// 이미 만든 Claude 대화에 작업 폴더를 붙이거나 뗍니다. 다음 전송 때 `--resume` 으로 도구를 켜고(끄고) 다시 띄웁니다.
    /// Codex 대화는 스레드 시작 때 정한 지시문·샌드박스를 바꿀 수 없어 지원하지 않습니다(새 대화 안내).
    func setConversationWorkspace(_ id: String, path: String?) {
        guard !progress.isBusy else { notice = "답변이 끝난 뒤 바꿀 수 있습니다."; return }
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        guard conversations[index].provider == .claude else {
            notice = "작업 폴더는 Claude 구독 대화에만 나중에 붙일 수 있습니다. Codex 는 작업 폴더를 고른 뒤 새 대화를 만들어 주세요."
            return
        }
        conversations[index].workspacePath = path ?? ""
        conversations[index].updatedAt = Date()
        if claude.sessionID == id { claude.stop() }
        store.save(conversations)
        notice = path == nil ? "이 대화의 작업 폴더를 해제했습니다. 다음 전송부터 텍스트 대화입니다."
                             : "이 대화에 작업 폴더를 연결했습니다: \(path ?? ""). 다음 전송부터 파일을 읽고(승인 후) 고칠 수 있습니다."
    }

    /// 폴더 선택 창을 열어 기존 대화에 붙입니다.
    func chooseWorkspace(forConversation id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("이 대화에 연결")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setConversationWorkspace(id, path: url.path)
    }

    // MARK: 빌드

    private func buildCommandKey(_ workspace: String) -> String { "buildCommand:" + workspace }

    /// 선택한 대화의 작업 폴더에 맞는 빌드 명령을 채웁니다. 저장된 것이 없으면 폴더를 보고 추정합니다(백그라운드).
    func refreshBuildCommand() async {
        guard let conversation = selectedConversation, conversation.hasWorkspace else { buildCommandDraft = ""; return }
        let workspace = conversation.workspacePath
        if let saved = defaults.string(forKey: buildCommandKey(workspace)), !saved.isEmpty {
            buildCommandDraft = saved
            return
        }
        buildCommandDetecting = true
        let detected = await Task.detached(priority: .userInitiated) {
            BuildCommandDetector.detect(in: URL(fileURLWithPath: workspace))
        }.value
        buildCommandDetecting = false
        guard selectedConversation?.workspacePath == workspace else { return }
        buildCommandDraft = detected ?? ""
    }

    func saveBuildCommand() {
        guard let conversation = selectedConversation, conversation.hasWorkspace else { return }
        defaults.set(buildCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines), forKey: buildCommandKey(conversation.workspacePath))
    }

    func runBuild() async {
        guard let conversation = selectedConversation, conversation.hasWorkspace, !buildRunning else { return }
        let command = buildCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { notice = "빌드 명령이 비어 있습니다. 빌드 명령 칸에 입력해 주세요."; return }
        saveBuildCommand()
        buildRunning = true
        lastBuildResult = nil
        let conversationID = conversation.id
        let entryID = "build-" + UUID().uuidString
        entries.append(ChatEntry(id: entryID, kind: .activity, title: "빌드 실행 · \(command)", text: "", status: "실행 중"))
        appendLog("!", "[build] \(command)")
        let result = await buildRunner.run(command: command, in: URL(fileURLWithPath: conversation.workspacePath)) { [weak self] line in
            Task { @MainActor in self?.appendLog("·", "[build] \(line)") }
        }
        buildRunning = false
        lastBuildResult = result
        guard selectedID == conversationID, let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].title = "빌드 결과 · \(result.statusText) · \(String(format: "%.0f초", result.durationSeconds))"
        entries[index].status = result.succeeded ? "성공" : (result.cancelled ? "중단됨" : "실패")
        let errorLines = result.errors.map { "\($0.file):\($0.line):\($0.column): \($0.message)" }
        let warnings = result.issues.filter { $0.severity == "warning" }.count
        if !errorLines.isEmpty {
            entries[index].text = errorLines.joined(separator: "\n") + (warnings > 0 ? "\n(경고 \(warnings)개는 생략)" : "")
        } else {
            let tail = result.outputTail.split(separator: "\n").suffix(40).joined(separator: "\n")
            entries[index].text = tail
        }
        progress.phase = "빌드 \(result.statusText)"
        persist()
    }

    func cancelBuild() {
        buildRunner.cancel()
    }

    /// 마지막 빌드 오류를 입력창에 채웁니다. 전송은 사용자가 합니다.
    func insertBuildErrorsIntoDraft() {
        guard let result = lastBuildResult else { return }
        var lines = [tr("빌드가 실패했습니다. 아래 오류를 고쳐 주세요. 고치기 전에 무엇을 바꿀지 한 줄로 설명하고, 수정은 승인을 받으세요.")]
        if !result.errors.isEmpty {
            lines.append("")
            lines.append(contentsOf: result.errors.prefix(30).map { "- \($0.file):\($0.line):\($0.column): \($0.message)" })
            if result.errors.count > 30 { lines.append("… 외 \(result.errors.count - 30)개") }
        } else {
            lines.append("")
            lines.append(tr("출력 마지막 부분:"))
            lines.append("```")
            lines.append(result.outputTail.split(separator: "\n").suffix(40).joined(separator: "\n"))
            lines.append("```")
        }
        lines.append("")
        lines.append(tr("(빌드 명령: \(result.command))"))
        draft = lines.joined(separator: "\n")
    }

    /// Claude 대화에 붙이는 안내. 도구는 플래그로 이미 모두 뺐으므로 강제 경계가 아니라 말투 안내입니다.
    private static let claudeInstructions =
        "이 대화는 Condux 실험 앱에서 시작되었습니다. 파일·셸 도구가 없는 텍스트 전용 대화이므로 " +
        "코드 수정이나 명령 실행을 시도하지 말고 텍스트로만 답하세요. 사용자가 쓴 언어로 답하세요. " + fileBlockInstructions

    /// - Parameter store: 테스트에서는 임시 폴더의 저장소를 넣어 실제 기록을 건드리지 않습니다.
    /// - Parameter defaults: 설정 저장소. 테스트는 별도 suite 를 넘겨 실제 설정을 건드리지 않습니다.
    /// - Parameters:
    ///   - secrets: API 키 저장소. 기본은 이 앱 전용 키체인 항목. 테스트는 메모리 저장소.
    ///   - apiTransport: Claude API HTTP 전송. 테스트는 가짜 전송으로 바꿔 네트워크 없이 검사합니다.
    init(store: ConversationStore = ConversationStore(), defaults: UserDefaults = .standard,
         secrets: SecretStore = KeychainSecretStore(), apiTransport: ClaudeAPITransport = URLSessionTransport(),
         localClient: LocalLLMGenerating = MLXLocalLLMClient()) {
        self.store = store
        self.localClient = localClient
        self.localModelStore = LocalModelStore(root: store.directory.appendingPathComponent("Models", isDirectory: true))
        attachmentStore = AttachmentStore(root: store.directory)
        mcpServers = MCPServerList.load(from: defaults)
        autoApproveEdits = defaults.bool(forKey: "autoApproveEdits")
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        webSearchEnabled = defaults.object(forKey: "webSearchEnabled") as? Bool ?? true
        appAppearance = AppAppearance(rawValue: defaults.string(forKey: AppAppearance.defaultsKey) ?? "") ?? .dark
        self.defaults = defaults
        self.secrets = secrets
        self.apiClient = ClaudeAPIClient(transport: apiTransport)
        self.openAIClient = OpenAIAPIClient(transport: apiTransport)
        openAIAPIModel = defaults.string(forKey: "openAIAPIModel") ?? "gpt-6.1-sol"
        openAIAPIEffort = defaults.string(forKey: "openAIAPIEffort") ?? ""
        openAIAPIKeyPresent = !(secrets.read(Self.openAIAPIKeyName) ?? "").isEmpty
        workspacePath = Self.isAppStoreBuild ? "" : (defaults.string(forKey: "workspacePath") ?? "")
        relayReviewer = Provider(rawValue: defaults.string(forKey: "relayReviewer") ?? "") ?? .openAIAPI
        relayMaxRounds = defaults.object(forKey: "relayMaxRounds") as? Int ?? 3
        relayAutoApproveEdits = defaults.bool(forKey: "relayAutoApproveEdits")
        relayAutoBuild = defaults.object(forKey: "relayAutoBuild") as? Bool ?? true
        relayAutoFix = defaults.object(forKey: "relayAutoFix") as? Bool ?? true
        client.approvalsEnabled = true
        claudeAPIModel = defaults.string(forKey: "claudeAPIModel") ?? "claude-opus-5-5"
        claudeAPIEffort = defaults.string(forKey: "claudeAPIEffort") ?? ""
        claudeAPIDefaultBudgetUSD = defaults.object(forKey: "claudeAPIDefaultBudgetUSD") as? Double ?? 1.0
        claudeAPIKeyPresent = !(secrets.read(Self.claudeAPIKeyName) ?? "").isEmpty
        codexPathOverride = defaults.string(forKey: "codexPathOverride") ?? ""
        claudePathOverride = defaults.string(forKey: "claudePathOverride") ?? ""
        claudeModel = defaults.string(forKey: "claudeModel") ?? ""
        claudeEffort = defaults.string(forKey: "claudeEffort") ?? ""
        localModelReady = localModelStore.isReady()
        if localModelReady { localModelStatus = "모델 준비됨 · 다운로드 후에는 인터넷 없이 대화할 수 있습니다." }
        localModelHasPartial = !localModelReady && localModelStore.hasPartial
        if localModelHasPartial { localModelStatus = "받다 만 파일이 있습니다. 누르면 받은 곳부터 이어받습니다." }
        conversations = store.load()
        notice = store.loadWarning
        selectedID = conversations.first?.id
        if let id = selectedID { loadCached(id) }
        client.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        claude.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handleClaude(event) }
        }
    }

    var selectedConversation: StoredConversation? {
        conversations.first { $0.id == selectedID }
    }

    var selectedProvider: Provider { selectedConversation?.provider ?? .codex }

    /// 선택한 대화의 연결로 보낼 수 있는 상태인지.
    var canSend: Bool {
        guard let conversation = selectedConversation else { return false }
        switch conversation.provider {
        case .codex: return connection.isConnected
        case .claude: return claudeAuth.isLoggedIn
        case .claudeAPI: return claudeAPIKeyPresent && conversation.apiRemainingUSD > 0
        case .openAIAPI: return openAIAPIKeyPresent && conversation.apiRemainingUSD > 0
        case .localLLM: return localLLMAvailable && localModelReady && !localModelDownloading
        }
    }

    /// 직접 API 연결 중 하나라도 키가 있으면 true (Store 빌드 첫 화면 안내에 사용)
    var anyAPIKeyPresent: Bool { claudeAPIKeyPresent || openAIAPIKeyPresent }

    /// ‘새 대화’ 기본 연결. 구독 연결이 살아 있으면 그것을, 아니면 키가 있는 API 연결을 씁니다.
    /// 사용자가 고른 ‘새 대화’ 기본 연결. 비어 있으면 연결 상태로 자동 결정.
    var preferredNewConversationProvider: Provider? {
        get { Provider(rawValue: defaults.string(forKey: "preferredNewConversationProvider") ?? "") }
        set { defaults.set(newValue?.rawValue ?? "", forKey: "preferredNewConversationProvider") }
    }

    /// 연결이 준비된 것만 기본으로 삼습니다.
    private func isReady(_ provider: Provider) -> Bool {
        switch provider {
        case .codex: return !Self.isAppStoreBuild && connection.isConnected
        case .claude: return !Self.isAppStoreBuild && claudeAuth.isLoggedIn
        case .claudeAPI: return claudeAPIKeyPresent
        case .openAIAPI: return openAIAPIKeyPresent
        case .localLLM: return localLLMAvailable && localModelReady && !localModelDownloading
        }
    }

    var defaultNewConversationProvider: Provider {
        // 로컬을 명시적으로 고른 경우 준비 실패를 유료 연결로 바꾸지 않습니다.
        if preferredNewConversationProvider == .localLLM { return .localLLM }
        if let preferred = preferredNewConversationProvider, isReady(preferred) { return preferred }
        if !Self.isAppStoreBuild {
            if connection.isConnected { return .codex }
            if claudeAuth.isLoggedIn { return .claude }
        }
        if claudeAPIKeyPresent { return .claudeAPI }
        if openAIAPIKeyPresent { return .openAIAPI }
        if isReady(.localLLM) { return .localLLM }
        return Self.isAppStoreBuild ? .claudeAPI : .codex
    }

    var canStartAnyConversation: Bool {
        (!Self.isAppStoreBuild && (connection.isConnected || claudeAuth.isLoggedIn)) || anyAPIKeyPresent || isReady(.localLLM)
    }

    /// API 대화의 비용 표시. 추정치임을 항상 함께 보여줍니다.
    var apiCostSummary: String {
        guard let conversation = selectedConversation else { return "" }
        // 구독(CLI) 대화라도 릴레이 검토자(API) 비용이 생기면 보여줍니다.
        guard conversation.provider.isDirectAPI || conversation.apiSpentUSD > 0 else { return "" }
        let label = conversation.provider.isDirectAPI ? "예상 비용" : "검토 비용(API)"
        return String(format: "%@ $%.4f / 예산 $%.2f", label, conversation.apiSpentUSD, conversation.apiBudgetUSD)
    }

    var apiBudgetExhausted: Bool {
        guard let conversation = selectedConversation, conversation.provider.isDirectAPI else { return false }
        return conversation.apiRemainingUSD <= 0
    }

    // MARK: Claude API 키 (사용자가 직접 입력)

    /// - Parameter key: 비우면 설정 창의 입력값(claudeAPIKeyDraft)을 씁니다.
    func saveClaudeAPIKey(_ key: String = "") {
        let source = key.isEmpty ? claudeAPIKeyDraft : key
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            claudeAPIKeyStatus = "API 키가 비어 있습니다."
            return
        }
        do {
            try secrets.write(Self.claudeAPIKeyName, value: trimmed)
            claudeAPIKeyPresent = true
            claudeAPIKeyDraft = ""
            claudeAPIKeyStatus = "저장됨 · 이 앱 전용 키체인 항목에 보관"
            notice = "Claude API 키를 저장했습니다. ‘새 대화’로 바로 시작할 수 있습니다."
        } catch {
            claudeAPIKeyStatus = "저장 실패: \(APIDiagnostics.redacted(error.localizedDescription, apiKey: trimmed))"
            notice = claudeAPIKeyStatus
        }
    }

    /// 설정 창을 어떤 버튼으로 닫든, 입력해 둔 키가 있으면 저장합니다 (Claude·OpenAI 둘 다).
    func commitPendingAPIKey() {
        if !claudeAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saveClaudeAPIKey() }
        if !openAIAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saveOpenAIAPIKey() }
    }

    func saveOpenAIAPIKey(_ key: String = "") {
        let source = key.isEmpty ? openAIAPIKeyDraft : key
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { openAIAPIKeyStatus = "API 키가 비어 있습니다."; return }
        do {
            try secrets.write(Self.openAIAPIKeyName, value: trimmed)
            openAIAPIKeyPresent = true
            openAIAPIKeyDraft = ""
            openAIAPIKeyStatus = "저장됨 · 이 앱 전용 키체인 항목에 보관"
            notice = "OpenAI API 키를 저장했습니다. ‘새 대화 ▸ OpenAI API’로 시작할 수 있습니다."
        } catch {
            openAIAPIKeyStatus = "저장 실패: \(APIDiagnostics.redacted(error.localizedDescription, apiKey: trimmed))"
            notice = openAIAPIKeyStatus
        }
    }

    func clearOpenAIAPIKey() {
        secrets.delete(Self.openAIAPIKeyName)
        openAIAPIKeyPresent = false
        openAIAPIKeyStatus = "키를 지웠습니다."
        notice = "OpenAI API 키를 지웠습니다."
    }

    func clearClaudeAPIKey() {
        secrets.delete(Self.claudeAPIKeyName)
        claudeAPIKeyPresent = false
        claudeAPIKeyStatus = "키를 지웠습니다."
        notice = "Claude API 키를 지웠습니다."
    }

    /// 선택한 API 대화의 작업 예산을 올립니다. 자동으로 올리지 않고 사용자가 눌러야 합니다.
    func raiseAPIBudget(by amount: Double = 1.0) {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }),
              conversations[index].provider.isDirectAPI else { return }
        conversations[index].apiBudgetUSD += amount
        notice = String(format: "이 대화 예산을 $%.2f 로 올렸습니다.", conversations[index].apiBudgetUSD)
        persist()
    }

    /// 앱스토어(샌드박스) 빌드인지. 이 빌드는 외부 CLI 를 실행할 수 없어 Claude API 연결만 제공합니다.
    static var isAppStoreBuild: Bool {
        #if CONDUX_APPSTORE
        return true
        #else
        return false
        #endif
    }

    /// 앱 시작: Codex 연결과 Claude 로그인 상태 확인을 함께 합니다. 앱스토어 빌드는 둘 다 건너뜁니다.
    func startUp() async {
        guard !Self.isAppStoreBuild else {
            connection = .failed("앱스토어 버전은 외부 CLI 를 실행하지 않습니다")
            claudeAuth = .unavailable("앱스토어 버전은 Claude API 키 연결만 지원합니다")
            return
        }
        Task { await refreshClaudeAuth() }
        Task { await refreshGitHubStatus() }
        await connect()
        // connect() 가 안내 띠를 비우므로, 기록을 못 읽었다는 안내는 다시 보여줍니다.
        if let warning = store.loadWarning { notice = warning }
    }

    var currentTurnEntries: [ChatEntry] {
        guard let start = turnStartIndex, start <= entries.count else { return [] }
        return Array(entries[start...])
    }

    // MARK: 연결

    func connect() async {
        guard connection != .starting, !progress.isBusy else { return }
        connection = .starting
        readyThreads.removeAll()
        notice = nil
        do {
            try client.start(executableOverride: codexPathOverride, extraArguments: MCPServerList.codexOverrides(enabledMCPServers))
            let result = try await client.request("initialize", params: [
                "clientInfo": ["name": "vibestudio", "title": "Condux", "version": "0.1.0"],
            ], timeout: 20)
            client.notify("initialized")
            connection = .connected(result["userAgent"]?.stringValue ?? "codex app-server")
            await refreshAccount()
            await refreshCodexMCPStatus()
            if let id = selectedID { await prepareThread(id) }
        } catch {
            connection = .failed(error.localizedDescription)
            client.stop()
        }
    }

    func disconnect() {
        client.stop()
        connection = .disconnected
        readyThreads.removeAll()
        if progress.isBusy { progress.state = .failed; progress.phase = "연결 끊김" }
    }

    /// Codex 구독 사용량을 "구독 사용량 5시간 창 12% · 7일 창 62%" 로 바꿉니다. 달러 비용은 만들지 않습니다.
    private func applyCodexRateLimits(_ limits: JSONValue?) {
        func window(_ value: JSONValue?) -> String? {
            guard let used = value?["usedPercent"]?.intValue else { return nil }
            let minutes = value?["windowDurationMins"]?.intValue ?? 0
            let name: String
            if minutes >= 1440, minutes % 1440 == 0 { name = "\(minutes / 1440)일 창" }
            else if minutes >= 60, minutes % 60 == 0 { name = "\(minutes / 60)시간 창" }
            else { name = "사용 창" }
            return "\(name) \(used)%"
        }
        let parts = [window(limits?["primary"]), window(limits?["secondary"])].compactMap { $0 }
        codexUsageSummary = parts.isEmpty ? "" : "구독 사용량 " + parts.joined(separator: " · ")
    }

    private func refreshCodexRateLimits() async {
        guard let result = try? await client.request("account/rateLimits/read", params: [:], timeout: 20) else { return }
        applyCodexRateLimits(result["rateLimits"])
    }

    func refreshAccount() async {
        do {
            let result = try await client.request("account/read", params: [:], timeout: 20)
            if let account = result["account"], !account.isNull {
                isLoggedIn = true
                switch account["type"]?.stringValue {
                case "chatgpt":
                    Task { await refreshCodexRateLimits() }
                    let email = account["email"]?.stringValue ?? ""
                    let plan = account["planType"]?.stringValue ?? ""
                    accountSummary = "ChatGPT 로그인됨 \(email) \(plan)".trimmingCharacters(in: .whitespaces)
                case "apiKey": accountSummary = "API 키로 인증됨"
                default: accountSummary = "인증됨 (\(account["type"]?.stringValue ?? "?"))"
                }
            } else if result["requiresOpenaiAuth"]?.boolValue == false {
                isLoggedIn = true
                accountSummary = "별도 인증 불필요"
            } else {
                isLoggedIn = false
                accountSummary = "로그인 필요"
            }
        } catch {
            isLoggedIn = false
            accountSummary = "계정 확인 실패: \(error.localizedDescription)"
        }
    }

    /// Codex 공식 로그인 절차를 시작합니다. 브라우저 주소만 받아서 열고, 토큰은 Codex 가 직접 저장합니다.
    func startLogin() async {
        do {
            let result = try await client.request("account/login/start", params: ["type": "chatgpt"], timeout: 20)
            if let urlText = result["authUrl"]?.stringValue, let url = URL(string: urlText) {
                NSWorkspace.shared.open(url)
                notice = "브라우저에서 로그인을 마치면 상태가 자동으로 갱신됩니다."
            } else {
                notice = "로그인 주소를 받지 못했습니다. 터미널에서 `codex login` 을 실행해 주세요."
            }
        } catch {
            notice = "로그인 시작 실패: \(error.localizedDescription) — 터미널에서 `codex login` 을 실행해 주세요."
        }
    }

    // MARK: Claude 로그인 상태 (읽기 전용)

    func refreshClaudeAuth() async {
        claudeAuth = .checking
        do {
            claudeAuth = .status(try await ClaudeClient.authStatus(executableOverride: claudePathOverride))
        } catch ClaudeError.processExited(let code, let detail) where code == 127 || detail.contains("No such file") {
            claudeAuth = .unavailable("Claude Code CLI 를 찾지 못했습니다. 설치 후 설정에서 경로를 지정해 주세요.")
        } catch {
            claudeAuth = .unavailable("Claude 상태 확인 실패: \(error.localizedDescription)")
        }
    }

    /// 로그인은 Anthropic 자체 절차로만 합니다. 앱은 명령을 복사해 주고 사용자가 터미널에서 실행합니다.
    func copyClaudeLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.claudeLoginCommand, forType: .string)
        notice = "`\(Self.claudeLoginCommand)` 을 복사했습니다. 터미널에 붙여 넣어 실행하고 브라우저에서 로그인한 뒤 ‘다시 확인’을 눌러 주세요."
    }

    // MARK: 대화 관리

    func newConversation(provider: Provider = .codex) async {
        switch provider {
        case .codex: await newCodexConversation()
        case .claude: newClaudeConversation()
        case .claudeAPI: newDirectAPIConversation(.claudeAPI)
        case .openAIAPI: newDirectAPIConversation(.openAIAPI)
        case .localLLM:
            guard !progress.isBusy else { return }
            guard isReady(.localLLM), localModelStore.isReady() else {
                notice = localLLMAvailable ? LocalLLMError.modelMissing.localizedDescription : LocalLLMError.unavailable.localizedDescription
                return
            }
            let now = Date()
            let id = "local-" + UUID().uuidString.lowercased()
            conversations.insert(StoredConversation(id: id, provider: .localLLM, title: "새 대화", createdAt: now,
                                                    updatedAt: now, messages: []), at: 0)
            selectedID = id
            entries = []
            resetTurn()
            notice = nil
            persist()
        }
    }

    private func newDirectAPIConversation(_ provider: Provider) {
        guard !progress.isBusy else { notice = "현재 답변이 끝난 뒤 새 대화를 만들 수 있습니다."; return }
        let hasKey = provider == .openAIAPI ? openAIAPIKeyPresent : claudeAPIKeyPresent
        guard hasKey else { notice = "설정에서 \(provider.displayName) 키를 먼저 저장해 주세요."; return }
        let now = Date()
        let id = (provider == .openAIAPI ? "oai-" : "api-") + UUID().uuidString.lowercased()
        conversations.insert(StoredConversation(id: id, provider: provider, title: "새 대화", createdAt: now, updatedAt: now,
                                                messages: [], apiBudgetUSD: claudeAPIDefaultBudgetUSD), at: 0)
        selectedID = id
        entries = []
        resetTurn()
        notice = nil
        persist()
    }

    func refreshGitHubStatus() async {
        guard !AppModel.isAppStoreBuild else { return }
        githubStatus = .checking
        githubStatus = await GitHubStatus.check()
    }

    /// 로그인은 GitHub 자체 절차로만 합니다. 앱은 명령을 복사해 주고 사용자가 터미널에서 실행합니다.
    func copyGitHubSetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(githubStatus == .missing ? "brew install gh && gh auth login --web" : "gh auth login --web", forType: .string)
        notice = "GitHub 명령을 복사했습니다. 터미널에 붙여넣어 실행한 뒤 ‘다시 확인’을 눌러 주세요."
    }

    /// 다른 프로그램을 부리는 대화. 전용 폴더에서 Claude 의 기본 도구를 켭니다.
    /// 명령은 언제나 승인 카드를 거치고, 파일 수정 자동 허용도 이 폴더 안으로 한정됩니다.
    func startMacControlConversation() {
        guard !AppModel.isAppStoreBuild else { return }
        guard claudeAuth.isLoggedIn else {
            notice = "다른 프로그램 제어는 Claude 구독 로그인이 필요합니다. ‘연결 관리’의 ‘로그인 명령 복사’를 이용해 주세요."
            return
        }
        let folder = store.directory.appendingPathComponent("mac-control", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            notice = "제어용 폴더를 만들지 못했습니다: \(error.localizedDescription)"
            return
        }
        let previous = workspacePath
        workspacePath = folder.path
        newClaudeConversation()
        workspacePath = previous // 다음 새 대화까지 이 폴더가 따라가지 않게 합니다.
        guard selectedConversation?.workspacePath == folder.path else { return }
        notice = "이 대화에서 AI 는 명령으로 다른 앱을 열고 조작합니다. 명령마다 승인 카드가 뜹니다."
    }

    private func newClaudeConversation() {
        guard !progress.isBusy else { notice = "현재 답변이 끝난 뒤 새 대화를 만들 수 있습니다."; return }
        guard claudeAuth.isLoggedIn else { notice = "Claude 에 로그인되어 있지 않습니다. ‘연결 관리’의 ‘로그인 명령 복사’로 터미널에서 로그인해 주세요."; return }
        let now = Date()
        let id = UUID().uuidString.lowercased()
        claude.stop()
        conversations.insert(StoredConversation(id: id, provider: .claude, title: "새 대화", createdAt: now, updatedAt: now, messages: [],
                                                workspacePath: workspacePath), at: 0)
        selectedID = id
        entries = []
        resetTurn()
        notice = nil
        persist()
    }

    private func newCodexConversation() async {
        guard connection.isConnected, !progress.isBusy else { notice = "연결과 현재 답변이 끝난 뒤 새 대화를 만들 수 있습니다."; return }
        do {
            let workspace = workspacePath
            let result = try await client.request("thread/start", params: .object(codexThreadParams(workspace: workspace)), timeout: 30)
            guard let id = result["thread"]?["id"]?.stringValue else {
                throw CodexError.malformed("thread/start 응답에 thread.id 가 없습니다")
            }
            let now = Date()
            conversations.insert(StoredConversation(id: id, title: "새 대화", createdAt: now, updatedAt: now, messages: [],
                                                    workspacePath: workspace), at: 0)
            readyThreads.insert(id)
            selectedID = id
            entries = []
            resetTurn()
            persist()
        } catch {
            notice = "새 대화를 만들지 못했습니다: \(error.localizedDescription)"
        }
    }

    func select(_ id: String?) {
        guard id != selectedID, !progress.isBusy else { return }
        selectedID = id
        resetTurn()
        notice = nil
        guard let id else { entries = []; return }
        loadCached(id)
        // Claude 프로세스는 세션 하나를 담당하므로 다른 대화로 가면 내려 둡니다. 다음 전송 때 --resume 으로 다시 띄웁니다.
        if claude.isRunning, claude.sessionID != id { claude.stop() }
        if selectedProvider == .codex { Task { await prepareThread(id) } }
    }

    /// 제거 확인 창을 띄웁니다. 실제 제거는 `deleteConversation`.
    func confirmDelete(_ id: String) {
        guard !progress.isBusy else { notice = "답변이 끝난 뒤 제거할 수 있습니다."; return }
        deleteTargetID = id
    }

    /// 사이드바 n번째(필터 적용) 대화로 이동 (⌘1~⌘9)
    func selectConversation(at index: Int) {
        let list = filteredConversations
        guard list.indices.contains(index) else { return }
        select(list[index].id)
    }

    func deleteConversation(_ id: String) {
        guard !progress.isBusy else { return }
        if claude.sessionID == id { claude.stop() }
        conversations.removeAll { $0.id == id }
        readyThreads.remove(id)
        if selectedID == id { selectedID = conversations.first?.id; entries = []; resetTurn(); if let s = selectedID { loadCached(s) } }
        persist()
    }

    /// 서버 쪽 대화를 다시 열어(thread/resume) 전체 기록을 받아옵니다. 실패하면 로컬 저장본을 그대로 둡니다.
    func prepareThread(_ id: String) async {
        guard conversations.first(where: { $0.id == id })?.provider != .localLLM else { return }
        guard connection.isConnected, !readyThreads.contains(id) else { return }
        do {
            let workspace = conversations.first { $0.id == id }?.workspacePath ?? ""
            let params = JSONValue.object(codexThreadParams(workspace: workspace)).merging(["threadId": .string(id)])
            let result = try await client.request("thread/resume", params: params, timeout: 60)
            readyThreads.insert(id)
            guard selectedID == id else { return }
            if let turns = result["thread"]?["turns"]?.arrayValue, !turns.isEmpty {
                entries = Self.entries(fromTurns: turns)
                progress.phase = "서버 기록으로 복원됨 (턴 \(turns.count)개)" // 성공은 띠로 띄우지 않고 조용히 표시
                persist()
            } else {
                notice = "서버가 기록을 돌려주지 않아 로컬 저장본을 표시합니다."
            }
        } catch {
            // 턴이 한 번도 없던 대화는 Codex 가 디스크에 저장하지 않아, 앱(또는 app-server)을 다시 띄우면 resume 이 실패합니다.
            // 그 경우 새 스레드를 만들어 같은 대화에 다시 연결합니다(화면 항목과 작업 폴더는 그대로).
            if let index = conversations.firstIndex(where: { $0.id == id }),
               !conversations[index].messages.contains(where: { $0.role == .user || $0.role == .assistant }),
               await rekeyEmptyThread(at: index) {
                return
            }
            notice = "대화 복원 실패: \(error.localizedDescription) — 로컬 저장본을 표시합니다."
        }
    }

    /// 빈 대화를 새 thread/start 로 다시 열고 대화 ID(=thread id)를 바꿉니다. 성공하면 true.
    private func rekeyEmptyThread(at index: Int) async -> Bool {
        let oldID = conversations[index].id
        let workspace = conversations[index].workspacePath
        guard let result = try? await client.request("thread/start", params: .object(codexThreadParams(workspace: workspace)), timeout: 30),
              let newID = result["thread"]?["id"]?.stringValue else { return false }
        conversations[index].id = newID
        conversations[index].updatedAt = Date()
        readyThreads.remove(oldID)
        readyThreads.insert(newID)
        if selectedID == oldID { selectedID = newID }
        if relay?.conversationID == oldID { relay?.conversationID = newID }
        progress.phase = "빈 대화를 새 Codex 스레드로 다시 열었습니다"
        persist()
        return true
    }

    // MARK: 메시지 보내기 / 중단

    func send() async {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty, !progress.isBusy else { return }
        guard let conversation = selectedConversation else { notice = "먼저 대화를 만들어 주세요."; return }
        if text.isEmpty { text = tr("첨부한 파일을 확인해 주세요.") }
        if Self.isAppStoreBuild, !conversation.provider.isDirectAPI {
            notice = "앱스토어 버전에서는 Codex/Claude 구독 대화를 이어갈 수 없습니다. 읽기만 가능하고, 새 대화는 API 키 연결로 시작해 주세요."
            return
        }
        switch conversation.provider {
        case .codex: await sendToCodex(conversation.id, text: text)
        case .claude: await sendToClaude(conversation, text: text)
        case .claudeAPI: sendToClaudeAPI(conversation, text: text)
        case .openAIAPI: sendToOpenAIAPI(conversation, text: text)
        case .localLLM: sendToLocalLLM(conversation, text: text)
        }
    }

    private func sendToLocalLLM(_ conversation: StoredConversation, text: String) {
        guard localLLMAvailable else { notice = LocalLLMError.unavailable.localizedDescription; return }
        guard !localModelDownloading, localModelStore.isReady() else {
            localModelReady = false
            notice = LocalLLMError.modelMissing.localizedDescription
            return
        }
        guard pendingAttachments.isEmpty else {
            notice = "시험용 로컬 AI는 글로만 대화합니다. 첨부 파일을 제거한 뒤 보내 주세요."
            return
        }
        let history = entries.compactMap { entry -> LocalLLMMessage? in
            guard entry.kind == .user || entry.kind == .assistant else { return nil }
            return LocalLLMMessage(role: entry.kind == .user ? .user : .assistant, text: entry.text)
        }
        guard history.reduce(text.count, { $0 + $1.text.count }) <= 8_000 else {
            notice = LocalLLMError.contextTooLong.localizedDescription
            return
        }
        let id = conversation.id
        beginTurn(id, text: text)
        let tag = UUID().uuidString
        claudeTurnTag = tag
        progress.state = .running
        progress.phase = "이 Mac에서 모델을 불러오는 중"
        localTask = Task { [weak self] in
            guard let self else { return }
            var failure: Error?
            do {
                try await self.localClient.stream(directory: self.localModelStore.directory, history: history, prompt: text) { [weak self] delta in
                    guard let self, self.claudeTurnTag == tag, !Task.isCancelled else { return }
                    self.upsert(id: "\(tag)-text", kind: .assistant) { $0.text += delta; $0.isStreaming = true }
                    self.progress.phase = "이 Mac에서 답변 작성 중"
                    self.schedulePersistence()
                }
                try Task.checkCancellation()
            } catch { failure = error }
            guard self.claudeTurnTag == tag else { return }
            self.localTask = nil
            for index in self.entries.indices { self.entries[index].isStreaming = false }
            if failure is CancellationError || self.stopRequested {
                self.progress.state = .interrupted
                self.progress.phase = "중단됨"
            } else if let failure {
                self.progress.state = .failed
                self.progress.phase = "로컬 AI 실패"
                self.entries.append(ChatEntry(id: UUID().uuidString, kind: .error,
                    text: (failure as? LocalLLMError)?.localizedDescription ?? "로컬 AI가 답변을 만들지 못했습니다. 모델을 다시 다운로드하거나 새 대화에서 짧게 질문해 주세요."))
            } else {
                self.progress.state = .completed
                self.progress.phase = "완료 · 긴 답변은 출력 상한에서 잘릴 수 있습니다"
            }
            self.tokenSummary = "이 Mac에서 처리 · API 사용료 없음"
            self.stopRequested = false
            self.interruptSent = false
            self.persist()
            self.turnDidFinish(conversationID: id)
        }
    }

    /// OpenAI 대화에 붙이는 지시문(Responses API `instructions`).
    private static let openAIAPIInstructions =
        "당신은 Condux 앱 안의 대화 상대입니다. 도구 없이 텍스트로만 답합니다. 사용자가 쓴 언어로 답하세요. " + fileBlockInstructions

    private func sendToOpenAIAPI(_ conversation: StoredConversation, text: String) {
        guard openAIAPIKeyPresent, let apiKey = secrets.read(Self.openAIAPIKeyName), !apiKey.isEmpty else {
            notice = "설정에서 OpenAI API 키를 먼저 저장해 주세요."; return
        }
        let id = conversation.id
        guard conversation.apiRemainingUSD > 0 else {
            notice = String(format: "이 대화의 작업 예산 $%.2f 를 다 썼습니다(추정 $%.4f). 아래 ‘예산 +$1’을 누르거나 새 대화를 시작하세요.",
                            conversation.apiBudgetUSD, conversation.apiSpentUSD)
            return
        }
        guard !progress.isBusy, selectedID == id else { return }
        beginTurn(id, text: text)
        let tag = String(UUID().uuidString.prefix(8))
        claudeTurnTag = tag

        let pricing = OpenAIPricing.forModel(openAIAPIModel)
        let affordable = Int(conversation.apiRemainingUSD / pricing.output * 1_000_000)
        let maxTokens = min(32_000, max(1_024, affordable))
        let userItem: JSONValue = ["role": "user",
                                   "content": .array([["type": "input_text", "text": .string(text)]] + turnAttachments.map(AttachmentEncoder.placeholder))]
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].apiTranscript.append(userItem)
        }
        var request = OpenAIAPIRequest(model: openAIAPIModel, instructions: webInstructions(Self.openAIAPIInstructions),
                                       input: AttachmentEncoder.expandOpenAI(conversations.first { $0.id == id }?.apiTranscript ?? [userItem]),
                                       maxOutputTokens: maxTokens, effort: openAIAPIEffort)
        if webSearchEnabled { request.tools = OpenAIAPIRequest.webTools }
        apiTurnSources = []
        progress.state = .running
        progress.phase = "API 요청 중 (\(openAIAPIModel))"
        if !pricing.known { notice = "이 모델의 요율을 몰라 가장 비싼 요율로 비용을 추정합니다." }

        apiTask = Task { [weak self] in
            guard let self else { return }
            var assembler = ClaudeAPIBlockAssembler()
            var usage = ClaudeAPIUsage()
            var stopReason = ""
            var stopDetails: JSONValue?
            var served = self.openAIAPIModel
            var failure: Error?
            var current = request
            while true {
            failure = nil
            let sending = current
            do {
                try await self.openAIClient.stream(sending, apiKey: apiKey) { [weak self] event in
                    guard let self, self.claudeTurnTag == tag else { return }
                    assembler.apply(event)
                    switch event {
                    case .started(let model, _):
                        served = model
                        self.openAIAPIServedModel = model
                        self.progress.phase = "답변 시작 (\(model))"
                    case .textDelta(_, let delta):
                        self.upsert(id: "\(tag)-text", kind: .assistant) { $0.text += delta; $0.isStreaming = true }
                        self.progress.phase = "답변 작성 중"
                    case .thinkingDelta(_, let delta):
                        self.upsert(id: "\(tag)-thinking", kind: .activity, title: "생각 정리 중") { $0.text += delta; $0.status = "진행 중" }
                        self.progress.phase = "생각 정리 중"
                    case .usage(let latest):
                        usage = latest
                    case .finished(let reason, let details):
                        stopReason = reason
                        stopDetails = details
                    case .webActivity(let key, let name, let detail):
                        self.showWebActivity(tag: tag, key: key, name: name, detail: detail)
                    case .source(let title, let url):
                        self.apiTurnSources.append((title, url))
                    case .log(let line):
                        self.appendLog("·", "[openai] " + APIDiagnostics.redacted(line, apiKey: apiKey))
                    default:
                        break
                    }
                    self.schedulePersistence()
                }
            } catch is CancellationError {
                failure = ClaudeAPIError.cancelled
            } catch let error as URLError where error.code == .cancelled {
                failure = ClaudeAPIError.cancelled
            } catch {
                failure = error
            }
            if !current.tools.isEmpty, Self.webToolsRejected(failure) {
                current.tools = []
                current.instructions = Self.openAIAPIInstructions
                self.notice = "이 API 계정이나 모델에서 웹 검색을 쓸 수 없어 웹 검색 없이 답합니다."
                continue
            }
            break
            }
            self.finishAPITurn(id: id, tag: tag, provider: .openAIAPI, assembler: assembler, usage: usage, served: served,
                               stopReason: stopReason, stopDetails: stopDetails, failure: failure, apiKey: apiKey)
        }
    }

    /// Claude API 대화에 붙이는 시스템 프롬프트.
    private static let claudeAPIInstructions =
        "당신은 Condux 앱 안의 대화 상대입니다. 도구 없이 텍스트로만 답합니다. 사용자가 쓴 언어로 답하세요. " + fileBlockInstructions

    private func sendToClaudeAPI(_ conversation: StoredConversation, text: String) {
        guard claudeAPIKeyPresent, let apiKey = secrets.read(Self.claudeAPIKeyName), !apiKey.isEmpty else {
            notice = "설정에서 Claude API 키를 먼저 저장해 주세요."; return
        }
        let id = conversation.id
        guard conversation.apiRemainingUSD > 0 else {
            notice = String(format: "이 대화의 작업 예산 $%.2f 를 다 썼습니다(추정 $%.4f). 아래 ‘예산 +$1’을 누르거나 새 대화를 시작하세요.",
                            conversation.apiBudgetUSD, conversation.apiSpentUSD)
            return
        }
        guard !progress.isBusy, selectedID == id else { return }
        beginTurn(id, text: text)
        let tag = String(UUID().uuidString.prefix(8))
        claudeTurnTag = tag

        let pricing = ClaudePricing.forModel(claudeAPIModel)
        // 남은 예산 안에서 출력 토큰 상한을 정합니다 (1,024 ~ 32,000). 입력 비용은 결과로 합산합니다.
        let affordable = Int(conversation.apiRemainingUSD / pricing.output * 1_000_000)
        let maxTokens = min(32_000, max(1_024, affordable))
        // 첨부는 전사본에 자리표시자로만 두고(기록 파일이 커지지 않게), 보낼 때 실제 블록으로 바꿉니다.
        let userMessage: JSONValue = ["role": "user",
                                      "content": .array([["type": "text", "text": .string(text)]] + turnAttachments.map(AttachmentEncoder.placeholder))]
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].apiTranscript.append(userMessage)
        }
        var request = ClaudeAPIRequest(model: claudeAPIModel, system: webInstructions(Self.claudeAPIInstructions),
                                       messages: AttachmentEncoder.expandClaude(conversations.first { $0.id == id }?.apiTranscript ?? [userMessage]),
                                       maxTokens: maxTokens, effort: claudeAPIEffort)
        if webSearchEnabled { request.tools = ClaudeAPIRequest.webTools }
        apiTurnSources = []
        progress.state = .running
        progress.phase = "API 요청 중 (\(claudeAPIModel))"
        if !pricing.known { notice = "이 모델의 요율을 몰라 가장 비싼 요율로 비용을 추정합니다." }

        apiTask = Task { [weak self] in
            guard let self else { return }
            var assembler = ClaudeAPIBlockAssembler()
            var usage = ClaudeAPIUsage()
            var stopReason = ""
            var stopDetails: JSONValue?
            var served = self.claudeAPIModel
            var failure: Error?
            var current = request
            var round = 0
            while true {
            assembler = ClaudeAPIBlockAssembler()
            usage = ClaudeAPIUsage()
            stopReason = ""
            stopDetails = nil
            failure = nil
            let sending = current
            let thisRound = round
            do {
                try await self.apiClient.stream(sending, apiKey: apiKey) { [weak self] event in
                    guard let self, self.claudeTurnTag == tag else { return }
                    assembler.apply(event)
                    switch event {
                    case .started(let model, _):
                        served = model
                        self.claudeAPIServedModel = model
                        self.progress.phase = "답변 시작 (\(model))"
                    case .textDelta(_, let delta):
                        self.upsert(id: "\(tag)-text", kind: .assistant) { $0.text += delta; $0.isStreaming = true }
                        self.progress.phase = "답변 작성 중"
                    case .thinkingDelta(_, let delta):
                        self.upsert(id: "\(tag)-thinking", kind: .activity, title: "생각 정리 중") { $0.text += delta; $0.status = "진행 중" }
                        self.progress.phase = "생각 정리 중"
                    case .usage(let latest):
                        usage = latest
                    case .finished(let reason, let details):
                        stopReason = reason
                        stopDetails = details
                    case .blockStarted(_, "server_tool_use"):
                        self.progress.phase = "웹 사용 중"
                    case .blockStopped(let index):
                        if let tool = assembler.serverTool(at: index) {
                            self.showWebActivity(tag: tag, key: "\(thisRound)-\(index)", name: tool.name, detail: tool.detail)
                        }
                    case .source(let title, let url):
                        self.apiTurnSources.append((title, url))
                    case .log(let line):
                        self.appendLog("·", "[api] " + APIDiagnostics.redacted(line, apiKey: apiKey))
                    default:
                        break
                    }
                    self.schedulePersistence()
                }
            } catch is CancellationError {
                failure = ClaudeAPIError.cancelled
            } catch let error as URLError where error.code == .cancelled {
                failure = ClaudeAPIError.cancelled
            } catch {
                failure = error
            }
            // 웹 도구를 꺼 둔 계정은 400 으로 거절됩니다. 거절된 요청은 요금이 없으니 도구 없이 다시 보냅니다.
            if !current.tools.isEmpty, Self.webToolsRejected(failure) {
                current.tools = []
                current.system = Self.claudeAPIInstructions
                self.notice = "이 API 계정이나 모델에서 웹 검색을 쓸 수 없어 웹 검색 없이 답합니다."
                continue
            }
            // 서버가 검색 도중 멈추면 받은 내용을 그대로 돌려보내 이어 달라고 합니다.
            if failure == nil, stopReason == "pause_turn", round < 5, self.claudeTurnTag == tag,
               let index = self.conversations.firstIndex(where: { $0.id == id }) {
                self.recordAPIUsage(conversation: index, provider: .claudeAPI, usage: usage, served: served)
                self.appendAssistant(assembler.resumableContent, conversation: index)
                current.messages = AttachmentEncoder.expandClaude(self.conversations[index].apiTranscript)
                round += 1
                continue
            }
            break
            }
            self.finishAPITurn(id: id, tag: tag, provider: .claudeAPI, assembler: assembler, usage: usage, served: served,
                               stopReason: stopReason, stopDetails: stopDetails, failure: failure, apiKey: apiKey)
        }
    }

    /// 웹 도구를 쓰도록 시스템 지시를 바꿉니다.
    private func webInstructions(_ base: String) -> String {
        guard webSearchEnabled else { return base }
        return base.replacingOccurrences(
            of: "도구 없이 텍스트로만 답합니다.",
            with: "최신 정보나 사용자가 준 링크가 필요하면 웹 검색과 웹 페이지 읽기 도구를 쓰세요. 이 Mac의 파일과 다른 앱에는 접근할 수 없습니다.")
    }

    /// 웹 도구 때문에 요청이 거절됐는지
    private static func webToolsRejected(_ failure: Error?) -> Bool {
        guard case .http(let status, _, let message)? = failure as? ClaudeAPIError, status == 400 else { return false }
        let lowered = message.lowercased()
        return ["web_search", "web_fetch", "web search", "web fetch"].contains { lowered.contains($0) }
    }

    private func showWebActivity(tag: String, key: String, name: String, detail: String) {
        let isFetch = name == "web_fetch"
        upsert(id: "\(tag)-web-\(key)", kind: .activity, title: isFetch ? "웹 페이지 읽기" : "웹 검색") { entry in
            if !detail.isEmpty { entry.text = detail }
            entry.status = "완료"
        }
        progress.phase = isFetch ? "웹 페이지 읽는 중" : "웹 검색 중"
    }

    /// 인용한 출처를 답변 아래에 링크로 붙입니다. 화면 표시용이라 AI 에게 보내는 기록은 바꾸지 않습니다.
    private func appendSources(tag: String) {
        var seen: Set<String> = []
        let lines = apiTurnSources.filter { source in
            source.url.lowercased().hasPrefix("http") && seen.insert(source.url).inserted
        }.prefix(8).map { source -> String in
            let title = source.title.filter { !"[]()\n".contains($0) }
            return "- [\(title.isEmpty ? source.url : title)](\(source.url))"
        }
        apiTurnSources = []
        guard !lines.isEmpty, entries.contains(where: { $0.id == "\(tag)-text" }) else { return }
        upsert(id: "\(tag)-text", kind: .assistant) { $0.text += "\n\n**\(tr("출처"))**\n" + lines.joined(separator: "\n") }
    }

    private func recordAPIUsage(conversation index: Int, provider: Provider, usage: ClaudeAPIUsage, served: String) {
        let pricing = provider == .openAIAPI ? OpenAIPricing.forModel(served) : ClaudePricing.forModel(served)
        conversations[index].apiSpentUSD += pricing.estimate(usage)
        let sent = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
        guard sent + usage.outputTokens > 0 else { return }
        conversations[index].usage.contextTokens = sent + usage.outputTokens
        conversations[index].usage.contextWindow = ModelContextWindow.tokens(for: served)
        conversations[index].usage.totalInputTokens += sent
        conversations[index].usage.totalOutputTokens += usage.outputTokens
    }

    /// 이어 받은 답은 앞 답과 한 메시지로 합칩니다.
    private func appendAssistant(_ content: [JSONValue], conversation index: Int) {
        guard !content.isEmpty else { return }
        if let last = conversations[index].apiTranscript.last, last["role"]?.stringValue == "assistant",
           let earlier = last["content"]?.arrayValue {
            conversations[index].apiTranscript[conversations[index].apiTranscript.count - 1] =
                ["role": "assistant", "content": .array(earlier + content)]
        } else {
            conversations[index].apiTranscript.append(["role": "assistant", "content": .array(content)])
        }
    }

    private func finishAPITurn(id: String, tag: String, provider: Provider, assembler: ClaudeAPIBlockAssembler, usage: ClaudeAPIUsage,
                               served: String, stopReason: String, stopDetails: JSONValue?, failure: Error?, apiKey: String) {
        guard claudeTurnTag == tag else { return }
        apiTask = nil
        let pricing = provider == .openAIAPI ? OpenAIPricing.forModel(served) : ClaudePricing.forModel(served)
        let cost = pricing.estimate(usage)
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            recordAPIUsage(conversation: index, provider: provider, usage: usage, served: served)
            switch provider {
            case .openAIAPI:
                // OpenAI 에는 완료된 텍스트만 돌려보냅니다 (추론 요약은 표시용).
                let text = assembler.completedContent.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
                if !text.isEmpty { conversations[index].apiTranscript.append(OpenAIAPIRequest.assistantItem(text)) }
            default:
                let content = assembler.completedContent
                appendAssistant(content, conversation: index)
            }
        }
        for i in entries.indices {
            entries[i].isStreaming = false
            if entries[i].title == "생각 정리 중" { entries[i].title = "생각 정리"; entries[i].status = "완료" }
        }
        appendSources(tag: tag)
        let interrupted = (failure as? ClaudeAPIError) == .cancelled
        if interrupted {
            progress.state = .interrupted
            progress.phase = "중단됨"
        } else if let failure {
            progress.state = .failed
            progress.phase = "API 실패"
            entries.append(ChatEntry(id: UUID().uuidString, kind: .error, text: APIDiagnostics.safeError(failure, apiKey: apiKey).localizedDescription))
        } else if stopReason == "refusal" {
            progress.state = .failed
            progress.phase = "안전 정책으로 거부됨"
            let category = APIDiagnostics.redacted(stopDetails?["category"]?.stringValue ?? "", apiKey: apiKey)
            entries.append(ChatEntry(id: UUID().uuidString, kind: .error,
                                     text: "안전 정책으로 답변이 거부되었습니다" + (category.isEmpty ? "." : " (\(category)).")))
        } else if stopReason == "max_tokens" {
            progress.state = .completed
            progress.phase = "출력 상한(예산)에 닿아 답변이 잘렸을 수 있습니다"
        } else {
            progress.state = .completed
            progress.phase = "완료"
        }
        tokenSummary = "토큰 입력 \(usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens) · 출력 \(usage.outputTokens)"
            + String(format: " · 이번 턴 추정 $%.4f", cost)
        stopRequested = false
        interruptSent = false
        persist()
        turnDidFinish(conversationID: id)
    }

    /// 사용자 말풍선을 추가하고 진행 상태를 시작합니다. 두 연결이 공통으로 씁니다.
    private func beginTurn(_ id: String, text: String) {
        stopRequested = false
        interruptSent = false
        draft = ""
        turnAttachments = pendingAttachments
        pendingAttachments = []
        var userEntry = ChatEntry(id: UUID().uuidString, kind: .user, text: text)
        userEntry.attachmentNames = turnAttachments.map(\.name)
        userEntry.attachmentPaths = turnAttachments.map(\.path)
        entries.append(userEntry)
        turnStartIndex = entries.count
        progress = TurnProgress(state: .requesting, turnID: nil, phase: "요청 보내는 중", startedAt: Date())
        if let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].title == "새 대화" {
            conversations[index].title = String(text.prefix(40))
        }
        persist()
    }

    private func sendToClaude(_ conversation: StoredConversation, text: String) async {
        guard claudeAuth.isLoggedIn else { notice = "Claude 에 로그인되어 있지 않습니다. ‘연결 관리’의 ‘로그인 명령 복사’로 터미널에서 로그인해 주세요."; return }
        let id = conversation.id
        // 모델/노력 설정이 바뀌었으면 프로세스를 다시 띄워 다음 턴부터 적용합니다.
        let mcpConfigJSON = MCPServerList.claudeConfigJSON(enabledMCPServers)
        let launchSignature = "\(claudeModel)|\(claudeEffort)|\(conversation.workspacePath)|\(mcpConfigJSON)|\(MCPServerList.claudeAllowedTools(enabledMCPServers))"
        if !(claude.isRunning && claude.sessionID == id && claudeLaunchSignature == launchSignature) {
            do {
                let workspace = conversation.hasWorkspace ? URL(fileURLWithPath: conversation.workspacePath) : store.sandboxDirectory
                let extraDirectories = conversation.hasWorkspace
                    ? [attachmentStore.attachmentsDirectory(for: id), attachmentStore.outputsDirectory(for: id)] : []
                for directory in extraDirectories { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                try claude.start(executableOverride: claudePathOverride, sessionID: id, resume: conversation.claudeSessionReady,
                                 workingDirectory: workspace,
                                 systemPromptAppendix: conversation.hasWorkspace
                                     ? Self.workspaceInstructions + " " + fileFolderHint(for: id) : Self.claudeInstructions,
                                 model: claudeModel, effort: claudeEffort, toolsEnabled: conversation.hasWorkspace,
                                 additionalDirectories: extraDirectories,
                                 mcpConfigJSON: mcpConfigJSON, mcpToolNames: MCPServerList.claudeToolNames(enabledMCPServers),
                                 allowedTools: MCPServerList.claudeAllowedTools(enabledMCPServers),
                                 webToolsEnabled: webSearchEnabled)
                claudeMCPStatus = [:]
                claudeLaunchSignature = launchSignature
            } catch {
                notice = "Claude Code 를 시작하지 못했습니다: \(error.localizedDescription)"
                return
            }
        }
        guard !progress.isBusy, selectedID == id else { return }
        beginTurn(id, text: text)
        claudeTurnTag = String(UUID().uuidString.prefix(8))
        do {
            // 이미지는 image 블록. PDF/ZIP 은 작업 폴더 모드면 경로(직접 읽음), 아니면 PDF 는 document 블록·ZIP 은 글자.
            var fullText = text
            var blocks: [JSONValue] = []
            for attachment in turnAttachments {
                switch attachment.kind {
                case .png, .jpeg: blocks += AttachmentEncoder.claudeBlocks(attachment)
                case .pdf: if conversation.hasWorkspace { fullText += "\n\n" + AttachmentEncoder.pathNote(attachment) } else { blocks += AttachmentEncoder.claudeBlocks(attachment) }
                case .zip: fullText += "\n\n" + (conversation.hasWorkspace ? AttachmentEncoder.pathNote(attachment) : AttachmentEncoder.zipSummary(attachment))
                }
            }
            try claude.sendUserMessage(content: [["type": "text", "text": .string(fullText)]] + blocks)
            // CLI 는 턴 ID 를 따로 주지 않습니다. 보낸 순간부터 중단 요청을 받을 수 있습니다.
            progress.state = .running
            progress.phase = "응답 기다리는 중"
        } catch {
            progress.state = .failed
            progress.phase = "전송 실패"
            entries.append(ChatEntry(id: UUID().uuidString, kind: .error, text: error.localizedDescription))
            persist()
        }
    }

    private func sendToCodex(_ id: String, text: String) async {
        guard connection.isConnected else { notice = "Codex 에 연결되어 있지 않습니다."; return }
        await prepareThread(id)
        // 빈 대화가 새 스레드로 바뀌었으면 바뀐 ID 로 계속합니다.
        let id = readyThreads.contains(id) ? id : (selectedID ?? id)
        guard readyThreads.contains(id) else {
            // prepareThread 가 실제 원인을 notice 에 적었으면 덮어쓰지 않습니다.
            if notice == nil { notice = "이 대화를 서버에서 열지 못해 보낼 수 없습니다." }
            return
        }

        guard !progress.isBusy, selectedID == id else { return }
        beginTurn(id, text: text)

        do {
            let workspace = conversations.first { $0.id == id }?.workspacePath ?? ""
            // 이미지는 localImage 항목으로, PDF/ZIP 은 작업 폴더 모드면 경로를, 아니면 글자로 풀어 보냅니다.
            var fullText = text
            var items: [JSONValue] = []
            for attachment in turnAttachments {
                if attachment.kind.isImage {
                    items.append(["type": "localImage", "path": .string(attachment.path)])
                } else {
                    fullText += "\n\n" + (workspace.isEmpty ? AttachmentEncoder.textFallback(attachment) : AttachmentEncoder.pathNote(attachment))
                }
            }
            if !workspace.isEmpty { fullText += "\n\n(" + fileFolderHint(for: id) + ")" }
            let turnParams = JSONValue.object(codexTurnParams(workspace: workspace, conversationID: id)).merging([
                "threadId": .string(id),
                "input": .array([["type": "text", "text": .string(fullText)]] + items),
            ])
            let result = try await client.request("turn/start", params: turnParams, timeout: 60)
            if let turnID = result["turn"]?["id"]?.stringValue {
                progress.turnID = turnID
                if stopRequested { await sendPendingInterrupt() }
            }
            if progress.state == .requesting { progress.state = .running; progress.phase = "응답 기다리는 중" }
        } catch {
            progress.state = .failed
            progress.phase = "전송 실패"
            entries.append(ChatEntry(id: UUID().uuidString, kind: .error, text: error.localizedDescription))
            persist()
        }
    }

    func interrupt() async {
        guard progress.isBusy else { return }
        stopRequested = true
        progress.phase = "중단 요청 중…"
        switch selectedProvider {
        case .codex: await sendPendingInterrupt()
        case .claude: await sendClaudeInterrupt()
        case .claudeAPI, .openAIAPI: apiTask?.cancel()
        case .localLLM: localTask?.cancel()
        }
    }

    private func sendClaudeInterrupt() async {
        guard stopRequested, !interruptSent, progress.isBusy, claude.isRunning else { return }
        interruptSent = true
        do {
            try await claude.interrupt()
        } catch {
            interruptSent = false
            notice = "중단 요청 실패: \(error.localizedDescription). 다시 눌러 주세요."
        }
    }

    private func sendPendingInterrupt() async {
        guard stopRequested, !interruptSent, progress.isBusy,
              let id = selectedID, let turnID = progress.turnID else { return }
        interruptSent = true
        do {
            _ = try await client.request("turn/interrupt", params: ["threadId": .string(id), "turnId": .string(turnID)], timeout: 20)
        } catch {
            interruptSent = false
            notice = "중단 요청 실패: \(error.localizedDescription). 다시 눌러 주세요."
        }
    }

    func flushAndDisconnect() {
        persistenceTask?.cancel()
        persist()
        disconnect()
        claude.stop()
        apiTask?.cancel()
        localTask?.cancel()
        localDownloadTask?.cancel()
    }

    // MARK: Claude 이벤트 처리

    private func handleClaude(_ event: ClaudeEvent) {
        switch event {
        case .log(let direction, let text):
            appendLog(direction, "[claude] \(text)")
        case .exited(let code):
            appendLog("!", "claude 종료 (코드 \(code))")
            if progress.isBusy, selectedProvider == .claude {
                progress.state = .failed
                progress.phase = "Claude 프로세스 종료 (코드 \(code))"
                for i in entries.indices { entries[i].isStreaming = false }
                persist()
            }
        case .controlRequest(let subtype, let params, let autoReply):
            guard selectedProvider == .claude else { return }
            let detail = params?["tool_name"]?.stringValue ?? ""
            entries.append(ChatEntry(id: UUID().uuidString, kind: .activity,
                                     title: "Claude 요청 \(subtype) → \(autoReply)", text: detail, status: "차단됨"))
            notice = "이번 실험은 대화만 지원합니다. 도구 사용 요청을 거절했습니다."
            persist()
        case .permissionRequest(let requestID, let toolName, let input, let description):
            guard selectedProvider == .claude, selectedConversation?.hasWorkspace == true else {
                claude.respondPermission(requestID: requestID, allow: false, input: input, message: "이 대화는 작업 폴더 모드가 아닙니다.")
                return
            }
            let filePaths = ApprovalSummary.claudeFilePaths(tool: toolName, input: input)
            var text = ApprovalSummary.claudeText(tool: toolName, input: input)
            if !description.isEmpty { text = description + "\n" + text }
            addApprovalEntry(PendingApproval(entryID: UUID().uuidString, provider: .claude, requestID: requestID,
                                             tool: toolName, input: input, filePaths: filePaths), text: text)
        case .message(let type, let payload):
            guard selectedProvider == .claude,
                  payload["session_id"]?.stringValue ?? selectedID ?? "" == selectedID ?? "" else { return }
            handleClaudeMessage(type, payload)
            schedulePersistence()
        }
    }

    private func handleClaudeMessage(_ type: String, _ payload: JSONValue) {
        switch type {
        case "system":
            switch payload["subtype"]?.stringValue {
            case "init":
                claudeModelName = payload["model"]?.stringValue ?? ""
                if let servers = payload["mcp_servers"]?.arrayValue {
                    var status: [String: String] = [:]
                    for server in servers { if let name = server["name"]?.stringValue { status[name] = server["status"]?.stringValue ?? "" } }
                    claudeMCPStatus = status
                    let needsAuth = status.filter { $0.value == "needs-auth" }.keys.sorted()
                    if !needsAuth.isEmpty { notice = "MCP 서버 로그인이 필요합니다: \(needsAuth.joined(separator: ", ")). ‘연결 관리’에서 ‘로그인 명령 복사’ 후 터미널에서 실행하세요." }
                }
                if let errors = payload["mcp_server_errors"]?.arrayValue, !errors.isEmpty {
                    notice = "MCP 설정 오류: " + errors.map { "\($0["name"]?.stringValue ?? "?"): \($0["message"]?.stringValue ?? "")" }.joined(separator: " / ")
                }
                if progress.isBusy { progress.phase = "Claude 준비됨" + (claudeModelName.isEmpty ? "" : " · \(claudeModelName)") }
            case "status":
                if progress.isBusy, payload["status"]?.stringValue == "requesting" { progress.phase = "요청 중" }
            case "api_retry":
                let attempt = payload["attempt"]?.intValue ?? 0
                let max = payload["max_retries"]?.intValue ?? 0
                progress.phase = "재시도 중 (\(attempt)/\(max)) \(payload["error"]?.stringValue ?? "")"
            case "permission_denied":
                entries.append(ChatEntry(id: UUID().uuidString, kind: .activity, title: "도구 요청 자동 거절",
                                         text: payload["tool_name"]?.stringValue ?? "", status: "차단됨"))
            default: break
            }
        case "stream_event":
            let event = payload["event"] ?? .null
            let messageID = "\(claudeTurnTag)-\(payload["api_message_id"]?.stringValue ?? "msg")"
            switch event["type"]?.stringValue {
            case "message_start":
                progress.state = .running
                progress.phase = "답변 시작"
            case "content_block_delta":
                let delta = event["delta"] ?? .null
                switch delta["type"]?.stringValue {
                case "text_delta":
                    let text = delta["text"]?.stringValue ?? ""
                    upsert(id: "\(messageID)-text", kind: .assistant) { $0.text += text; $0.isStreaming = true }
                    progress.phase = "답변 작성 중"
                case "thinking_delta":
                    let text = delta["thinking"]?.stringValue ?? delta["text"]?.stringValue ?? ""
                    upsert(id: "\(messageID)-thinking", kind: .activity, title: "생각 정리 중") { $0.text += text; $0.status = "진행 중" }
                    progress.phase = "생각 정리 중"
                default: break
                }
            default: break
            }
        case "assistant":
            let message = payload["message"] ?? .null
            // 하위 작업의 메시지는 대화 컨텍스트에 들어가지 않습니다.
            if payload["parent_tool_use_id"]?.stringValue == nil, let usage = message["usage"] {
                claudeLastContextTokens = (usage["input_tokens"]?.intValue ?? 0) + (usage["cache_read_input_tokens"]?.intValue ?? 0)
                    + (usage["cache_creation_input_tokens"]?.intValue ?? 0) + (usage["output_tokens"]?.intValue ?? 0)
            }
            let messageID = "\(claudeTurnTag)-\(message["id"]?.stringValue ?? "msg")"
            if let index = conversations.firstIndex(where: { $0.id == selectedID }) {
                conversations[index].claudeSessionReady = true // CLI 기록에 세션이 생겼으므로 다음엔 --resume
            }
            for block in message["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    let text = block["text"]?.stringValue ?? ""
                    guard !text.isEmpty else { continue }
                    upsert(id: "\(messageID)-text", kind: .assistant) { $0.text = text; $0.isStreaming = true }
                case "thinking":
                    let text = block["thinking"]?.stringValue ?? ""
                    guard !text.isEmpty else { continue }
                    upsert(id: "\(messageID)-thinking", kind: .activity, title: "생각 정리") { $0.text = text; $0.status = "완료" }
                case "tool_use":
                    let name = block["name"]?.stringValue ?? ""
                    let hasWorkspace = selectedConversation?.hasWorkspace == true
                    upsert(id: block["id"]?.stringValue ?? UUID().uuidString, kind: .activity,
                           title: hasWorkspace ? "도구 \(name)" : "도구 호출 시도 \(name)") { entry in
                        entry.text = ApprovalSummary.claudeText(tool: name, input: block["input"])
                        entry.status = hasWorkspace ? "실행 중" : "도구 없음"
                    }
                    progress.phase = "도구 \(name)"
                default: break
                }
            }
        case "user":
            // 도구 결과(tool_result)는 해당 도구 항목의 상태로 반영합니다. 그 밖의 user 메시지는 CLI 내부용입니다.
            for block in payload["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                guard let toolUseID = block["tool_use_id"]?.stringValue,
                      let index = entries.firstIndex(where: { $0.id == toolUseID }) else { continue }
                let isError = block["is_error"]?.boolValue ?? false
                entries[index].status = isError ? "오류" : "완료"
                let resultText = block["content"]?.stringValue
                    ?? (block["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                if !resultText.isEmpty {
                    let clipped = resultText.count > 800 ? String(resultText.prefix(800)) + "\n…(생략)" : resultText
                    entries[index].text += "\n→ \(clipped)"
                }
                // 도구(MCP 등)가 돌려준 이미지는 ‘받은 파일’ 폴더에 저장해 턴이 끝나면 미리보기 항목으로 보여줍니다.
                if let id = selectedID {
                    let toolName = entries[index].title.split(separator: " ").last.map(String.init) ?? "도구"
                    let saved = saveToolResultImages(block["content"]?.arrayValue ?? [], conversationID: id, toolName: toolName)
                    if saved > 0 { entries[index].text += "\n→ 이미지 \(saved)개를 받은 파일로 저장" }
                }
            }
        case "rate_limit_event":
            let windows = payload["rate_limit_info"]?["unifiedWindows"]
            func percent(_ key: String) -> String? {
                windows?[key]?["utilization"]?.doubleValue.map { "\(Int(($0 * 100).rounded()))%" }
            }
            var parts: [String] = []
            if let five = percent("five_hour") { parts.append("5시간 창 \(five)") }
            if let week = percent("seven_day") { parts.append("7일 창 \(week)") }
            claudeUsageSummary = parts.isEmpty ? "" : "구독 사용량 " + parts.joined(separator: " · ")
        case "result":
            finishClaudeTurn(payload)
        default:
            break
        }
    }

    private func finishClaudeTurn(_ payload: JSONValue) {
        let subtype = payload["subtype"]?.stringValue ?? ""
        let isError = payload["is_error"]?.boolValue ?? false
        let reason = payload["terminal_reason"]?.stringValue ?? ""
        if reason == "aborted_streaming" || (isError && stopRequested) {
            progress.state = .interrupted
            progress.phase = "중단됨"
        } else if isError || subtype != "success" {
            progress.state = .failed
            progress.phase = "실패"
            let errors = (payload["errors"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " / ")
            let message = payload["result"]?.stringValue ?? (errors.isEmpty ? subtype : errors)
            entries.append(ChatEntry(id: UUID().uuidString, kind: .error, text: message))
        } else {
            progress.state = .completed
            progress.phase = "완료"
        }
        stopRequested = false
        interruptSent = false
        expirePendingApprovals()
        for i in entries.indices {
            entries[i].isStreaming = false
            if entries[i].title == "생각 정리 중" { entries[i].title = "생각 정리"; entries[i].status = "완료" }
        }
        if let usage = payload["usage"] {
            let input = (usage["input_tokens"]?.intValue ?? 0) + (usage["cache_read_input_tokens"]?.intValue ?? 0)
                + (usage["cache_creation_input_tokens"]?.intValue ?? 0)
            let output = usage["output_tokens"]?.intValue ?? 0
            tokenSummary = "토큰 입력 \(input) · 출력 \(output)"
            if let index = conversations.firstIndex(where: { $0.id == selectedID }) {
                // result 의 usage 는 이번 턴 전체 합계이므로 컨텍스트는 마지막 메시지 값을 씁니다.
                conversations[index].usage.contextTokens = claudeLastContextTokens > 0 ? claudeLastContextTokens : input + output
                conversations[index].usage.totalInputTokens += input
                conversations[index].usage.totalOutputTokens += output
                let windows = (payload["modelUsage"]?.objectValue?.values ?? [:].values).compactMap { $0["contextWindow"]?.intValue }
                if let window = windows.max() { conversations[index].usage.contextWindow = window }
            }
        }
        claudeLastContextTokens = 0
        persist()
        if let id = selectedID { turnDidFinish(conversationID: id) }
    }

    // MARK: 이벤트 처리

    private func handle(_ event: CodexEvent) {
        switch event {
        case .log(let direction, let text):
            appendLog(direction, "[codex] \(text)")
        case .exited(let code):
            appendLog("!", "codex app-server 종료 (코드 \(code))")
            if connection.isConnected || connection == .starting {
                connection = .failed("프로세스 종료 (코드 \(code))")
            }
            readyThreads.removeAll()
            if progress.isBusy { progress.state = .failed; progress.phase = "연결 끊김" }
        case .approvalRequest(let requestID, let method, let params):
            let threadID = params?["threadId"]?.stringValue
            let conversation = conversations.first { $0.id == (threadID ?? selectedID ?? "") }
            guard let conversation, conversation.hasWorkspace, conversation.id == selectedID else {
                client.respondApproval(requestID: requestID, decision: "cancel")
                entries.append(ChatEntry(id: UUID().uuidString, kind: .activity,
                                         title: "서버 요청 \(method) → 거절 및 턴 중단(cancel)",
                                         text: params?["command"]?.displayString ?? params?["changes"]?.displayString ?? "", status: "차단됨"))
                notice = "이 대화는 작업 폴더 모드가 아니라 도구 승인 요청을 차단했습니다."
                Task { await self.interrupt() }
                persist()
                return
            }
            let tool = method.contains("commandExecution") ? "명령 실행" : (method.contains("fileChange") ? "파일 변경" : method)
            addApprovalEntry(PendingApproval(entryID: UUID().uuidString, provider: .codex, requestID: requestID, tool: tool,
                                             input: params, filePaths: ApprovalSummary.codexFilePaths(params: params)),
                             text: ApprovalSummary.codexText(method: method, params: params))
        case .serverRequest(let method, let params, let autoReply):
            let threadID = params?["threadId"]?.stringValue
            guard selectedProvider == .codex, threadID == nil || threadID == selectedID else { return }
            let detail = params?["command"]?.displayString
                ?? params?["reason"]?.stringValue
                ?? params?["changes"]?.displayString ?? ""
            entries.append(ChatEntry(id: UUID().uuidString, kind: .activity,
                                     title: "서버 요청 \(method) → \(autoReply)", text: detail, status: "차단됨"))
            progress.phase = "요청을 차단하고 중단합니다"
            notice = "이번 실험은 대화만 지원합니다. 도구 승인 요청을 차단했습니다."
            Task { await self.interrupt() }
            persist()
        case .notification(let method, let params):
            handleNotification(method, params)
            schedulePersistence()
        }
    }

    func handleNotification(_ method: String, _ params: JSONValue?) {
        guard selectedProvider == .codex else { return } // Claude 대화를 보는 동안 Codex 이벤트는 로그에만 남깁니다.
        if let threadID = params?["threadId"]?.stringValue ?? params?["thread"]?["id"]?.stringValue,
           let selectedID, threadID != selectedID {
            return // 다른 대화의 이벤트는 로그에만 남깁니다.
        }
        switch method {
        case "turn/started":
            if let turnID = params?["turn"]?["id"]?.stringValue { progress.turnID = turnID }
            progress.state = .running
            progress.phase = "턴 시작"
            if progress.startedAt == nil { progress.startedAt = Date() }
            if stopRequested { Task { await self.sendPendingInterrupt() } }
        case "turn/completed":
            let status = params?["turn"]?["status"]?.stringValue ?? "completed"
            switch status {
            case "interrupted": progress.state = .interrupted; progress.phase = "중단됨"
            case "failed":
                progress.state = .failed
                progress.phase = "실패: \(params?["turn"]?["error"]?["message"]?.stringValue ?? "")"
            default: progress.state = .completed; progress.phase = "완료"
            }
            stopRequested = false
            interruptSent = false
            expirePendingApprovals()
            for i in entries.indices { entries[i].isStreaming = false }
            persist()
            if let id = selectedID { turnDidFinish(conversationID: id) }
        case "item/started":
            if let item = params?["item"] { applyItem(item, completed: false) }
        case "item/completed":
            if let item = params?["item"] { applyItem(item, completed: true) }
        case "item/agentMessage/delta":
            guard let itemID = params?["itemId"]?.stringValue, let delta = params?["delta"]?.stringValue else { return }
            upsert(id: itemID, kind: .assistant) { $0.text += delta; $0.isStreaming = true }
            progress.phase = "답변 작성 중"
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let itemID = params?["itemId"]?.stringValue, let delta = params?["delta"]?.stringValue else { return }
            upsert(id: itemID, kind: .activity, title: "생각 정리 중") { $0.text += delta }
            progress.phase = "생각 정리 중"
        case "item/commandExecution/outputDelta":
            guard let itemID = params?["itemId"]?.stringValue, let delta = params?["delta"]?.stringValue else { return }
            upsert(id: itemID, kind: .activity, title: "명령 실행") { $0.text += delta }
        case "thread/tokenUsage/updated":
            let usage = params?["tokenUsage"]
            let total = usage?["total"]?["totalTokens"]?.intValue ?? usage?["totalTokens"]?.intValue
            let window = usage?["modelContextWindow"]?.intValue
            if let total { tokenSummary = "토큰 \(total)" + (window.map { " / 창 \($0)" } ?? "") }
            let threadID = params?["threadId"]?.stringValue ?? selectedID
            if let index = conversations.firstIndex(where: { $0.id == threadID }), let last = usage?["last"], let sum = usage?["total"] {
                conversations[index].usage.contextTokens = last["totalTokens"]?.intValue ?? 0
                if let window { conversations[index].usage.contextWindow = window }
                conversations[index].usage.totalInputTokens = sum["inputTokens"]?.intValue ?? 0
                conversations[index].usage.totalOutputTokens = sum["outputTokens"]?.intValue ?? 0
            }
        case "account/rateLimits/updated":
            applyCodexRateLimits(params?["rateLimits"])
        case "error":
            let message = params?["error"]?["message"]?.stringValue ?? params?["message"]?.stringValue ?? "알 수 없는 오류"
            let willRetry = params?["willRetry"]?.boolValue ?? false
            entries.append(ChatEntry(id: UUID().uuidString, kind: .error, text: message + (willRetry ? " (재시도 중)" : "")))
            if !willRetry, progress.isBusy { progress.state = .failed; progress.phase = "오류" }
        case "account/login/completed", "account/updated":
            Task { await refreshAccount() }
        default:
            break
        }
    }

    private func applyItem(_ item: JSONValue, completed: Bool) {
        let type = item["type"]?.stringValue ?? "unknown"
        let itemID = item["id"]?.stringValue ?? UUID().uuidString
        let status = item["status"]?.stringValue ?? (completed ? "완료" : "진행 중")
        switch type {
        case "userMessage":
            break // 보낸 사람이 우리이므로 이미 화면에 있습니다.
        case "agentMessage":
            let text = item["text"]?.stringValue ?? ""
            upsert(id: itemID, kind: .assistant) { entry in
                if completed || entry.text.isEmpty { entry.text = text.isEmpty ? entry.text : text }
                entry.isStreaming = !completed
            }
            progress.phase = completed ? "답변 완료" : "답변 작성 중"
        case "reasoning":
            let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
            upsert(id: itemID, kind: .activity, title: completed ? "생각 정리" : "생각 정리 중") { entry in
                if !summary.isEmpty { entry.text = summary }
                entry.status = completed ? "완료" : "진행 중"
            }
            progress.phase = completed ? "생각 정리 끝" : "생각 정리 중"
        case "commandExecution":
            let command = item["command"]?.displayString ?? ""
            upsert(id: itemID, kind: .activity, title: "명령 실행 요청") { entry in
                if entry.text.isEmpty { entry.text = command }
                if let exit = item["exitCode"]?.intValue { entry.status = "\(status) · 종료코드 \(exit)" } else { entry.status = status }
            }
            progress.phase = completed ? "명령 처리 끝 (\(status))" : "명령 실행 요청 (읽기 전용 샌드박스)"
        case "fileChange":
            let paths = (item["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }.joined(separator: ", ")
            upsert(id: itemID, kind: .activity, title: "파일 변경 이벤트 (실행 결과 확인 필요)") { entry in
                entry.text = paths; entry.status = status
            }
            progress.phase = "파일 변경 이벤트 수신"
        case "webSearch":
            upsert(id: itemID, kind: .activity, title: "웹 검색") { $0.text = item["query"]?.stringValue ?? ""; $0.status = status }
            progress.phase = "웹 검색 중"
        case "mcpToolCall":
            let name = "mcp__\(item["server"]?.stringValue ?? "")__\(item["tool"]?.stringValue ?? "")"
            let arguments = (try? item["arguments"]?.compactJSON()) ?? ""
            let resultBlocks = item["result"]?["content"]?.arrayValue ?? []
            let resultText = resultBlocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            let errorText = item["error"]?["message"]?.stringValue ?? ""
            let statusText = status == "completed" ? "완료" : status == "failed" ? "실패" : "진행 중"
            upsert(id: itemID, kind: .activity, title: "도구 \(name)") {
                $0.status = statusText
                var text = arguments.count > 600 ? String(arguments.prefix(600)) + "…" : arguments
                if !resultText.isEmpty { text += "\n→ " + (resultText.count > 800 ? String(resultText.prefix(800)) + "\n…(생략)" : resultText) }
                if !errorText.isEmpty { text += "\n⚠️ " + errorText }
                $0.text = text
            }
            if completed, let id = selectedID {
                let saved = saveToolResultImages(resultBlocks, conversationID: id, toolName: name)
                if saved > 0, let index = entries.firstIndex(where: { $0.id == itemID }) { entries[index].text += "\n→ 이미지 \(saved)개를 받은 파일로 저장" }
            }
            progress.phase = "도구 호출"
        case "error":
            entries.append(ChatEntry(id: itemID, kind: .error, text: item["message"]?.stringValue ?? "오류"))
        default:
            upsert(id: itemID, kind: .activity, title: type) { $0.status = status }
        }
    }

    private func upsert(id: String, kind: ChatEntry.Kind, title: String = "", _ update: (inout ChatEntry) -> Void) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            if !title.isEmpty { entries[index].title = title }
            update(&entries[index])
        } else {
            var entry = ChatEntry(id: id, kind: kind, title: title, text: "")
            update(&entry)
            entries.append(entry)
        }
    }

    /// thread/resume 응답의 turns 배열을 화면 항목으로 바꿉니다.
    private static func entries(fromTurns turns: [JSONValue]) -> [ChatEntry] {
        var result: [ChatEntry] = []
        for turn in turns {
            for item in turn["items"]?.arrayValue ?? [] {
                let type = item["type"]?.stringValue ?? ""
                let id = item["id"]?.stringValue ?? UUID().uuidString
                switch type {
                case "userMessage":
                    let text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                    result.append(ChatEntry(id: id, kind: .user, text: text))
                case "agentMessage":
                    result.append(ChatEntry(id: id, kind: .assistant, text: item["text"]?.stringValue ?? ""))
                case "reasoning":
                    let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
                    if !summary.isEmpty { result.append(ChatEntry(id: id, kind: .activity, title: "생각 정리", text: summary, status: "완료")) }
                case "commandExecution":
                    result.append(ChatEntry(id: id, kind: .activity, title: "명령 실행 요청",
                                            text: item["command"]?.displayString ?? "", status: item["status"]?.stringValue ?? ""))
                case "fileChange":
                    let paths = (item["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }.joined(separator: ", ")
                    result.append(ChatEntry(id: id, kind: .activity, title: "파일 수정 시도", text: paths, status: item["status"]?.stringValue ?? ""))
                case "error":
                    result.append(ChatEntry(id: id, kind: .error, text: item["message"]?.stringValue ?? "오류"))
                default:
                    result.append(ChatEntry(id: id, kind: .activity, title: type, text: "", status: item["status"]?.stringValue ?? ""))
                }
            }
        }
        return result
    }

    // MARK: 승인·백업·되돌리기 (작업 폴더 모드)

    private func addApprovalEntry(_ approval: PendingApproval, text: String) {
        pendingApprovals[approval.entryID] = approval
        var entry = ChatEntry(id: approval.entryID, kind: .approval, title: "승인 요청 · \(approval.tool)", text: text, status: "대기 중")
        entry.isPendingApproval = true
        entries.append(entry)
        // 파일 수정이면(명령 실행 제외) 스위치에 따라 자동 허용. 백업은 approve() 가 그대로 남깁니다.
        // 단, 작업 폴더와 받은 파일 폴더 안의 파일만. 그 밖(홈 폴더의 설정 파일 등)은 항상 묻습니다.
        let relayAuto = relayIsActive && relayAutoApproveEdits && relay?.conversationID == selectedID
        if (relayAuto || autoApproveEdits), !approval.filePaths.isEmpty,
           let conversation = selectedConversation, Self.pathsAreInside(approval.filePaths, roots: autoApproveRoots(for: conversation)) {
            approve(entryID: approval.entryID)
            if let index = entries.firstIndex(where: { $0.id == approval.entryID }) { entries[index].status = relayAuto ? "자동 허용(릴레이)" : "자동 허용" }
            return
        }
        progress.phase = "승인을 기다리는 중: \(approval.tool)"
        NSSound.beep()
        Notifier.notify(title: "승인이 필요합니다", body: "\(approval.tool) · \(selectedConversation?.title ?? "")")
        persist()
    }

    // MARK: 편의 기능

    /// tool_result 의 image 블록(base64)을 받은 파일 폴더에 씁니다. 저장한 개수를 돌려줍니다.
    @discardableResult
    func saveToolResultImages(_ blocks: [JSONValue], conversationID: String, toolName: String) -> Int {
        var count = 0
        for block in blocks where block["type"]?.stringValue == "image" {
            // Anthropic 형식(source.data/media_type)과 MCP 형식(data/mimeType) 둘 다
            let data64 = block["source"]?["data"]?.stringValue ?? block["data"]?.stringValue ?? ""
            guard let data = Data(base64Encoded: data64), !data.isEmpty else { continue }
            let mediaType = block["source"]?["media_type"]?.stringValue ?? block["mimeType"]?.stringValue ?? "image/png"
            let ext = mediaType.split(separator: "/").last.map(String.init) ?? "png"
            let directory = attachmentStore.outputsDirectory(for: conversationID)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeTool = toolName.replacingOccurrences(of: "/", with: "_").prefix(40)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let target = directory.appendingPathComponent("\(safeTool)-\(stamp)-\(count + 1).\(ext == "jpeg" ? "jpg" : ext)")
            if (try? data.write(to: target, options: .atomic)) != nil { count += 1 }
        }
        return count
    }

    func beginRename(_ id: String) {
        renameDraft = conversations.first { $0.id == id }?.title ?? ""
        renameTargetID = id
    }

    func commitRename() {
        guard let id = renameTargetID, let index = conversations.firstIndex(where: { $0.id == id }) else { renameTargetID = nil; return }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { conversations[index].title = String(title.prefix(80)); store.save(conversations) }
        renameTargetID = nil
    }

    /// 대화 하나를 마크다운 문서로 만듭니다 (내보내기용).
    func conversationMarkdown(_ id: String) -> String {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["# \(conversation.title)", "",
                     tr("- 연결: \(conversation.provider.displayName)"), tr("- 만든 날짜: \(formatter.string(from: conversation.createdAt))")]
        if conversation.hasWorkspace { lines.append(tr("- 작업 폴더: \(conversation.workspacePath)")) }
        if conversation.provider.isDirectAPI { lines.append(tr(String(format: "- 예상 비용: $%.4f / 예산 $%.2f", conversation.apiSpentUSD, conversation.apiBudgetUSD))) }
        lines.append("")
        let messages = selectedID == id ? entries.map { StoredMessage(id: $0.id, role: $0.kind, title: $0.title, text: $0.text, status: $0.status,
                                                                      changeRecordID: $0.changeRecordID, attachmentNames: $0.attachmentNames,
                                                                      attachmentPaths: $0.attachmentPaths) }
                                        : conversation.messages
        for message in messages {
            switch message.role {
            case .user:
                lines.append(tr("## 나"))
                lines.append("")
                lines.append(message.text)
                if let names = message.attachmentNames, !names.isEmpty { lines.append(""); lines.append(tr("첨부: " + names.joined(separator: ", "))) }
            case .assistant:
                lines.append("## \(conversation.provider.displayName)")
                lines.append("")
                lines.append(message.text)
            case .activity:
                guard !(message.title.hasPrefix("생각 정리") && message.text.isEmpty) else { continue }
                lines.append("> **\(message.title)**" + (message.status.isEmpty ? "" : " · \(message.status)"))
                if !message.text.isEmpty { lines.append(contentsOf: message.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(30).map { "> " + $0 }) }
            case .approval:
                lines.append("> **\(message.title)** · \(message.status)")
                lines.append(contentsOf: message.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(30).map { "> " + $0 })
            case .file:
                lines.append(tr("> **받은 파일** · \(message.title) · \(message.text)"))
            case .error:
                lines.append("> ⚠️ \(message.text)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func exportConversationMarkdown(_ id: String) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        let safeTitle = conversation.title.replacingOccurrences(of: "/", with: "-").prefix(40)
        panel.nameFieldStringValue = "\(safeTitle).md"
        panel.prompt = tr("내보내기")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try conversationMarkdown(id).write(to: url, atomically: true, encoding: .utf8)
            notice = "내보냈습니다: \(url.lastPathComponent)"
        } catch {
            notice = "내보내기 실패: \(error.localizedDescription)"
        }
    }

    // MARK: MCP 서버

    func addMCPServer(_ server: MCPServer) {
        var server = server
        server.id = UUID().uuidString
        guard server.isValid else { notice = "서버 이름은 영문·숫자·-·_ 만 쓰고, 주소나 명령을 채워 주세요."; return }
        guard !mcpServers.contains(where: { $0.name == server.name }) else { notice = "같은 이름의 MCP 서버가 이미 있습니다: \(server.name)"; return }
        mcpServers.append(server)
        mcpServersDidChange()
    }

    func removeMCPServer(id: String) {
        mcpServers.removeAll { $0.id == id }
        mcpServersDidChange()
    }

    func setMCPServer(id: String, enabled: Bool? = nil, autoAllow: Bool? = nil) {
        guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        if let enabled { mcpServers[index].enabled = enabled }
        if let autoAllow { mcpServers[index].autoAllow = autoAllow }
        mcpServersDidChange()
    }

    private func mcpServersDidChange() {
        claudeMCPStatus = [:]
        notice = "MCP 설정을 바꿨습니다. Claude 는 다음 전송부터, Codex 는 ‘다시 연결’ 후 적용됩니다."
    }

    /// 터미널에서 한 번 실행할 로그인 명령을 복사합니다. 앱은 로그인 자체를 하지 않습니다.
    func copyMCPLoginCommands(id: String) {
        guard let server = mcpServers.first(where: { $0.id == id }), let commands = server.loginCommands else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
        notice = "\(server.name) 로그인 명령을 복사했습니다. 터미널에 붙여 넣어 실행한 뒤 다시 보내세요."
    }

    func mcpStatusText(for server: MCPServer) -> String {
        var parts: [String] = []
        if let status = claudeMCPStatus[server.name] { parts.append("Claude " + MCPServerList.statusText(status)) }
        if let status = codexMCPStatus[server.name] { parts.append("Codex " + status) }
        return parts.isEmpty ? "미확인 (전송 후 표시)" : parts.joined(separator: " · ")
    }

    /// Codex app-server 에 MCP 서버 상태를 물어봅니다 (연결 직후).
    func refreshCodexMCPStatus() async {
        guard connection.isConnected, !enabledMCPServers.isEmpty else { codexMCPStatus = [:]; return }
        guard let result = try? await client.request("mcpServerStatus/list", params: [:], timeout: 20) else { return }
        var status: [String: String] = [:]
        for item in result["data"]?.arrayValue ?? result["servers"]?.arrayValue ?? [] {
            guard let name = item["name"]?.stringValue else { continue }
            let auth = item["authStatus"]?.stringValue ?? ""
            switch auth {
            case "oAuth", "bearerToken": status[name] = "로그인됨"
            case "notLoggedIn": status[name] = "로그인 필요"
            default: status[name] = "설정됨"
            }
        }
        codexMCPStatus = status
    }

    // MARK: 추천 설정

    static let recommendedClaudeAPIModel = "claude-sonnet-5-5"
    static let recommendedOpenAIAPIModel = "gpt-6.1-sol"
    /// 연결 관리 창에 보여 주는 요약 (이름, 값과 이유)
    static let recommendedSummary: [(String, String)] = [
        ("Claude 구독 모델", "계정 기본값 · 요금제에 맞는 모델을 자동으로 씁니다"),
        ("Claude API 모델", "Sonnet 5.5 · 품질과 비용의 균형이 좋습니다"),
        ("OpenAI API 모델", "GPT-6.1 Sol · 기본 모델입니다"),
        ("새 대화 예산", "$1 · 넘으면 멈춰서 안심입니다"),
        ("릴레이 횟수", "3회 · 대부분 이 안에서 끝납니다"),
        ("릴레이 자동 수정·빌드 확인", "켬 · 손이 덜 갑니다"),
        ("파일 수정 자동 허용", "끔 · 고치기 전에 내용을 확인합니다"),
    ]

    /// 검토자는 키가 있는 연결 중에서 고릅니다.
    private var recommendedReviewer: Provider? {
        availableReviewers.contains(.openAIAPI) ? .openAIAPI : availableReviewers.first
    }

    var usesRecommendedSettings: Bool {
        claudeModel.isEmpty && claudeEffort.isEmpty
            && claudeAPIModel == Self.recommendedClaudeAPIModel && claudeAPIEffort.isEmpty
            && openAIAPIModel == Self.recommendedOpenAIAPIModel && openAIAPIEffort.isEmpty
            && claudeAPIDefaultBudgetUSD == 1 && preferredNewConversationProvider == nil
            && relayMaxRounds == 3 && relayAutoFix && relayAutoBuild
            && !relayAutoApproveEdits && !autoApproveEdits
            && (recommendedReviewer == nil || relayReviewer == recommendedReviewer)
    }

    /// 무난한 값으로 맞춥니다. 키, 로그인, 작업 폴더, MCP, 로컬 모델은 건드리지 않습니다.
    func applyRecommendedSettings() {
        claudeModel = ""
        claudeEffort = ""
        claudeAPIModel = Self.recommendedClaudeAPIModel
        claudeAPIEffort = ""
        openAIAPIModel = Self.recommendedOpenAIAPIModel
        openAIAPIEffort = ""
        claudeAPIDefaultBudgetUSD = 1
        preferredNewConversationProvider = nil
        relayMaxRounds = 3
        relayAutoFix = true
        relayAutoBuild = true
        relayAutoApproveEdits = false
        autoApproveEdits = false
        if let reviewer = recommendedReviewer { relayReviewer = reviewer }
        notice = "추천 설정을 적용했습니다."
    }

    // MARK: 입력창

    /// 새 대화 화면으로 갑니다. 대화는 첫 메시지를 보내거나 파일을 붙일 때 만들어집니다.
    func startFreshConversation(provider: Provider? = nil) {
        guard !progress.isBusy else { return }
        startProvider = provider
        selectedID = nil
        entries = []
        resetTurn()
        notice = nil
    }

    /// 지금 쓸 수 있는 연결 (새 대화 메뉴)
    var startableProviders: [Provider] {
        (Self.isAppStoreBuild ? [Provider.claudeAPI, .openAIAPI] : [Provider.codex, .claude, .claudeAPI, .openAIAPI, .localLLM]).filter(isReady)
    }

    var apiKeyCount: Int { [claudeAPIKeyPresent, openAIAPIKeyPresent].filter { $0 }.count }

    /// 입력창이 보내는 곳: 지금 대화의 연결, 없으면 새 대화 화면에서 고른 연결.
    var composerProvider: Provider { selectedConversation?.provider ?? startProvider ?? defaultNewConversationProvider }

    /// 입력창의 대상에 작업 폴더가 있는지
    var composerHasWorkspace: Bool {
        if let conversation = selectedConversation { return conversation.hasWorkspace }
        let provider = composerProvider
        return !Self.isAppStoreBuild && !workspacePath.isEmpty && !provider.isDirectAPI && provider != .localLLM
    }

    var composerCanSend: Bool {
        let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
        guard hasContent else { return false }
        return selectedID == nil ? canStartAnyConversation : canSend
    }

    /// 지금 대화의 연결과 모델 이름 (입력창 오른쪽 칩)
    var composerModelLabel: String {
        let provider = composerProvider
        let model: String
        switch provider {
        case .claude: model = claudeModelName.isEmpty ? claudeModel : claudeModelName
        case .claudeAPI: model = claudeAPIModel
        case .openAIAPI: model = openAIAPIModel
        case .codex, .localLLM: model = ""
        }
        return model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
    }

    /// 입력창 릴레이 칩 글자
    var relayChipText: String {
        guard let relay else { return "릴레이" }
        switch relay.phase {
        case .implementing: return "릴레이 \(relay.round)/\(relay.maxRounds) 구현 중"
        case .reviewing: return "릴레이 \(relay.round)/\(relay.maxRounds) 검토 중"
        case .done, .stopped: return "릴레이"
        }
    }

    /// 대화가 없으면 만듭니다. 만들지 못하면 false (안내는 notice 에 있습니다).
    func ensureConversation() async -> Bool {
        if selectedID != nil { return true }
        let provider = composerProvider
        startProvider = nil
        await newConversation(provider: provider)
        return selectedID != nil
    }

    func sendFromComposer() async {
        guard await ensureConversation() else { return }
        await send()
    }

    func startRelayFromComposer() async {
        guard await ensureConversation() else { return }
        await startRelay()
    }

    // MARK: 첨부 파일 / 받은 파일

    /// 열기 창으로 첨부할 파일을 고릅니다 (PNG·JPEG·PDF·ZIP, 여러 개).
    func attachFiles() {
        guard selectedID != nil else { notice = "먼저 대화를 만들어 주세요."; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Attachment.allowedTypes
        panel.prompt = tr("첨부")
        panel.message = tr("PNG·JPEG·PDF·ZIP 파일을 다음 메시지에 붙입니다.")
        guard panel.runModal() == .OK else { return }
        addAttachments(urls: panel.urls)
    }

    /// 파일 URL 들을 첨부로 더합니다 (열기 창·드롭 공통). 앱 폴더로 바로 복사합니다.
    func addAttachments(urls: [URL]) {
        guard selectedProvider != .localLLM else { notice = "시험용 로컬 AI는 글로만 대화합니다."; return }
        guard let id = selectedID else { notice = "먼저 대화를 만들어 주세요."; return }
        var problems: [String] = []
        for url in urls {
            do { pendingAttachments.append(try attachmentStore.importFile(url, conversationID: id)) }
            catch { problems.append(error.localizedDescription) }
        }
        if !problems.isEmpty { notice = problems.joined(separator: " ") }
    }

    func removeAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// 클립보드의 파일이나 이미지를 첨부로 더합니다 (⌘⇧V). 스크린샷을 복사한 뒤 바로 붙일 때 씁니다.
    /// 이미지는 PNG 로 저장한 뒤 복사본으로 가져갑니다. 더한 개수를 돌려줍니다.
    @discardableResult
    func pasteAttachments(from pasteboard: NSPasteboard = .general) -> Int {
        guard selectedProvider != .localLLM else { notice = "시험용 로컬 AI는 글로만 대화합니다."; return 0 }
        guard selectedID != nil else { notice = "먼저 대화를 만들어 주세요."; return 0 }
        let before = pendingAttachments.count
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addAttachments(urls: urls)
        } else if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(tr("붙여넣은 이미지 \(formatter.string(from: Date())).png"))
            do {
                try png.write(to: temporary)
                addAttachments(urls: [temporary])
                try? FileManager.default.removeItem(at: temporary)
            } catch {
                notice = "클립보드 이미지를 저장하지 못했습니다: \(error.localizedDescription)"
            }
        } else {
            notice = "클립보드에 이미지나 파일이 없습니다."
        }
        return pendingAttachments.count - before
    }

    /// 턴이 끝난 뒤: 답변 속 ```file: 블록을 파일로 쓰고, ‘받은 파일’ 폴더의 새 파일을 항목으로 보여줍니다.
    private func collectReceivedFiles(conversationID id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        for entry in currentTurnEntries where entry.kind == .assistant {
            attachmentStore.writeFileBlocks(from: entry.text, conversationID: id)
        }
        let known = Set(conversations[index].receivedFiles.map(\.path))
        let fresh = attachmentStore.newReceivedFiles(for: id, known: known)
        guard !fresh.isEmpty else { return }
        conversations[index].receivedFiles += fresh
        if selectedID == id {
            for file in fresh {
                entries.append(ChatEntry(id: "file-\(file.id)", kind: .file, title: file.name, text: file.path, status: file.sizeText))
            }
        }
        persist()
    }

    func revealReceivedFile(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 이 대화의 ‘받은 파일’ 폴더를 Finder 로 엽니다 (없으면 만듭니다).
    func revealReceivedFolder() {
        guard let id = selectedID else { return }
        let folder = attachmentStore.outputsDirectory(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func openReceivedFile(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 다른 곳에 복사해 저장합니다 (샌드박스에서도 저장 창은 허용됩니다).
    func saveReceivedFile(path: String) {
        let source = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        panel.prompt = tr("저장")
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            notice = "저장했습니다: \(target.lastPathComponent)"
        } catch {
            notice = "저장 실패: \(error.localizedDescription)"
        }
    }

    /// 자동 허용이 허락되는 폴더: 작업 폴더와 이 대화의 받은 파일 폴더
    func autoApproveRoots(for conversation: StoredConversation) -> [String] {
        var roots: [String] = []
        if conversation.hasWorkspace { roots.append(conversation.workspacePath) }
        roots.append(attachmentStore.outputsDirectory(for: conversation.id).path)
        return roots
    }

    /// 모든 경로가 roots 중 하나의 안에 있는지 (심볼릭 링크·`..` 는 standardized 경로로 풀어 비교).
    static func pathsAreInside(_ paths: [String], roots: [String]) -> Bool {
        guard !paths.isEmpty, !roots.isEmpty else { return false }
        func normalized(_ path: String) -> String {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            return url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        }
        let rootPaths = roots.map(normalized)
        return paths.allSatisfy { path in
            let candidate = normalized(path)
            return rootPaths.contains { root in candidate == root || candidate.hasPrefix(root + "/") }
        }
    }

    // MARK: 자동 릴레이

    /// 릴레이에 쓸 수 있는 검토자(키가 저장된 API 연결)
    var availableReviewers: [Provider] {
        var list: [Provider] = []
        if claudeAPIKeyPresent { list.append(.claudeAPI) }
        if openAIAPIKeyPresent { list.append(.openAIAPI) }
        return list
    }

    /// 입력창의 작업 지시로 릴레이를 시작합니다. 구현자는 현재 대화의 AI, 검토자는 설정의 API 연결입니다.
    func startRelay() async {
        guard let conversation = selectedConversation else { notice = "먼저 대화를 만들어 주세요."; return }
        guard conversation.provider != .localLLM else { notice = "시험용 로컬 AI는 릴레이를 지원하지 않습니다."; return }
        let task = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { notice = "입력창에 작업 지시를 쓴 뒤 ‘릴레이 시작’을 누르세요."; return }
        guard availableReviewers.contains(relayReviewer) else { notice = "검토자로 쓸 \(relayReviewer.displayName) 키가 없습니다. 설정에서 키를 저장하세요."; return }
        guard !progress.isBusy, !relayIsActive else { return }
        relay = RelayState(conversationID: conversation.id, task: task, reviewer: relayReviewer, maxRounds: max(1, relayMaxRounds))
        entries.append(ChatEntry(id: "relay-start-\(UUID().uuidString)", kind: .activity,
                                 title: "릴레이 시작 · 구현 \(conversation.provider.displayName) → 검토 \(relayReviewer.displayName) · 최대 \(relay!.maxRounds)회",
                                 text: task, status: "진행 중"))
        await send()
        if !progress.isBusy && progress.state != .completed {
            finishRelay(phase: .stopped, summary: "구현자 전송 실패")
        }
    }

    func stopRelay() {
        relayReviewTask?.cancel()
        relayReviewTask = nil
        finishRelay(phase: .stopped, summary: "사용자가 중단")
        if progress.isBusy { Task { await interrupt() } }
    }

    private func finishRelay(phase: RelayState.Phase, summary: String) {
        guard var state = relay else { return }
        state.phase = phase
        state.summary = summary
        relay = state
        let status = phase == .done ? "완료" : "중단"
        // ‘릴레이 시작’ 항목도 같이 닫습니다.
        if let start = entries.lastIndex(where: { $0.id.hasPrefix("relay-start-") && $0.status == "진행 중" }) { entries[start].status = status }
        entries.append(ChatEntry(id: "relay-end-\(UUID().uuidString)", kind: .activity,
                                 title: state.statusText, text: "라운드 \(state.round)/\(state.maxRounds)에서 끝났습니다.", status: status))
        notice = state.statusText
        Notifier.notify(title: phase == .done ? "릴레이 완료" : "릴레이 중단", body: summary)
        persist()
    }

    /// 한 턴이 끝날 때 호출됩니다. 릴레이 구현 단계였다면 검토를 시작합니다.
    private func turnDidFinish(conversationID: String) {
        if conversations.first(where: { $0.id == conversationID })?.provider != .localLLM {
            collectReceivedFiles(conversationID: conversationID)
        }
        if !relayIsActive, let conversation = conversations.first(where: { $0.id == conversationID }) {
            let answer = entries.last { $0.kind == .assistant }?.text ?? ""
            Notifier.notify(title: progress.state == .completed ? "답변이 끝났습니다" : "턴이 \(progress.phase)",
                            body: conversation.title + (answer.isEmpty ? "" : " · " + String(answer.prefix(80))))
        }
        guard var state = relay, state.isActive, state.conversationID == conversationID, state.phase == .implementing else { return }
        guard progress.state == .completed else {
            finishRelay(phase: .stopped, summary: progress.state == .interrupted ? "구현 중단됨" : "구현 실패")
            return
        }
        state.phase = .reviewing
        relay = state
        relayReviewTask = Task { await runReviewStep() }
    }

    /// 이번 턴의 답변과 변경 내용을 모아 검토자에게 보내고, 결과에 따라 끝내거나 수정 요청을 자동으로 보냅니다.
    private func runReviewStep() async {
        guard let state = relay, state.phase == .reviewing,
              let cIndex = conversations.firstIndex(where: { $0.id == state.conversationID }) else { return }
        let conversation = conversations[cIndex]
        guard conversation.apiRemainingUSD > 0 else {
            finishRelay(phase: .stopped, summary: "작업 예산 소진 (예산 +$1 후 다시 시작)"); return
        }
        // 작업 폴더 대화면 먼저 빌드. 실패하면 검토자를 부르지 않고 오류를 바로 구현자에게 돌려보냅니다(비용·시간 절약).
        if relayAutoBuild, conversation.hasWorkspace {
            if buildCommandDraft.trimmingCharacters(in: .whitespaces).isEmpty { await refreshBuildCommand() }
            if !buildCommandDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                progress.phase = "릴레이 \(state.round)/\(state.maxRounds) · 빌드 확인 중"
                await runBuild()
                guard relay?.phase == .reviewing else { return }
                if let result = lastBuildResult, !result.succeeded, !result.cancelled {
                    let isLast = state.round >= state.maxRounds
                    entries.append(ChatEntry(id: "relay-build-\(UUID().uuidString)", kind: .activity,
                                             title: isLast ? "릴레이 · 빌드 실패 (라운드 \(state.round)/\(state.maxRounds), 마지막)"
                                                           : "릴레이 · 빌드 실패 → 수정 요청 (라운드 \(state.round)/\(state.maxRounds))",
                                             text: result.statusText, status: "빌드 실패"))
                    guard !isLast else {
                        finishRelay(phase: .done, summary: "최대 \(state.maxRounds)회 도달 · 빌드 실패 상태"); return
                    }
                    var next = state
                    next.round += 1
                    next.phase = .implementing
                    next.roundStarted = Date()
                    relay = next
                    insertBuildErrorsIntoDraft()
                    await send()
                    if !progress.isBusy && progress.state != .completed { finishRelay(phase: .stopped, summary: "수정 요청 전송 실패") }
                    return
                }
            }
        }
        let turnEntries = currentTurnEntries
        let answer = turnEntries.filter { $0.kind == .assistant }.map(\.text).joined(separator: "\n\n")
        var changes = turnEntries.filter { $0.kind == .approval || ($0.kind == .activity && ($0.title.hasPrefix("도구 ") || $0.title.hasPrefix("빌드 결과"))) }
            .map { "### \($0.title) [\($0.status)]\n\($0.text)" }.joined(separator: "\n\n")
        // 이번 라운드에 승인된 파일 변경은 실제 diff 로 보여줍니다 (명령으로 바뀐 파일은 기록이 없어 제외).
        let roundRecords = conversation.changeRecords.filter { $0.date >= state.roundStarted }
        if !roundRecords.isEmpty {
            changes += (changes.isEmpty ? "" : "\n\n") + "## 승인된 파일 변경 (diff)\n" + WorkspaceBackups.reviewDiffs(roundRecords)
        }
        let request = RelayPrompts.reviewRequest(task: state.task, answer: RelayPrompts.clip(answer, 12_000),
                                                 changes: RelayPrompts.clip(changes, 12_000), round: state.round, maxRounds: state.maxRounds)
        let entryID = "relay-review-\(UUID().uuidString)"
        entries.append(ChatEntry(id: entryID, kind: .activity, title: "검토자 의견 · \(state.reviewer.displayName) · 라운드 \(state.round)/\(state.maxRounds)",
                                 text: "", status: "검토 중"))
        progress.phase = state.statusText
        persist()

        var reviewText = ""
        var usage = ClaudeAPIUsage()
        var servedModel = ""
        var reviewAPIKey = ""
        do {
            let handler: @MainActor (ClaudeAPIEvent) -> Void = { [weak self] event in
                guard let self else { return }
                switch event {
                case .textDelta(_, let delta):
                    reviewText += delta
                    if let i = self.entries.firstIndex(where: { $0.id == entryID }) { self.entries[i].text = reviewText }
                case .usage(let latest): usage = latest
                case .started(let model, _): servedModel = model
                default: break
                }
            }
            switch state.reviewer {
            case .openAIAPI:
                guard let key = secrets.read(Self.openAIAPIKeyName), !key.isEmpty else { throw ClaudeAPIError.missingKey }
                reviewAPIKey = key
                let pricing = OpenAIPricing.forModel(openAIAPIModel)
                let maxTokens = min(8_000, max(1_024, Int(conversation.apiRemainingUSD / pricing.output * 1_000_000)))
                try await openAIClient.stream(OpenAIAPIRequest(model: openAIAPIModel, instructions: RelayPrompts.reviewerSystem,
                                                               input: [OpenAIAPIRequest.userItem(request)], maxOutputTokens: maxTokens,
                                                               effort: openAIAPIEffort), apiKey: key, onEvent: handler)
            default:
                guard let key = secrets.read(Self.claudeAPIKeyName), !key.isEmpty else { throw ClaudeAPIError.missingKey }
                reviewAPIKey = key
                let pricing = ClaudePricing.forModel(claudeAPIModel)
                let maxTokens = min(8_000, max(1_024, Int(conversation.apiRemainingUSD / pricing.output * 1_000_000)))
                try await apiClient.stream(ClaudeAPIRequest(model: claudeAPIModel, system: RelayPrompts.reviewerSystem,
                                                            messages: [["role": "user", "content": [["type": "text", "text": .string(request)]]]],
                                                            maxTokens: maxTokens, effort: claudeAPIEffort), apiKey: key, onEvent: handler)
            }
        } catch is CancellationError {
            return
        } catch let error as ClaudeAPIError where error == .cancelled {
            return
        } catch {
            if let i = entries.firstIndex(where: { $0.id == entryID }) { entries[i].status = "실패" }
            finishRelay(phase: .stopped, summary: "검토 실패: \(APIDiagnostics.safeError(error, apiKey: reviewAPIKey).localizedDescription)")
            return
        }
        guard relay?.phase == .reviewing else { return }
        // 검토 비용은 같은 대화의 작업 예산에 합산합니다.
        let cost = (state.reviewer == .openAIAPI ? OpenAIPricing.forModel(servedModel) : ClaudePricing.forModel(servedModel)).estimate(usage)
        if let i = conversations.firstIndex(where: { $0.id == state.conversationID }) { conversations[i].apiSpentUSD += cost }
        let approved = RelayPrompts.isApproved(reviewText)
        if let i = entries.firstIndex(where: { $0.id == entryID }) { entries[i].status = approved ? "승인" : "수정 필요" }
        if approved {
            finishRelay(phase: .done, summary: "검토자 승인 (라운드 \(state.round))")
            return
        }
        guard state.round < state.maxRounds else {
            finishRelay(phase: .done, summary: "최대 \(state.maxRounds)회 도달 · 마지막 검토 의견을 확인하세요")
            return
        }
        draft = RelayPrompts.fixRequest(review: reviewText, round: state.round, maxRounds: state.maxRounds)
        guard relayAutoFix else {
            // 검토만 받기: 수정 요청을 입력창에 넣어 두고 사용자가 보내도록 합니다.
            finishRelay(phase: .done, summary: "검토 의견을 입력창에 넣었습니다 · 보내기를 누르면 수정 요청")
            return
        }
        var next = state
        next.round += 1
        next.phase = .implementing
        next.roundStarted = Date()
        relay = next
        await send()
        if !progress.isBusy && progress.state != .completed {
            finishRelay(phase: .stopped, summary: "수정 요청 전송 실패")
        }
    }

    /// 승인. 파일 변경이면 먼저 원본을 백업합니다.
    func approve(entryID: String) {
        guard let approval = pendingApprovals.removeValue(forKey: entryID) else { return }
        guard let conversation = selectedConversation else { return }
        var records: [ChangeRecord] = []
        let backups = WorkspaceBackups(directory: store.backupDirectory(for: conversation.id))
        for path in approval.filePaths {
            let absolute = path.hasPrefix("/") ? path : (conversation.workspacePath as NSString).appendingPathComponent(path)
            do { records.append(try backups.backup(path: absolute, tool: approval.tool)) }
            catch { appendLog("!", "백업 실패 \(absolute): \(error.localizedDescription)") }
        }
        switch approval.provider {
        case .claude: claude.respondPermission(requestID: approval.requestID, allow: true, input: approval.input)
        case .codex: client.respondApproval(requestID: approval.requestID, decision: "accept")
        default: break
        }
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            entries[index].isPendingApproval = false
            entries[index].status = "허용됨"
        }
        if let cIndex = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[cIndex].changeRecords.append(contentsOf: records)
        }
        for record in records {
            entries.append(ChatEntry(id: "change-\(record.id)", kind: .activity,
                                     title: "파일 변경 백업 · \((record.path as NSString).lastPathComponent)",
                                     text: record.path + (record.backupPath == nil ? " (새 파일)" : ""), status: "되돌리기 가능",
                                     changeRecordID: record.id))
        }
        progress.phase = "허용됨: \(approval.tool)"
        persist()
    }

    func deny(entryID: String) {
        guard let approval = pendingApprovals.removeValue(forKey: entryID) else { return }
        switch approval.provider {
        case .claude: claude.respondPermission(requestID: approval.requestID, allow: false, input: approval.input, message: "사용자가 거부했습니다. 다른 방법을 제안하거나 이유를 물어보세요.")
        case .codex: client.respondApproval(requestID: approval.requestID, decision: "decline")
        default: break
        }
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            entries[index].isPendingApproval = false
            entries[index].status = "거부됨"
        }
        progress.phase = "거부됨: \(approval.tool)"
        persist()
    }

    /// 턴이 끝났는데 답하지 않은 승인이 남아 있으면 만료 처리합니다 (CLI 쪽은 이미 정리됨).
    private func expirePendingApprovals() {
        guard !pendingApprovals.isEmpty else { return }
        for (entryID, _) in pendingApprovals {
            if let index = entries.firstIndex(where: { $0.id == entryID }) {
                entries[index].isPendingApproval = false
                entries[index].status = "만료"
            }
        }
        pendingApprovals.removeAll()
    }

    func changeRecord(id: String) -> ChangeRecord? {
        selectedConversation?.changeRecords.first { $0.id == id }
    }

    /// 승인했던 파일 변경을 백업으로 되돌립니다.
    func revert(changeRecordID: String) {
        guard let cIndex = conversations.firstIndex(where: { $0.id == selectedID }),
              let rIndex = conversations[cIndex].changeRecords.firstIndex(where: { $0.id == changeRecordID }) else { return }
        let record = conversations[cIndex].changeRecords[rIndex]
        guard !record.reverted else { return }
        let backups = WorkspaceBackups(directory: store.backupDirectory(for: conversations[cIndex].id))
        do {
            try backups.revert(record)
            conversations[cIndex].changeRecords[rIndex].reverted = true
            if let eIndex = entries.firstIndex(where: { $0.changeRecordID == changeRecordID }) {
                entries[eIndex].status = "되돌림"
            }
            notice = "되돌렸습니다: \(record.path)"
        } catch {
            notice = "되돌리기 실패: \(error.localizedDescription)"
        }
        persist()
    }

    // MARK: 저장

    private func loadCached(_ id: String) {
        let messages = conversations.first { $0.id == id }?.messages ?? []
        entries = messages.map {
            ChatEntry(id: $0.id, kind: $0.role, title: $0.title, text: $0.text, status: $0.status,
                      changeRecordID: $0.changeRecordID, attachmentNames: $0.attachmentNames ?? [], attachmentPaths: $0.attachmentPaths ?? [])
        }
    }

    private func schedulePersistence() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.persistenceTask = nil
            self.persist()
        }
    }

    private func persist() {
        if let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].messages = entries.map {
                StoredMessage(id: $0.id, role: $0.kind, title: $0.title, text: $0.text,
                              status: $0.isPendingApproval ? "만료" : $0.status, changeRecordID: $0.changeRecordID,
                              attachmentNames: $0.attachmentNames.isEmpty ? nil : $0.attachmentNames,
                              attachmentPaths: $0.attachmentPaths.isEmpty ? nil : $0.attachmentPaths)
            }
            conversations[index].updatedAt = Date()
        }
        store.save(conversations)
    }

    private func resetTurn() {
        progress = TurnProgress()
        turnStartIndex = nil
        tokenSummary = ""
    }

    private func appendLog(_ direction: String, _ text: String) {
        eventLog.append(LogLine(direction: direction, text: text))
        if eventLog.count > 600 { eventLog.removeFirst(eventLog.count - 600) }
    }

    func clearLog() { eventLog.removeAll() }
}
