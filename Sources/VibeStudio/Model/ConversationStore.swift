import CryptoKit
import Foundation

/// 대화를 어느 AI 연결로 진행하는지. 기존 저장 파일에 값이 없으면 codex 로 읽습니다.
enum Provider: String, Codable {
    case codex, claude, claudeAPI, openAIAPI, localLLM

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .claudeAPI: return "Claude API"
        case .openAIAPI: return "OpenAI API"
        case .localLLM: return tr("로컬 AI (MLX)")
        }
    }

    /// 사용자 API 키로 직접 호출하는 연결인지 (예산·키체인 공통 처리 대상)
    var isDirectAPI: Bool { self == .claudeAPI || self == .openAIAPI }
}

/// 화면에 보이는 대화 한 줄 (사용자 말, 답변, 중간 활동, 오류)
struct ChatEntry: Identifiable, Equatable {
    enum Kind: String, Codable { case user, assistant, activity, error, approval, file }
    let id: String
    var kind: Kind
    var title: String = ""
    var text: String
    var status: String = ""
    var isStreaming = false
    /// 승인 카드: 아직 답하지 않았으면 true (허용/거부 버튼 표시)
    var isPendingApproval = false
    /// 파일 변경 기록 ID (되돌리기 버튼용)
    var changeRecordID: String?
    /// 사용자 메시지에 붙인 첨부 파일 이름 (표시용). `.file` 항목은 text 가 파일 경로입니다.
    var attachmentNames: [String] = []
    /// 첨부 복사본 경로 (이미지 미리보기용). 이름과 같은 순서.
    var attachmentPaths: [String] = []
}

/// 승인 직전에 떠 둔 파일 백업. 되돌리기에 씁니다.
struct ChangeRecord: Codable, Identifiable, Equatable {
    var id: String
    var path: String
    /// 원본 백업 파일. nil 이면 승인 시점에 파일이 없었음(새 파일) → 되돌리기는 파일 삭제.
    var backupPath: String?
    var tool: String
    var date: Date
    var reverted = false
}

/// 디스크에 저장하는 최소 정보. 서버의 thread id 만 있으면 재실행 후 복원할 수 있습니다.
struct StoredMessage: Codable, Identifiable {
    var id: String
    var role: ChatEntry.Kind
    var title: String = ""
    var text: String
    var status: String = ""
    var changeRecordID: String?
    var attachmentNames: [String]?
    var attachmentPaths: [String]?
}

/// 대화의 토큰 사용량. 화면 표시용이며 청구 금액이 아닙니다.
struct ConversationUsage: Codable, Equatable {
    /// 마지막 턴이 끝났을 때 대화가 차지한 토큰 수
    var contextTokens = 0
    /// 모델이 한 번에 다룰 수 있는 토큰 수. 모르면 nil.
    var contextWindow: Int?
    /// 지금까지 보낸·받은 토큰 합계. 메시지마다 앞선 대화도 다시 보내므로 컨텍스트보다 빨리 늘어납니다.
    var totalInputTokens = 0
    var totalOutputTokens = 0

    var hasData: Bool { contextTokens > 0 || totalInputTokens > 0 || totalOutputTokens > 0 }

    var contextPercent: Int? {
        guard let contextWindow, contextWindow > 0, contextTokens > 0 else { return nil }
        return min(100, Int((Double(contextTokens) / Double(contextWindow) * 100).rounded(.up)))
    }
}

/// 모델별 컨텍스트 크기(토큰). 2026-10 기준 Anthropic·OpenAI 공식 문서 값입니다. 표에 없으면 비율을 보여주지 않습니다.
enum ModelContextWindow {
    private static let table: [String: Int] = [
        "claude-fable-5-1": 1_000_000, "claude-fable-5": 1_000_000,
        "claude-opus-5-5": 1_000_000, "claude-opus-5": 1_000_000,
        "claude-sonnet-5-5": 1_000_000, "claude-sonnet-5": 1_000_000,
        "claude-haiku-5-5": 1_000_000, "claude-haiku-4-5": 200_000,
        "gpt-6.1-sol": 1_050_000, "gpt-6.1-terra": 1_050_000,
        "gpt-6-sol": 1_050_000, "gpt-6-luna": 1_050_000, "gpt-6-astra": 1_050_000,
    ]

    static func tokens(for model: String) -> Int? { table[model] }
}

