import Foundation

/// 입문자용 쉬운 문구 모음. 도구 이름 번역, 승인 카드 설명, 빈 대화 예시 질문.
enum FriendlyText {
    /// 도구 이름 → 쉬운 이름. 모르면 원래 이름 그대로.
    static func toolLabel(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "__").map(String.init)
            if parts.count >= 3 { return "\(parts[1]) 도구 · \(parts[2...].joined(separator: "__"))" }
            return name
        }
        switch name {
        case "Read": return "파일 읽기"
        case "Write": return "파일 만들기·쓰기"
        case "Edit", "MultiEdit": return "파일 고치기"
        case "Bash": return "명령 실행"
        case "Glob": return "파일 찾기"
        case "Grep": return "내용 검색"
        case "LS": return "폴더 보기"
        case "WebFetch": return "웹 페이지 읽기"
        case "WebSearch": return "웹 검색"
        case "NotebookEdit": return "노트북 고치기"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "할 일 정리"
        case "Agent", "Task": return "보조 작업 실행"
        case "commandExecution": return "명령 실행"
        case "fileChange", "applyPatch": return "파일 고치기"
        default: return name
        }
    }

    /// 활동 항목 제목(예: "도구 Read", "도구 호출 시도 Bash", "승인 요청 · Write")을 쉬운 제목으로.
    static func activityTitle(_ title: String) -> String {
        for prefix in ["도구 호출 시도 ", "도구 ", "승인 요청 · "] where title.hasPrefix(prefix) {
            let raw = String(title.dropFirst(prefix.count))
            let label = toolLabel(raw)
            let head = prefix == "승인 요청 · " ? "허용할까요? " : (prefix == "도구 호출 시도 " ? "도구 없음 · " : "")
            return label == raw ? title : "\(tr(head))\(tr(label)) (\(raw))"
        }
        return title
    }

    /// 승인 카드 아래 한 줄 설명
    static func approvalHint(tool: String) -> String {
        switch tool {
        case "Write": return tr("AI 가 파일을 새로 만들거나 통째로 바꾸려고 합니다. 허용하면 원본은 자동으로 백업되고, 나중에 ‘되돌리기’로 복구할 수 있습니다.")
        case "Edit", "MultiEdit", "fileChange", "applyPatch": return tr("AI 가 파일 일부를 고치려고 합니다. 빨간 줄이 지워지고 초록 줄이 들어갑니다. 허용하면 원본은 백업됩니다.")
        case "Bash", "commandExecution": return tr("AI 가 터미널 명령을 실행하려고 합니다. 명령 내용을 읽어 보고, 모르는 명령이면 거부해도 괜찮습니다. 명령으로 바뀐 파일은 되돌리기 대상이 아닙니다.")
        case "WebFetch", "WebSearch": return tr("AI 가 인터넷에서 자료를 읽으려고 합니다.")
        default:
            if tool.hasPrefix("mcp__") { return tr("연결한 MCP 서버의 도구를 쓰려고 합니다. 읽기 위주 서버면 연결 관리에서 ‘도구 자동 허용’을 켜 두면 매번 묻지 않습니다.") }
            return tr("AI 가 이 도구를 쓰려고 합니다. 내용을 확인한 뒤 허용하거나 거부하세요.")
        }
    }

    /// 빈 대화에서 보여 줄 예시 질문
    static func examplePrompts(provider: Provider, hasWorkspace: Bool) -> [String] {
        koreanPrompts(provider: provider, hasWorkspace: hasWorkspace).map(tr)
    }

    private static func koreanPrompts(provider: Provider, hasWorkspace: Bool) -> [String] {
        if hasWorkspace {
            return [
                "이 프로젝트가 어떤 구조인지 초보자에게 설명하듯 알려 줘",
                "빌드가 실패하는데 원인을 찾아서 고쳐 줘",
                "이 폴더에서 가장 복잡한 파일 하나를 골라 읽기 쉽게 정리해 줘",
                "지금 상태를 바탕으로 다음에 할 일 3가지를 제안해 줘",
            ]
        }
        switch provider {
        case .localLLM:
            return ["짧은 자기소개를 한국어로 해 줘", "이 글을 두 문장으로 요약해 줘: (글을 붙여 넣으세요)"]
        case .codex, .claude:
            return [
                "SwiftUI 로 간단한 할 일 앱을 만들려면 어디서 시작해야 해?",
                "이 오류 메시지가 무슨 뜻인지 쉽게 설명해 줘: (오류를 붙여 넣으세요)",
                "첨부한 PDF 의 핵심만 5줄로 요약해 줘",
            ]
        case .claudeAPI, .openAIAPI:
            return [
                "앱 아이디어를 말할 테니 화면 구성을 제안해 줘",
                "첨부한 스크린샷의 UI 에서 고칠 점을 알려 줘",
                "이 글을 더 친절한 말투로 다듬어 줘: (글을 붙여 넣으세요)",
            ]
        }
    }

    /// 연결 관리 창의 한 줄 설명
    static var codexBoxHint: String { tr("ChatGPT 구독으로 쓰는 코딩 AI") }
    static var claudeBoxHint: String { tr("Claude 구독(Pro/Max)으로 쓰는 AI") }
    static var apiBoxHint: String { tr("본인 키로 쓰는 연결 · 쓴 만큼 청구") }
    static var workspaceBoxHint: String { tr("AI 가 읽고 고칠 프로젝트 폴더") }
    static var relayHint: String { tr("릴레이: 한 AI 가 만들고, 다른 AI 가 검토해서 고칠 점을 돌려주는 걸 자동으로 반복합니다. 횟수와 예산 안에서만 돕니다.") }
    static var composerHint: String { tr("Enter 보내기 · Shift+Enter 줄바꿈 · + 또는 드래그로 첨부 · 복사한 이미지는 ⌘V · 도움말은 ⌘?") }
}
