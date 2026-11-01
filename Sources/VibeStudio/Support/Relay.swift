import Foundation

/// 자동 릴레이: 구현자(현재 대화의 AI) → 검토자(API 키 연결) → 구현자 수정 → … 을 최대 N회 자동으로 돕니다.
/// 사용자는 ‘릴레이 시작’ 한 번만 누르고, 명령 실행 승인만 직접 합니다(파일 수정은 스위치로 자동 허용 가능).
struct RelayState: Equatable {
    enum Phase: String { case implementing, reviewing, done, stopped }
    var conversationID: String
    var task: String
    var reviewer: Provider
    var maxRounds: Int
    var round = 1
    var phase: Phase = .implementing
    var summary = ""
    /// 이번 라운드의 구현 턴이 시작된 시각. 이후 승인된 파일 변경만 검토자에게 diff 로 보냅니다.
    var roundStarted = Date()

    var isActive: Bool { phase == .implementing || phase == .reviewing }
    var statusText: String {
        switch phase {
        case .implementing: return "릴레이 \(round)/\(maxRounds) · 구현 중"
        case .reviewing: return "릴레이 \(round)/\(maxRounds) · \(reviewer.displayName) 검토 중"
        case .done: return "릴레이 완료 · \(summary)"
        case .stopped: return "릴레이 중단 · \(summary)"
        }
    }
}

enum RelayPrompts {
    static let reviewerSystem =
        "당신은 꼼꼼한 코드·문서 검토자입니다. 사용자의 작업 지시와 구현자의 답변(및 변경 내용)을 받으면, " +
        "지시를 빠뜨리거나 잘못 이해한 부분, 버그·위험·누락을 구체적으로 지적합니다. " +
        "수정이 필요 없으면 첫 줄에 정확히 APPROVED 라고만 쓰고 한 줄 이유를 덧붙입니다. " +
        "수정이 필요하면 첫 줄에 NEEDS_CHANGES 라고 쓰고, 무엇을 어떻게 고칠지 번호를 매겨 짧고 명확하게 씁니다. 사용자가 쓴 언어로 답하세요."

    static func reviewRequest(task: String, answer: String, changes: String, round: Int, maxRounds: Int) -> String {
        var text = "[라운드 \(round)/\(maxRounds)]\n\n## 사용자의 작업 지시\n\(task)\n\n## 구현자의 답변\n\(answer.isEmpty ? "(답변 텍스트 없음)" : answer)"
        if !changes.isEmpty { text += "\n\n## 이번 라운드의 변경·실행 내용\n\(changes)" }
        text += "\n\n위 기준으로 검토하세요."
        return text
    }

    static func fixRequest(review: String, round: Int, maxRounds: Int) -> String {
        tr("검토자 의견(라운드 \(round)/\(maxRounds))입니다. 타당한 지적은 반영해 수정하고, 동의하지 않는 지적은 이유를 짧게 쓰세요. 바꾼 내용을 마지막에 요약하세요.\n\n\(review)")
    }

    /// 첫 줄(또는 앞부분)에 APPROVED 가 있으면 승인으로 봅니다. NEEDS_CHANGES 가 먼저 나오면 수정 필요.
    static func isApproved(_ review: String) -> Bool {
        let head = review.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).uppercased()
        if head.contains("NEEDS_CHANGES") { return false }
        return head.hasPrefix("APPROVED") || head.contains("\nAPPROVED") || head.contains("APPROVED")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…(생략, \(text.count - limit)자)" : text
    }
}