struct StoredConversation: Codable, Identifiable {
    var id: String          // Codex thread id 또는 Claude session id(UUID)
    var provider: Provider
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredMessage]
    /// Claude 전용. CLI 기록에 세션이 실제로 만들어졌으면 true → 다음 실행은 `--resume`, 아니면 `--session-id`.
    var claudeSessionReady: Bool
    /// Claude API 전용. Messages API 형식 그대로의 대화(thinking 블록 포함). 다음 턴에 통째로 다시 보냅니다.
    var apiTranscript: [JSONValue]
    /// Claude API 전용 작업 예산(달러). 재시도·검토·인계도 같은 예산에 합산합니다.
    var apiBudgetUSD: Double
    /// Claude API 전용 누적 추정 비용(달러). 실제 청구와 다를 수 있습니다.
    var apiSpentUSD: Double
    /// 작업 폴더(절대 경로). 비어 있으면 텍스트 대화만. 대화를 만들 때 정해지고 바꿀 수 없습니다.
    var workspacePath: String
    /// 승인한 파일 변경의 백업 기록 (되돌리기용)
    var changeRecords: [ChangeRecord]
    /// AI 가 사용자에게 돌려준 파일 (outputs/<대화>/ 폴더)
    var receivedFiles: [ReceivedFile]
    /// 토큰 사용량
    var usage = ConversationUsage()

    var hasWorkspace: Bool { !workspacePath.isEmpty }

    init(id: String, provider: Provider = .codex, title: String, createdAt: Date, updatedAt: Date,
         messages: [StoredMessage], claudeSessionReady: Bool = false,
         apiTranscript: [JSONValue] = [], apiBudgetUSD: Double = 1.0, apiSpentUSD: Double = 0,
         workspacePath: String = "", changeRecords: [ChangeRecord] = [], receivedFiles: [ReceivedFile] = []) {
        self.workspacePath = workspacePath
        self.changeRecords = changeRecords
        self.receivedFiles = receivedFiles
        self.id = id
        self.provider = provider
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.claudeSessionReady = claudeSessionReady
        self.apiTranscript = apiTranscript
        self.apiBudgetUSD = apiBudgetUSD
        self.apiSpentUSD = apiSpentUSD
    }

    var apiRemainingUSD: Double { max(0, apiBudgetUSD - apiSpentUSD) }

    /// 예전 파일(provider 없음)도 그대로 읽히도록 빠진 키는 기본값으로 채웁니다.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .codex
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messages = try container.decode([StoredMessage].self, forKey: .messages)
        claudeSessionReady = try container.decodeIfPresent(Bool.self, forKey: .claudeSessionReady) ?? false
        apiTranscript = try container.decodeIfPresent([JSONValue].self, forKey: .apiTranscript) ?? []
        apiBudgetUSD = try container.decodeIfPresent(Double.self, forKey: .apiBudgetUSD) ?? 1.0
        apiSpentUSD = try container.decodeIfPresent(Double.self, forKey: .apiSpentUSD) ?? 0
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath) ?? ""
        changeRecords = try container.decodeIfPresent([ChangeRecord].self, forKey: .changeRecords) ?? []
        receivedFiles = try container.decodeIfPresent([ReceivedFile].self, forKey: .receivedFiles) ?? []
        usage = try container.decodeIfPresent(ConversationUsage.self, forKey: .usage) ?? ConversationUsage()
    }
}

/// 대화 하나를 못 읽어도 전체 읽기가 실패하지 않게 감쌉니다.
private struct LossyConversation: Decodable {
    let value: StoredConversation?
    init(from decoder: Decoder) { value = try? StoredConversation(from: decoder) }
}

/// ~/Library/Application Support/VibeStudio/conversations.json 에 저장합니다.
/// 인증 정보는 절대 여기에 두지 않습니다.
final class ConversationStore {
    let directory: URL
    let fileURL: URL
    /// Codex/Claude 대화의 기본 작업 폴더. 빈 폴더는 홈 폴더 전체 읽기를 차단하는 경계가 아닙니다.
    let sandboxDirectory: URL

    /// - Parameter directory: 비우면 Application Support/VibeStudio. 테스트는 임시 폴더를 넘깁니다.
    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? base.appendingPathComponent("VibeStudio", isDirectory: true)
        fileURL = self.directory.appendingPathComponent("conversations.json")
        let directory = self.directory
        sandboxDirectory = directory.appendingPathComponent("empty-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandboxDirectory, withIntermediateDirectories: true)
    }

    /// 읽지 못한 대화가 있을 때 사용자에게 보여 줄 안내. 없으면 nil.
    private(set) var loadWarning: String?

    /// 대화 하나를 못 읽어도 나머지는 살립니다. 다음 저장이 원본을 덮어쓰기 전에, 못 읽은 원본 파일을 따로 보관합니다.
    func load() -> [StoredConversation] {
        loadWarning = nil
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try? decoder.decode([LossyConversation].self, from: data)
        let conversations = items?.compactMap(\.value) ?? []
        if let items, items.count == conversations.count {
            if !conversations.isEmpty { saveDailySnapshot(data) }
            return conversations
        }
        let rescued = preserveUnreadableFile(data)
        let what = items.map { "대화 \($0.count - conversations.count)개를" } ?? "대화 기록을"
        loadWarning = "\(what) 읽지 못했습니다. 원본은 지우지 않고 \(rescued)에 보관했습니다. 최신 버전의 앱에서 다시 열어 보세요."
        return conversations
    }

    /// 읽지 못한 원본을 내용별 이름으로 한 번만 보관합니다. 보관한 파일 이름을 돌려줍니다.
    private func preserveUnreadableFile(_ data: Data) -> String {
        let digest = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent("conversations.unreadable-\(digest).json")
        if !FileManager.default.fileExists(atPath: target.path) { try? data.write(to: target, options: .atomic) }
        return target.lastPathComponent
    }

    /// 앱을 켤 때 하루 한 번 기록을 복사해 최근 7개를 남깁니다. 옛날 앱이 기록을 덮어써도 복구할 수 있게 합니다.
    private func saveDailySnapshot(_ data: Data) {
        let folder = directory.appendingPathComponent("conversation-history", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let target = folder.appendingPathComponent("conversations-\(formatter.string(from: Date())).json")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
        let snapshots = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("conversations-") && $0.hasSuffix(".json") }.sorted()
        for name in snapshots.dropLast(7) { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
    }

    /// 승인 전 파일 백업 폴더 (대화별).
    func backupDirectory(for conversationID: String) -> URL {
        let safe = conversationID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("backups", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
    }

    func save(_ conversations: [StoredConversation]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(conversations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
