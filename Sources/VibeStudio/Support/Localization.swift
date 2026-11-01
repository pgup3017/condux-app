import AppKit
import Foundation

/// 화면 언어. 내부 로직과 저장 형식은 한국어 그대로 두고, 화면에 그릴 때만 `tr()` 로 번역합니다.
/// 그래서 기존 대화 기록과 앞글자 비교 코드(`hasPrefix("도구 ")` 등)는 영향을 받지 않습니다.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, korean, english
    var id: String { rawValue }
    /// 이름은 항상 그 언어로 보여 줍니다.
    var label: String {
        switch self {
        case .system: return tr("시스템 설정 따르기")
        case .korean: return "한국어"
        case .english: return "English"
        }
    }
}

/// 밝은·어두운 화면. 처음에는 Condux 의 차콜 화면(어둡게)으로 시작합니다.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let defaultsKey = "appAppearance"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return tr("시스템 설정 따르기")
        case .light: return tr("밝게")
        case .dark: return tr("어둡게")
        }
    }

    /// 앱을 켤 때 쓸 값. 캡처할 때는 `CONDUX_APPEARANCE` 로 정합니다.
    static var current: AppAppearance {
        let stored = ProcessInfo.processInfo.environment["CONDUX_APPEARANCE"] ?? UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return AppAppearance(rawValue: stored) ?? .dark
    }

    /// 창·시트·팝오버·제목 줄까지 앱 전체에 적용합니다. 테스트처럼 NSApp 이 없으면 아무것도 하지 않습니다.
    func apply() {
        let application: NSApplication? = NSApp
        switch self {
        case .system: application?.appearance = nil
        case .light: application?.appearance = NSAppearance(named: .aqua)
        case .dark: application?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum Tr {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var preference: AppLanguage = {
        // 테스트는 항상 한국어로 돕니다. 시스템 언어에 따라 결과가 달라지면 안 됩니다.
        if NSClassFromString("XCTestCase") != nil { return .korean }
        if let forced = ProcessInfo.processInfo.environment["CONDUX_LANGUAGE"] { return forced == "en" ? .english : .korean }
        return AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    }()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func set(_ language: AppLanguage) {
        lock.withLock { preference = language; cache = [:] }
    }

    static var isEnglish: Bool {
        switch lock.withLock({ preference }) {
        case .english: return true
        case .korean: return false
        case .system: return !(Locale.preferredLanguages.first ?? "ko").hasPrefix("ko")
        }
    }

    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "ko_KR") }

    // MARK: 번역표

    private struct Pattern { let regex: NSRegularExpression; let english: String }

    private static let table: (exact: [String: String], patterns: [Pattern]) = {
        var exact: [String: String] = [:]
        var templates: [(String, String)] = []
        for line in Translations.text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.components(separatedBy: " ==> ")
            guard parts.count == 2 else { continue }
            let korean = parts[0].replacingOccurrences(of: "\\n", with: "\n")
            let english = parts[1].replacingOccurrences(of: "\\n", with: "\n")
            if korean.contains("{}") { templates.append((korean, english)) } else { exact[korean] = english }
        }
        // 글자가 많은 틀부터 맞춰 봅니다. 구체적인 문장이 짧은 틀에 먹히지 않게 합니다.
        templates.sort { $0.0.replacingOccurrences(of: "{}", with: "").count > $1.0.replacingOccurrences(of: "{}", with: "").count }
        let patterns = templates.compactMap { korean, english -> Pattern? in
            let body = korean.components(separatedBy: "{}").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.+?)")
            guard let regex = try? NSRegularExpression(pattern: "^" + body + "$", options: [.dotMatchesLineSeparators]) else { return nil }
            return Pattern(regex: regex, english: english)
        }
        return (exact, patterns)
    }()

    /// 번역합니다. 표에 없으면 ‘ · ’ 로 나눈 조각별로 시도하고, 그래도 없으면 원문을 그대로 돌려줍니다.
    static func translate(_ text: String) -> String {
        guard isEnglish, !text.isEmpty, text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { return text }
        if let cached = lock.withLock({ cache[text] }) { return cached }
        let result = lookup(text)
        lock.withLock { cache[text] = result }
        return result
    }

    private static func lookup(_ text: String) -> String {
        if let exact = table.exact[text] { return exact }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != text, let exact = table.exact[trimmed] {
            return (text.hasPrefix(" ") ? " " : "") + exact + (text.hasSuffix(" ") ? " " : "")
        }
        // ‘도구 없음 · ’ 처럼 뒤에 이어 붙일 조각은 틀보다 먼저 봅니다. ‘도구 {}’ 같은 짧은 틀에 먹히지 않게 합니다.
        if text.hasSuffix(" · ") { return translate(String(text.dropLast(3))) + " · " }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in table.patterns {
            guard let match = pattern.regex.firstMatch(in: text, range: range) else { continue }
            var captures: [String] = []
            for index in 1..<match.numberOfRanges {
                if let r = Range(match.range(at: index), in: text) { captures.append(translate(String(text[r]))) }
            }
            return fill(pattern.english, with: captures)
        }
        if text.contains(" · ") {
            return text.components(separatedBy: " · ").map(translate).joined(separator: " · ")
        }
        return text
    }

    /// `{}` 는 순서대로, `{1}` `{2}` 는 번호대로 채웁니다.
    private static func fill(_ template: String, with captures: [String]) -> String {
        var result = template
        for (index, capture) in captures.enumerated() {
            result = result.replacingOccurrences(of: "{\(index + 1)}", with: capture)
        }
        var next = captures.makeIterator()
        while let range = result.range(of: "{}"), let capture = next.next() {
            result.replaceSubrange(range, with: capture)
        }
        return result
    }
}

/// 화면에 보이는 문구를 현재 언어로 바꿉니다.
func tr(_ text: String) -> String { Tr.translate(text) }

// swiftlint:disable line_length
enum Translations {
    /// `한국어 ==> English`. `{}` 는 바뀌는 값입니다. AI 에게 보내는 지시문과 원문 로그는 번역하지 않습니다.
    static let text = #"""
(내용 없음) ==> (empty)
(새 파일) ==> (new file)
(재시도 중) ==> (retrying)
· 로그인됨 ==> · signed in
· 없으면 글 대화만 ==> · text chat only without one
· 연결됨 ==> · connected
로 새 대화 ==>  – new conversation
## 나 ==> ## Me
(빌드 명령: {}) ==> (Build command: {})
(이진 파일) ==> (binary file)
- 만든 날짜: {} ==> - Created: {}
- 연결: {} ==> - Connection: {}
- 예상 비용: ${} / 예산 ${} ==> - Estimated cost: ${} / budget ${}
- 작업 폴더: {} ==> - Project folder: {}
5시간 창 {} ==> 5-hour window {}
7일 창 {} ==> 7-day window {}
> **받은 파일** · {} · {} ==> > **Received file** · {} · {}
{} ${} / 예산 ${} ==> {} ${} / budget ${}
AI 가 돌려준 파일은 대화에 항목으로 나타나고 열기·Finder에서 보기·저장이 됩니다. 이미지는 미리보기가 뜹니다. ==> Files the AI hands back appear in the conversation. You can open, show in Finder, or save them. Images get a preview.
AI 가 이 도구를 쓰려고 합니다. 내용을 확인한 뒤 허용하거나 거부하세요. ==> The AI wants to use this tool. Check the details, then allow or deny.
AI 가 인터넷에서 자료를 읽으려고 합니다. ==> The AI wants to read something on the internet.
AI 가 일할 프로젝트 폴더 고르기 (선택) ==> Choose a project folder for the AI (optional)
AI 가 읽고 (승인 후) 고칠 수 있는 프로젝트 폴더를 고르세요. 새 대화부터 적용됩니다. ==> Choose a project folder the AI can read and, with your approval, change. Applies to new conversations.
AI 가 읽고 고칠 프로젝트 폴더 ==> The project folder the AI reads and changes
AI 가 읽고 고칠 프로젝트 폴더. 새 대화에 적용됩니다. ==> The project folder the AI reads and changes. Applies to new conversations.
AI 가 터미널 명령을 실행하려고 합니다. 명령 내용을 읽어 보고, 모르는 명령이면 거부해도 괜찮습니다. 명령으로 바뀐 파일은 되돌리기 대상이 아닙니다. ==> The AI wants to run a terminal command. Read it first. If you don't recognize it, it's fine to deny. Files changed by commands can't be reverted.
AI 가 파일 일부를 고치려고 합니다. 빨간 줄이 지워지고 초록 줄이 들어갑니다. 허용하면 원본은 백업됩니다. ==> The AI wants to edit part of a file. Red lines are removed and green lines are added. The original is backed up if you allow it.
AI 가 파일을 새로 만들거나 통째로 바꾸려고 합니다. 허용하면 원본은 자동으로 백업되고, 나중에 ‘되돌리기’로 복구할 수 있습니다. ==> The AI wants to create or replace a file. If you allow it, the original is backed up and you can restore it with Revert.
AI 가 폴더 안 파일을 읽고, 고치거나 명령을 실행할 때는 먼저 허용을 묻습니다. ==> The AI reads files in this folder and asks before changing anything or running commands.
AI 와 도구를 여기서 연결합니다. 하나만 연결해도 바로 쓸 수 있습니다. ==> Connect AIs and tools here. One connection is enough to get started.
AI 와 주고받은 원문 기록 보기 ==> Show the raw log of messages with the AI
API 대화는 대화마다 작업 예산(기본 $1, 추정치)이 있고 입력창 위에 표시됩니다. 다 쓰면 전송이 막힙니다. ‘예산 +$1’로만 올립니다. 구독 대화는 비용을 지어내지 않고 사용률만 보여줍니다. ==> Each API conversation has a budget (default $1, estimated), shown above the message box. Sending stops when it runs out, and only “Budget +$1” raises it. Subscription conversations show usage only, never made-up costs.
API 모델 ==> API model
API 서버가 혼잡합니다 (529). 잠시 후 다시 시도해 주세요. ==> The API server is busy (529). Please try again shortly.
API 실패 ==> API failed
API 연결에 실패했습니다. 네트워크 상태를 확인한 뒤 다시 시도해 주세요. ==> Couldn't reach the API. Check your network and try again.
API 예산 ==> API budget
API 오류 {} {}: {} ==> API error {} {}: {}
API 요청 중 ({}) ==> Calling the API ({})
API 요청 한도에 걸렸습니다 (429). 잠시 후 다시 시도해 주세요. ==> API rate limit reached (429). Please try again shortly.
API 응답을 해석할 수 없습니다: {} ==> Couldn't read the API response: {}
API 잔액/결제 문제입니다 (400): {} ==> API balance or billing problem (400): {}
API 잔액/결제 문제입니다 (402): {} ==> API balance or billing problem (402): {}
API 키 넣기 (Anthropic 또는 OpenAI 사이트에서 발급) ==> Add an API key (get one from Anthropic or OpenAI)
API 키가 비어 있습니다. ==> The API key is empty.
API 키가 유효하지 않습니다 (401). 설정에서 키를 다시 확인해 주세요. ==> The API key is invalid (401). Please check it in Settings.
API 키로 인증됨 ==> Signed in with an API key
Apple Silicon Mac의 직접 설치판에서 사용합니다. API 키 없이 이 Mac에서 답변을 만듭니다. ==> For the direct-install version on Apple Silicon Macs. Replies are made on this Mac, without an API key.
ChatGPT 구독으로 쓰는 코딩 AI ==> Coding AI that uses your ChatGPT subscription
ChatGPT 로그인됨 {} {} ==> Signed in to ChatGPT {} {}
Claude API (본인 API 키, 구독과 별개) ==> Claude API (your own key, separate from subscriptions)
Claude API 키가 설정되어 있지 않습니다. ==> No Claude API key is set.
Claude API 키를 저장했습니다. ‘새 대화’로 바로 시작할 수 있습니다. ==> Claude API key saved. You can start with New Conversation.
Claude API 키를 지웠습니다. ==> Claude API key removed.
Claude Code CLI 를 찾지 못했습니다. 설치 후 설정에서 경로를 지정해 주세요. ==> Couldn't find the Claude Code CLI. Install it, then set its path in Settings.
Claude Code 를 시작하지 못했습니다: {} ==> Couldn't start Claude Code: {}
Claude Code 버전: {} ==> Claude Code version: {}
Claude Code 제어 오류: {} ==> Claude Code control error: {}
Claude Code 프로세스가 실행 중이 아닙니다. ==> Claude Code isn't running.
Claude Code 프로세스가 종료되었습니다 (코드 {}). {} ==> Claude Code exited (code {}). {}
Claude 구독(Pro/Max)으로 쓰는 AI ==> AI that uses your Claude subscription (Pro/Max)
Claude 는 공식 Claude Code CLI 를 수정 없이 실행하고, 로그인은 터미널에서 `claude auth login` 으로 사용자가 직접 합니다. ==> Claude runs the official Claude Code CLI unmodified. You sign in yourself in Terminal with `claude auth login`.
Claude 로그인 필요 ==> Claude sign-in needed
Claude 로그인됨 ==> Claude signed in
Claude 모델: {} ==> Claude model: {}
Claude 상태 확인 실패: {} ==> Couldn't check Claude status: {}
Claude 에 로그인되어 있지 않습니다. ‘연결 관리’의 ‘로그인 명령 복사’로 터미널에서 로그인해 주세요. ==> You aren't signed in to Claude. Use “Copy sign-in command” in Connections, then sign in from Terminal.
Claude 준비됨 ==> Claude ready
Claude 확인 전 ==> Claude not checked yet
Claude 확인 중… ==> Checking Claude…
Codex app-server 가 실행 중이 아닙니다. ==> The Codex app-server isn't running.
Codex 계정: {} ==> Codex account: {}
Codex 는 ‘브라우저로 로그인’, Claude 구독은 터미널에서 claude auth login. 앱은 토큰을 읽거나 저장하지 않습니다. ==> For Codex, use “Sign in with browser”. For a Claude subscription, run claude auth login in Terminal. The app never reads or stores tokens.
Codex 에 연결되어 있지 않습니다. ==> Not connected to Codex.
Codex 프로세스가 종료되었습니다 (코드 {}). {} ==> Codex exited (code {}). {}
Codex·Claude 에 로그인하거나 API 키 넣기 ==> Sign in to Codex or Claude, or add an API key
Condux 빠른 안내 ==> Condux Quick Guide
Condux 설정 ==> Condux Settings
Fable (최상위) ==> Fable (top tier)
Figma 데스크톱 앱 ▸ 환경설정 ▸ ‘로컬 MCP 서버 활성화’ 를 켜야 합니다(Dev/Full 시트). 선택한 프레임을 바로 읽습니다. ==> Turn on “Enable local MCP server” in the Figma desktop app's preferences (Dev/Full seat). Reads the frame you select.
Figma 원격 서버. 터미널에서 로그인 한 번 필요(로그인 명령 복사). ==> Figma remote server. Sign in once from Terminal (copy the sign-in command).
GPT-6.1 Sol · 기본 (입력 $2 / 출력 $10 per 1M) ==> GPT-6.1 Sol · default (input $2 / output $10 per 1M)
Haiku (빠르고 가벼움) ==> Haiku (fast and light)
MCP 서버 ==> MCP servers
MCP 서버 {}개 켜짐 ==> {} MCP servers on
MCP 서버 로그인이 필요합니다: {}. ‘연결 관리’에서 ‘로그인 명령 복사’ 후 터미널에서 실행하세요. ==> MCP server sign-in needed: {}. Use Copy Sign-in Command in Connections, then run it in Terminal.
개발 빌드 ==> development build
자세히 보기 ==> Details
MCP 서버 없음 ==> No MCP servers
MCP 서버 직접 입력 ==> Add an MCP server manually
MCP 설정 오류: {} ==> MCP settings error: {}
MCP 설정을 바꿨습니다. Claude 는 다음 전송부터, Codex 는 ‘다시 연결’ 후 적용됩니다. ==> MCP settings changed. Applies to Claude on the next message, and to Codex after Reconnect.
Mobbin 디자인 레퍼런스. 터미널에서 로그인 한 번 필요. ==> Mobbin design references. Sign in once from Terminal.
OpenAI API (본인 API 키) ==> OpenAI API (your own key)
OpenAI API 키를 저장했습니다. ‘새 대화 ▸ OpenAI API’로 시작할 수 있습니다. ==> OpenAI API key saved. You can start from New Conversation ▸ OpenAI API.
OpenAI API 키를 지웠습니다. ==> OpenAI API key removed.
OpenAI Responses API 로 직접 호출하고, 기록은 앱이 들고 다시 보냅니다(OpenAI 서버에 저장하지 않음). 요금은 OpenAI 에 직접 청구됩니다. ==> Calls the OpenAI Responses API directly. The app keeps the history and resends it (nothing is stored on OpenAI's servers). OpenAI bills you directly.
OpenAI 모델 ==> OpenAI model
Opus (높은 품질) ==> Opus (high quality)
Opus 5.5 · 기본 (입력 $4 / 출력 $20 per 1M) ==> Opus 5.5 · default (input $4 / output $20 per 1M)
PNG·JPEG·PDF·ZIP 파일을 다음 메시지에 붙입니다. ==> Attach PNG, JPEG, PDF, or ZIP files to your next message.
PNG·JPEG·PDF·ZIP 파일을 첨부합니다. 끌어다 놓거나, 복사한 스크린샷을 ⌘⇧V 로 붙여도 됩니다. ==> Attach PNG, JPEG, PDF, or ZIP files. You can also drag them in, or paste a copied screenshot with ⌘⇧V.
Qwen3 1.7B · 약 1GB · 작은 시험용 모델입니다. 한국어·코딩 답변의 정확도는 낮을 수 있습니다. 대화는 총 8,000자까지, 긴 답변은 잘릴 수 있습니다. ==> Qwen3 1.7B · about 1 GB · a small test model. Answers may be less accurate. Conversations are limited to 8,000 characters, and long replies may be cut off.
Sonnet (균형) ==> Sonnet (balanced)
SwiftUI 로 간단한 할 일 앱을 만들려면 어디서 시작해야 해? ==> Where should I start to build a simple to-do app in SwiftUI?
Xcode 빌드·시뮬레이터 도구(MobileBuildMCP). Node 18+ 와 Xcode 16+ 필요. 첫 실행 때 npx 가 내려받습니다. ==> Xcode build and simulator tools (MobileBuildMCP). Needs Node 18+ and Xcode 16+. npx downloads it on first run.
\n→ 이미지 {}개를 받은 파일로 저장 ==> \n→ Saved {} images as received files
`{}` 을 복사했습니다. 터미널에 붙여 넣어 실행하고 브라우저에서 로그인한 뒤 ‘다시 확인’을 눌러 주세요. ==> Copied `{}`. Paste it into Terminal, sign in with your browser, then press Check Again.
claude 실행 파일 경로 (비우면 PATH 에서 자동으로 찾습니다. 예: ~/.local/bin/claude) ==> Path to the claude executable (leave empty to search PATH, e.g. ~/.local/bin/claude)
codex 실행 파일 경로 (비우면 PATH 에서 자동으로 찾습니다. 예: /opt/homebrew/bin/codex) ==> Path to the codex executable (leave empty to search PATH, e.g. /opt/homebrew/bin/codex)
sk-ant-… (Anthropic 콘솔에서 만든 키) ==> sk-ant-… (key from the Anthropic Console)
sk-… (OpenAI 플랫폼에서 만든 키) ==> sk-… (key from the OpenAI Platform)
{} · 종료코드 {} ==> {} · exit code {}
{} 구독 ==> {} subscription
{} 도구 · {} ==> {} tool · {}
{} 로그인 명령을 복사했습니다. 터미널에 붙여 넣어 실행한 뒤 다시 보내세요. ==> Copied the sign-in command for {}. Run it in Terminal, then send again.
{} 읽지 못했습니다. 원본은 지우지 않고 {}에 보관했습니다. 최신 버전의 앱에서 다시 열어 보세요. ==> Couldn't read {}. The original was kept as {}. Try opening it in the latest version of the app.
{}: PNG·JPEG·PDF·ZIP 파일만 첨부할 수 있습니다. ==> {}: only PNG, JPEG, PDF, and ZIP files can be attached.
{}: 너무 큽니다 (최대 {}). ==> {}: too large (max {}).
{}: 파일을 읽을 수 없습니다. ==> {}: couldn't read the file.
{}회 ==> {} rounds
{}초 ==> {}s
· 승인을 기다리는 중 ==> · waiting for your approval
‘새 대화’ 기본 연결 ==> Default connection for new conversations
⌘N 과 ‘새 대화’ 버튼에 적용됩니다. 로컬 AI를 고르면 모델 준비가 끝날 때까지 기다립니다. 다른 연결은 준비되지 않으면 자동 선택으로 돌아갑니다. ==> Applies to ⌘N and New Conversation. If you choose Local AI, it waits until the model is ready. Other connections fall back to Automatic when they aren't ready.
Enter 보내기 · Shift+Enter 줄바꿈 ==> Enter to send · Shift+Enter for a new line
Enter 보내기 ==> Enter to send
Shift+Enter 줄바꿈 ==> Shift+Enter for a new line
+ 또는 드래그로 첨부 ==> + or drag to attach
복사한 이미지는 ⌘V ==> ⌘V to paste a copied image
도움말은 ⌘? ==> ⌘? for help
같은 이름의 MCP 서버가 이미 있습니다: {} ==> An MCP server with that name already exists: {}
개인정보 처리방침 ==> Privacy Policy
거부 ==> Deny
거부됨 ==> Denied
거부됨: {} ==> Denied: {}
검토 비용(API) ==> Review cost (API)
검토 실패: {} ==> Review failed: {}
검토 의견을 입력창에 넣었습니다 · 보내기를 누르면 수정 요청 ==> Review added to the message box · press Send to request the fixes
검토 중 ==> Reviewing
검토자 ==> Reviewer
검토자 승인 (라운드 {}) ==> Approved by the reviewer (round {})
검토자 의견 · {} · 라운드 {}/{} ==> Reviewer notes · {} · round {}/{}
검토자 의견(라운드 {}/{})입니다. 타당한 지적은 반영해 수정하고, 동의하지 않는 지적은 이유를 짧게 쓰세요. 바꾼 내용을 마지막에 요약하세요.\n\n{} ==> Reviewer notes (round {}/{}). Fix what is valid, and briefly explain anything you disagree with. Summarize your changes at the end.\n\n{}
검토자로 쓸 API 키가 필요합니다. 연결 관리에서 Claude API 나 OpenAI API 키를 넣어 주세요. ==> A reviewer needs an API key. Add a Claude API or OpenAI API key in Connections.
검토자로 쓸 {} 키가 없습니다. 설정에서 키를 저장하세요. ==> No {} key for the reviewer. Save one in Settings.
계정 기본값 ==> Account default
계정 확인 실패: {} ==> Couldn't check the account: {}
고급 설정… ==> Advanced Settings…
공식 요율표로 계산한 추정치라 실제 청구와 다를 수 있습니다 ==> Estimated from official pricing. Your actual bill may differ
구독 ==> Subscription
구독 사용량 {} ==> Subscription usage {}
구독으로 쓰기 ==> Use a subscription
구현 실패 ==> Implementation failed
구현 중단됨 ==> Implementation stopped
구현이 끝날 때마다 빌드하고, 실패하면 검토자 없이 오류를 바로 수정 요청합니다. ==> Builds after each implementation round. If the build fails, the errors go straight back for fixing without using the reviewer.
구현자 전송 실패 ==> Couldn't send to the implementer
기본 ==> Default
끄면 검토 의견을 입력창에만 넣고 멈춥니다. 보내기를 누르면 수정 요청이 갑니다. ==> When off, the review is placed in the message box and the relay stops. Press Send to request the fixes.
낮음 ==> Low
내보내기 ==> Export
내보내기 실패: {} ==> Export failed: {}
내보냈습니다: {} ==> Exported: {}
내용 검색 ==> Search contents
노력 수준 ==> Effort
노트북 고치기 ==> Edit notebook
높음 ==> High
다시 연결 ==> Reconnect
다시 확인 ==> Check Again
다운로드 중 {} / {} ({}%) ==> Downloading {} / {} ({}%)
다운로드 중단 ==> Stop Download
다운로드 중단 요청 중… ==> Stopping the download…
다운로드를 시작합니다. 인터넷 연결이 필요합니다. ==> Starting the download. An internet connection is needed.
다운로드를 중단했습니다. 다시 누르면 받은 곳부터 이어받습니다. ==> Download stopped. Press again to resume where it left off.
다운로드할 때만 Hugging Face에 연결합니다. 로컬 대화 내용은 모델 다운로드에 보내지 않습니다. 첨부·MCP·릴레이는 지원하지 않습니다. ==> Connects to Hugging Face only to download. Your conversations are never sent. Attachments, MCP, and Relay aren't supported.
닫기 ==> Close
답변 시작 ==> Reply started
답변 시작 ({}) ==> Reply started ({})
답변 완료 ==> Reply finished
답변 작성 중 ==> Writing a reply
답변이 끝나면 다른 대화로 이동할 수 있습니다. ==> You can switch conversations when the reply finishes.
답변이 끝난 뒤 바꿀 수 있습니다. ==> You can change this after the reply finishes.
답변이 끝난 뒤 제거할 수 있습니다. ==> You can remove this after the reply finishes.
답변이 끝났습니다 ==> Reply finished
대기 중 ==> Waiting
대화 {}개를 ==> {} conversations
대화 {}로 이동 ==> Go to Conversation {}
대화 검색 ==> Search conversations
대화 기록을 ==> conversation history
대화 복원 실패: {} — 로컬 저장본을 표시합니다. ==> Couldn't restore the conversation: {} — showing the local copy.
대화 이름 바꾸기 ==> Rename Conversation
대화를 마크다운으로 내보내기… ==> Export Conversation as Markdown…
도구 ==> Tools
도구 (MCP) ==> Tools (MCP)
도구 없음 ==> No tools
도구 요청 자동 거절 ==> Tool request denied automatically
도구 자동 허용 (승인 없이) ==> Allow tools automatically (no approval)
도구 호출 ==> Calling a tool
되돌렸습니다: {} ==> Reverted: {}
되돌리기 ==> Revert
되돌리기 가능 ==> Can revert
되돌리기 실패: {} ==> Revert failed: {}
되돌림 ==> Reverted
라운드 {}/{}에서 끝났습니다. ==> Finished at round {}/{}.
로그인 ==> Sign In
로그인 명령 복사 ==> Copy Sign-in Command
로그인 시작 실패: {} — 터미널에서 `codex login` 을 실행해 주세요. ==> Couldn't start sign-in: {} — please run `codex login` in Terminal.
로그인 주소를 받지 못했습니다. 터미널에서 `codex login` 을 실행해 주세요. ==> Didn't get a sign-in address. Please run `codex login` in Terminal.
로그인 필요 ==> Sign-in needed
로그인됨 ==> Signed in
로컬 AI (MLX) ==> Local AI (MLX)
로컬 AI (MLX) · 시험 기능 ==> Local AI (MLX) · experimental
로컬 AI (시험 기능) ==> Local AI (experimental)
로컬 AI 실패 ==> Local AI failed
로컬 AI가 답변을 만들지 못했습니다. 모델을 다시 다운로드하거나 새 대화에서 짧게 질문해 주세요. ==> Local AI couldn't make a reply. Download the model again, or try a short question in a new conversation.
로컬 AI는 Apple Silicon Mac의 직접 설치판에서 사용할 수 있습니다. ==> Local AI is available in the direct-install version on Apple Silicon Macs.
로컬 명령 ==> Local command
로컬 명령 (stdio) ==> Local command (stdio)
로컬 새 대화 ==> New Local Conversation
릴레이 ==> Relay
릴레이 {}/{} · 구현 중 ==> Relay {}/{} · implementing
릴레이 {}/{} · {} 검토 중 ==> Relay {}/{} · {} reviewing
릴레이 {}/{} · 빌드 확인 중 ==> Relay {}/{} · checking the build
릴레이 {}/{} 검토 중 ==> Relay {}/{} reviewing
릴레이 {}/{} 구현 중 ==> Relay {}/{} implementing
릴레이 · 빌드 실패 (라운드 {}/{}, 마지막) ==> Relay · build failed (round {}/{}, last)
릴레이 · 빌드 실패 → 수정 요청 (라운드 {}/{}) ==> Relay · build failed → fix requested (round {}/{})
릴레이 시작 · 구현 {} → 검토 {} · 최대 {}회 ==> Relay started · implement {} → review {} · up to {} rounds
릴레이 완료 ==> Relay finished
릴레이 완료 · {} ==> Relay finished · {}
릴레이 중단 ==> Stop Relay
릴레이 중단 · {} ==> Relay stopped · {}
릴레이: 한 AI 가 만들고, 다른 AI 가 검토해서 고칠 점을 돌려주는 걸 자동으로 반복합니다. 횟수와 예산 안에서만 돕니다. ==> Relay: one AI builds, another reviews and sends back fixes, automatically, within a round and budget limit.
마크다운으로 내보내기… ==> Export as Markdown…
만료 ==> Expired
매우 높음 ==> Very high
먼저 대화를 만들어 주세요. ==> Please start a conversation first.
먼저 입력창에 지시를 쓰세요 ==> Write your request in the message box first
명령 실행 ==> Run command
명령 실행 요청 ==> Command request
명령 실행 요청 (읽기 전용 샌드박스) ==> Command request (read-only sandbox)
명령과 인수 (예: npx -y some-mcp-server) ==> Command and arguments (e.g. npx -y some-mcp-server)
모델 ==> Model
모델 {} · {} ==> Model {} · {}
모델 다운로드 (약 1GB) ==> Download Model (about 1 GB)
모델 다운로드 전 · 약 1GB ==> Model not downloaded · about 1 GB
모델 받기 ==> Get Model
모델 삭제 ==> Delete Model
모델 삭제… ==> Delete Model…
모델 이름 직접 입력 (예: claude-sonnet-5-5). 비우면 위 선택을 따릅니다. ==> Enter a model name (e.g. claude-sonnet-5-5). Leave empty to use the choice above.
모델 정보·라이선스 ==> Model Info and License
모델 준비됨 · 다운로드 후에는 인터넷 없이 대화할 수 있습니다. ==> Model ready · no internet needed from now on.
모델 파일 검증에 실패해 받은 파일을 지웠습니다. 다시 눌러 처음부터 받아 주세요. ==> The model file failed verification, so it was removed. Press again to start over.
모델 파일 약 1GB를 삭제합니다. 대화 기록은 남아 있습니다. ==> This deletes about 1 GB of model files. Your conversations are kept.
모델과 노력 수준은 다음 메시지부터 적용됩니다. 높은 모델·노력일수록 구독 한도를 더 빨리 씁니다. ==> Model and effort apply from your next message. Higher settings use your subscription limit faster.
모델을 다운로드하지 못했습니다. 인터넷 연결을 확인한 뒤 다시 누르면 받은 곳부터 이어받습니다. ==> Couldn't download the model. Check your connection and press again to resume.
모델을 바꾸려면 누르세요. 대화의 AI 연결은 바꿀 수 없습니다. ==> Press to change the model. A conversation's AI connection can't be changed.
모델을 삭제하지 못했습니다. 저장 공간 접근 권한을 확인해 주세요. ==> Couldn't delete the model. Please check storage permissions.
모델을 삭제했습니다. 대화 기록은 남아 있습니다. ==> Model deleted. Your conversations are kept.
목록에서 제거… ==> Remove from List…
무엇을 해 드릴까요? ==> What can I do for you?
무엇이든 물어보세요. ==> Ask anything.
미확인 ==> Unknown
미확인 (전송 후 표시) ==> Unknown (shown after sending)
받다 만 파일 지우기 ==> Delete Partial Download
받다 만 파일이 있습니다. 누르면 받은 곳부터 이어받습니다. ==> There is a partial download. Press to resume.
받은 파일 ==> Received files
받은 파일 {} ==> Received files {}
받은 파일 · {} ==> Received file · {}
받은 파일 폴더를 Finder 로 엽니다 ==> Open the received files folder in Finder
버전 {} ==> Version {}
변경된 파일 {}개 ==> {} changed files
별도 인증 불필요 ==> No sign-in needed
보내기 (Enter) ==> Send (Enter)
보조 작업 실행 ==> Run a subtask
복사 ==> Copy
복사됨 ==> Copied
본인 키로 쓰기 · 쓴 만큼 청구 ==> Use your own key · pay for what you use
본인 키로 쓰는 연결 · 쓴 만큼 청구 ==> Connection with your own key · pay for what you use
붙여넣은 이미지 {}.png ==> Pasted image {}.png
브라우저로 로그인 ==> Sign In with Browser
브라우저에서 로그인을 마치면 상태가 자동으로 갱신됩니다. ==> The status updates automatically after you sign in with your browser.
비우기 ==> Clear
빈 답변 ==> Empty reply
빈 대화를 새 Codex 스레드로 다시 열었습니다 ==> Reopened the empty conversation as a new Codex thread
빌드 ==> Build
빌드 결과 · {} · {} ==> Build result · {} · {}
빌드 결과 ==> Build result
빌드 명령 (예: swift build) ==> Build command (e.g. swift build)
빌드 명령 찾는 중… ==> Finding the build command…
빌드 명령이 비어 있습니다. 빌드 명령 칸에 입력해 주세요. ==> The build command is empty. Please enter one.
빌드 실패 ==> Build failed
빌드 실행 ==> Run Build
빌드 실행 · {} ==> Running build · {}
빌드 자동 확인 ==> Check the build automatically
빌드가 실패하는데 원인을 찾아서 고쳐 줘 ==> The build is failing. Find the cause and fix it
빌드가 실패했습니다. 아래 오류를 고쳐 주세요. 고치기 전에 무엇을 바꿀지 한 줄로 설명하고, 수정은 승인을 받으세요. ==> The build failed. Please fix the errors below. Before changing anything, explain in one line what you will change, and get approval for edits.
사용자가 거부했습니다. ==> You denied this.
사용자가 중단 ==> Stopped by you
삭제 ==> Delete
새 대화 ==> New Conversation
새 대화 예산 ${} ==> New conversation budget ${}
새 대화 작업 예산 (달러) ==> Budget per new conversation (USD)
새 대화 화면 입력창의 ‘폴더’ 칩이나 연결 관리에서 폴더를 고르면 그 뒤 만드는 대화가 그 폴더에서 일합니다. 파일 수정과 명령 실행은 승인 카드에서 허용해야 실행되고, 파일 변경은 되돌릴 수 있습니다. 입력창의 폴더 칩을 누르면 빌드를 돌리고 오류를 AI 에게 보낼 수 있습니다. ==> Choose a folder with the folder chip on the new conversation screen, or in Connections. New conversations then work in that folder. Edits and commands run only after you allow them, and file changes can be reverted. Press the folder chip in the message box to run builds and send errors to the AI.
새 대화 화면으로 갑니다. 첫 메시지를 보낼 때 대화가 만들어집니다. ==> Go to the new conversation screen. The conversation is created when you send your first message.
새 대화를 만들지 못했습니다: {} ==> Couldn't start a new conversation: {}
생각 정리 ==> Thinking
생각 정리 끝 ==> Finished thinking
생각 정리 중 ==> Thinking
서버 기록으로 복원됨 (턴 {}개) ==> Restored from the server ({} turns)
서버 이름은 영문·숫자·-·_ 만 쓰고, 주소나 명령을 채워 주세요. ==> Server names can only use letters, numbers, - and _. Please also fill in the address or command.
서버가 기록을 돌려주지 않아 로컬 저장본을 표시합니다. ==> The server returned no history, so the local copy is shown.
설정 ==> Settings
설정… ==> Settings…
설정됨 ==> Set up
설정에서 Claude API 키를 먼저 저장해 주세요. ==> Please save a Claude API key in Settings first.
설정에서 OpenAI API 키를 먼저 저장해 주세요. ==> Please save an OpenAI API key in Settings first.
설정에서 {} 키를 먼저 저장해 주세요. ==> Please save a {} key in Settings first.
설정에서 로컬 AI 모델을 먼저 다운로드해 주세요. ==> Please download the Local AI model in Settings first.
성공 ==> Succeeded
성공 (오류 {}개 표시) ==> Succeeded ({} errors shown)
수정 요청 전송 실패 ==> Couldn't send the fix request
수정 필요 ==> Needs changes
스트림 오류 ==> Stream error
승인 ==> Approved
승인 요청 · {} ==> Approval request · {}
승인을 기다리는 중: {} ==> Waiting for approval: {}
승인이 필요합니다 ==> Approval needed
시작하기 · {}/{} 완료 ==> Getting started · {}/{} done
시험용 로컬 AI 는 글로만 대화합니다. ==> The experimental Local AI is text only.
시험용 로컬 AI는 글로만 대화합니다. ==> The experimental Local AI is text only.
시험용 로컬 AI는 글로만 대화합니다. 첨부 파일을 제거한 뒤 보내 주세요. ==> The experimental Local AI is text only. Remove the attachments, then send.
시험용 로컬 AI는 대화 전체 8,000자까지 지원합니다. 새 로컬 대화를 시작해 주세요. ==> The experimental Local AI supports up to 8,000 characters per conversation. Please start a new local conversation.
시험용 로컬 AI는 릴레이를 지원하지 않습니다. ==> The experimental Local AI doesn't support Relay.
실패 ==> Failed
실패 · 오류 {}개 · 종료코드 {} ==> Failed · {} errors · exit code {}
실패: {} ==> Failed: {}
실행 중 ==> Running
실험 모드: 읽기 전용 샌드박스를 사용하고 도구 승인 요청을 취소합니다. 읽기 명령이나 별도 도구까지 모두 차단하는 설정은 아닙니다. ==> Without a project folder, Codex uses a read-only sandbox and cancels tool requests. This doesn't block every read command or separate tool.
안전 정책으로 거부됨 ==> Refused by safety policy
안전 정책으로 답변이 거부되었습니다 ==> The reply was refused by safety policy
알 수 없는 오류 ==> Unknown error
알 수 없는 키체인 오류 ==> Unknown Keychain error
앱 아이디어를 말할 테니 화면 구성을 제안해 줘 ==> I'll describe an app idea. Suggest the screens for it
앱스토어 버전에서는 Codex/Claude 구독 대화를 이어갈 수 없습니다. 읽기만 가능하고, 새 대화는 API 키 연결로 시작해 주세요. ==> The App Store version can't continue Codex or Claude subscription conversations. You can read them. Please start new ones with an API key.
앱스토어 버전은 Claude API 키 연결만 지원합니다 ==> The App Store version supports API key connections only
앱스토어 버전은 외부 CLI 를 실행하지 않습니다 ==> The App Store version doesn't run external CLIs
앱은 키를 화면에 다시 보여주지 않고, 파일이나 설정에 남기지 않습니다. ==> The app never shows your key again and doesn't store it in files or settings.
앱은 토큰이나 인증 파일을 읽지 않고 `claude auth status` 로 상태만 확인합니다. 구독 요금제의 한도를 그대로 따르고, 한도가 끝나도 API 로 자동 전환하지 않습니다. ==> The app doesn't read tokens or credential files. It only checks status with `claude auth status`. Your plan's limits apply, and it never switches to the API automatically.
앱의 로컬 기록에서만 지웁니다. Codex 서버 기록과 Claude Code 세션 파일은 남고, 받은 파일·첨부 복사본 폴더도 지우지 않습니다. ==> This only removes it from the app's local history. Codex server history, Claude Code session files, and folders of received files and attachment copies are kept.
어떤 AI 로 시작할지 고릅니다 ==> Choose which AI to start with
연결 관리 ==> Connections
연결 관리 열기 ==> Open Connections
연결 관리 열기: 로그인, API 키, 작업 폴더, MCP 도구 ==> Open Connections: sign-in, API keys, project folder, MCP tools
연결 관리 열기… ==> Open Connections…
연결 관리: 로그인, API 키, 작업 폴더, MCP 도구 ==> Connections: sign-in, API keys, project folder, MCP tools
연결 관리… ==> Connections…
연결 끊김 ==> Disconnected
연결 상세 정보 ==> Connection Details
연결 실패 ==> Connection failed
연결 실패: {} ==> Connection failed: {}
연결 안 됨 ==> Not connected
연결 중 ==> Connecting
연결 중… ==> Connecting…
연결과 현재 답변이 끝난 뒤 새 대화를 만들 수 있습니다. ==> You can start a new conversation once connected and the current reply finishes.
연결됨 ==> Connected
연결됨 · {} ==> Connected · {}
연결한 MCP 서버의 도구를 쓰려고 합니다. 읽기 위주 서버면 연결 관리에서 ‘도구 자동 허용’을 켜 두면 매번 묻지 않습니다. ==> The AI wants to use a tool from a connected MCP server. For read-only servers, turn on “Allow tools automatically” in Connections to stop being asked.
열기 ==> Open
예산 +$1 ==> Budget +$1
예산은 대화마다 적용되는 추정 비용 상한입니다(Claude·OpenAI 공통). 재시도·검토·인계도 같은 예산에 합산되고, 다 쓰면 자동으로 올리지 않습니다. 추정치는 공식 요율표 기준이라 실제 청구와 다를 수 있습니다. ==> The budget is an estimated cost limit per conversation (Claude and OpenAI). Retries and reviews count toward it, and it never rises on its own. Estimates use official pricing, so your actual bill may differ.
예상 비용 ==> Estimated cost
오류 ==> Error
오류 {}개 ==> {} errors
오류를 AI에게 보내기 ==> Send Errors to AI
완료 ==> Done
완료 · 긴 답변은 출력 상한에서 잘릴 수 있습니다 ==> Done · long replies may be cut off at the output limit
왼쪽 검색창으로 대화를 찾고, 오른쪽 클릭으로 이름 바꾸기·마크다운 내보내기(⌘⇧E)·제거를 합니다. ==> Find conversations with the search box on the left. Right-click to rename, export as Markdown (⌘⇧E), or remove.
왼쪽 아래 연결 상태 ▸ 연결 관리의 ‘도구 (MCP)’에서 Figma·Mobbin·Xcode 프리셋을 켭니다. 원격 서버 로그인은 ‘로그인 명령 복사’로 받은 명령을 터미널에서 한 번 실행합니다. ==> Press the connection status at the bottom left, then turn on the Figma, Mobbin, or Xcode presets under Tools (MCP). For remote servers, run the copied sign-in command in Terminal once.
왼쪽 위 ‘새 대화’(⌘N)를 누르고 가운데 입력창에 씁니다. 어떤 AI 로 시작할지는 입력창 오른쪽에서 고릅니다. 보내기는 Enter, 중단은 ⌘. 입니다. ==> Press New Conversation (⌘N) at the top left and type in the box in the middle. Choose which AI to use on the right side of the box. Enter sends, ⌘. stops.
요청 보내는 중 ==> Sending
요청 중 ==> Requesting
요청이 중단되었습니다. ==> The request was stopped.
원격 (HTTP) ==> Remote (HTTP)
원격 서버 로그인은 추가 후 ‘로그인 명령 복사’로 터미널에서 합니다. ==> To sign in to a remote server, add it, then use Copy Sign-in Command in Terminal.
웹 검색 ==> Web search
웹 검색 중 ==> Searching the web
웹 페이지 읽기 ==> Read a web page
위 입력창에 첫 질문 보내기 ==> Send your first question in the box above
응답 기다리는 중 ==> Waiting for a response
응답 실패 ==> Response failed
이 Mac 에서 ==> On this Mac
이 Mac 에서 글로만 대화합니다. 짧은 질문이나 요약할 글을 입력해 주세요. ==> Text-only chat on this Mac. Enter a short question or some text to summarize.
이 Mac에서 답변 작성 중 ==> Writing a reply on this Mac
이 Mac에서 모델을 불러오는 중 ==> Loading the model on this Mac
이 Mac에서 처리 · API 사용료 없음 ==> Processed on this Mac · no API charges
이 글을 더 친절한 말투로 다듬어 줘: (글을 붙여 넣으세요) ==> Rewrite this in a friendlier tone: (paste your text)
이 글을 두 문장으로 요약해 줘: (글을 붙여 넣으세요) ==> Summarize this in two sentences: (paste your text)
이 내용으로 릴레이 시작 ==> Start Relay with This Request
이 대화 예산을 ${} 로 올렸습니다. ==> Raised this conversation's budget to ${}.
이 대화는 작업 폴더 모드가 아니라 도구 승인 요청을 차단했습니다. ==> This conversation has no project folder, so the tool request was blocked.
이 대화는 작업 폴더 모드가 아닙니다. ==> This conversation has no project folder.
이 대화를 목록에서 제거할까요? ==> Remove this conversation from the list?
이 대화를 서버에서 열지 못해 보낼 수 없습니다. ==> Couldn't open this conversation on the server, so it can't be sent.
이 대화에 연결 ==> Connect to This Conversation
이 대화에 작업 폴더를 연결했습니다: {}. 다음 전송부터 파일을 읽고(승인 후) 고칠 수 있습니다. ==> Connected a project folder to this conversation: {}. From the next message, the AI can read files and, with approval, change them.
이 대화에 프로젝트 폴더를 연결합니다. 다음 전송부터 파일을 읽고 고칠 수 있습니다. ==> Connect a project folder to this conversation. From the next message, the AI can read and change files.
이 대화의 작업 예산 ${} 를 다 썼습니다(추정 ${}). 아래 ‘예산 +$1’을 누르거나 새 대화를 시작하세요. ==> This conversation's ${} budget is used up (estimated ${}). Press “Budget +$1” below or start a new conversation.
이 대화의 작업 폴더를 해제했습니다. 다음 전송부터 텍스트 대화입니다. ==> Removed the project folder from this conversation. From the next message, it's a text chat.
이 모델의 요율을 몰라 가장 비싼 요율로 비용을 추정합니다. ==> This model's pricing is unknown, so the cost is estimated at the highest rate.
이 빌드에서는 로컬 AI를 사용할 수 없습니다. Apple Silicon Mac의 직접 설치판이 필요합니다. ==> Local AI isn't available in this build. It needs the direct-install version on an Apple Silicon Mac.
이 오류 메시지가 무슨 뜻인지 쉽게 설명해 줘: (오류를 붙여 넣으세요) ==> Explain this error in simple terms: (paste the error)
이 폴더 안의 파일 수정은 묻지 않고 허용합니다. 백업·되돌리기는 그대로이고 명령 실행은 항상 묻습니다. ==> Allows file edits in this folder without asking. Backups and Revert still work, and commands always ask.
이 폴더에서 가장 복잡한 파일 하나를 골라 읽기 쉽게 정리해 줘 ==> Pick the most complex file in this folder and make it easier to read
이 폴더에서 작업 ==> Work in This Folder
이 프로젝트가 어떤 구조인지 초보자에게 설명하듯 알려 줘 ==> Explain how this project is organized, as if to a beginner
이름 (영문·숫자·-·_) ==> Name (letters, numbers, - and _)
이름 바꾸기… ==> Rename…
이번 대화에 쓸 AI 를 고릅니다 ==> Choose the AI for this conversation
이번 실험은 대화만 지원합니다. 도구 사용 요청을 거절했습니다. ==> This mode supports chat only. The tool request was denied.
이번 실험은 대화만 지원합니다. 도구 승인 요청을 차단했습니다. ==> This mode supports chat only. The tool request was blocked.
이벤트 로그 ==> Event Log
이어서 받기 ==> Resume Download
인증됨 ({} ==> Signed in ({}
입력창에 작업 지시를 쓴 뒤 ‘릴레이 시작’을 누르세요. ==> Write your request in the message box, then start the relay.
입력창의 + 버튼(⌘⇧A)이나 드래그 앤 드롭으로 PNG·JPEG·PDF·ZIP 을 붙입니다. 사진은 말풍선에서 바로 보입니다. ==> Attach PNG, JPEG, PDF, or ZIP files with the + button (⌘⇧A) or by dragging them in. Photos show right in the message.
자동 (준비된 연결 중 먼저) ==> Automatic (first ready connection)
자동 릴레이 ==> Automatic Relay
자동 수정 ==> Fix automatically
자동 허용 ==> Allowed automatically
자동 허용(릴레이) ==> Allowed automatically (Relay)
작업 예산 소진 (예산 +$1 후 다시 시작) ==> Budget used up (add +$1, then start again)
작업 폴더 ==> Project Folder
작업 폴더 연결… ==> Connect Project Folder…
작업 폴더 해제 ==> Remove Project Folder
작업 폴더: {} — 이제 만드는 새 대화는 이 폴더에서 도구를 쓸 수 있습니다(수정·명령은 승인 필요). ==> Project folder: {} — new conversations can use tools here (edits and commands need approval).
작업 폴더는 Claude 구독 대화에만 나중에 붙일 수 있습니다. Codex 는 작업 폴더를 고른 뒤 새 대화를 만들어 주세요. ==> Only Claude subscription conversations can get a project folder later. For Codex, choose the folder first, then start a new conversation.
작업 폴더를 연결한 대화만 파일 도구를 씁니다. ==> Only conversations with a project folder use file tools.
작업 폴더를 해제했습니다. 새 대화는 텍스트 대화로 만들어집니다. ==> Project folder removed. New conversations will be text chats.
재시도 중 ({}/{}) {} ==> Retrying ({}/{}) {}
저장 ==> Save
저장 공간이 부족합니다. 약 1GB를 비운 뒤 다시 시도해 주세요. ==> Not enough storage. Free up about 1 GB and try again.
저장 실패: {} ==> Save failed: {}
저장 후 다시 연결 ==> Save and Reconnect
저장… ==> Save…
저장된 키 없음 · 키를 붙여 넣고 ‘키 저장’ 또는 아래 ‘저장’을 누르세요 ==> No key saved · paste a key, then press Save Key or Save below
저장됨 · 이 앱 전용 키체인 항목에 보관 ==> Saved · kept in this app's own Keychain item
저장했습니다: {} ==> Saved: {}
전송 실패 ==> Couldn't send
정리 ==> Organize
제거 ==> Remove
제목 ==> Title
종류 ==> Type
종료코드 {} ==> exit code {}
중간 ==> Medium
중단 ==> Stop
중단 (⌘.) ==> Stop (⌘.)
중단 요청 실패: {}. 다시 눌러 주세요. ==> Couldn't stop: {}. Please press again.
중단 요청 중… ==> Stopping…
중단됨 ==> Stopped
지금 상태를 바탕으로 다음에 할 일 3가지를 제안해 줘 ==> Based on the current state, suggest three things to do next
지시를 쓰고 입력창의 ‘릴레이’ ▸ ‘이 내용으로 릴레이 시작’을 누르면 현재 대화의 AI 가 만들고, 검토자(API)가 확인해 고칠 점을 자동으로 돌려줍니다. 최대 횟수와 작업 예산 안에서만 돕니다. ==> Write a request, then press Relay ▸ Start Relay with This Request. This conversation's AI builds, and the reviewer (API) sends back fixes automatically, within the round and budget limits.
지원 안 함 ==> Not supported
지원 페이지 열기 ==> Open Support Page
지원 페이지와 개인정보 처리방침 열기 ==> Open Support Page and Privacy Policy
직접 입력: {} ==> Custom: {}
직접 입력… ==> Enter Manually…
진행 중 ==> In progress
짧게 물어봐도 됩니다. 사진·PDF 를 붙이면 그걸 보고 답합니다. ==> A short question is fine. Attach a photo or PDF and the AI will read it.
짧은 자기소개를 한국어로 해 줘 ==> Introduce yourself briefly
차단됨 ==> Blocked
첨부 ==> Attach
첨부: {} ==> Attachments: {}
첨부한 PDF 의 핵심만 5줄로 요약해 줘 ==> Summarize the attached PDF in five lines
첨부한 스크린샷의 UI 에서 고칠 점을 알려 줘 ==> Tell me what to improve in the UI in this screenshot
첨부한 파일을 확인해 주세요. ==> Please take a look at the attached files.
최근 대화 ==> Recent
최대 ==> Max
최대 {}회 도달 · 마지막 검토 의견을 확인하세요 ==> Reached {} rounds · check the last review
최대 {}회 도달 · 빌드 실패 상태 ==> Reached {} rounds · build still failing
최대 횟수 ==> Max rounds
추가 ==> Add
추론 수준 ==> Reasoning
출력 마지막 부분: ==> End of the output:
출력 상한(예산)에 닿아 답변이 잘렸을 수 있습니다 ==> The reply may be cut off by the output limit (budget)
취소 ==> Cancel
켜면 다음 전송부터 Claude 에서, ‘다시 연결’ 후 Codex 에서 씁니다. 로그인은 터미널에서 한 번. ==> When on, Claude uses it from the next message, and Codex after Reconnect. Sign in once from Terminal.
코드 ==> Code
클립보드 이미지를 저장하지 못했습니다: {} ==> Couldn't save the clipboard image: {}
클립보드에 이미지나 파일이 없습니다. ==> No image or file on the clipboard.
클립보드에서 첨부 ==> Attach from Clipboard
키 {} ==> Keys {}
키 넣기 ==> Add Key
키 삭제 ==> Delete Key
키 설정 ==> Set Key
키 없음 · Anthropic 사이트에서 발급 ==> No key · get one from Anthropic
키 없음 · OpenAI 사이트에서 발급 ==> No key · get one from OpenAI
키 저장 ==> Save Key
키 저장됨 · 이 앱 전용 키체인 항목에 보관 ==> Key saved · kept in this app's own Keychain item
키를 지웠습니다. ==> Key removed.
키체인 저장 실패 ({}): {} ==> Keychain save failed ({}): {}
턴 시작 ==> Turn started
턴이 {} ==> Turn: {}
토큰 {} ==> Tokens {}
토큰 입력 {} · 출력 {} ==> Tokens in {} · out {}
파일 · ==> File ·
파일 고치기 ==> Edit a file
파일 만들기·쓰기 ==> Create or write a file
파일 변경 ==> File change
파일 변경 백업 · {} ==> File backup · {}
파일 변경 이벤트 (실행 결과 확인 필요) ==> File change event (check the result)
파일 변경 이벤트 수신 ==> File change event received
파일 수정 시도 ==> File edit attempt
파일 수정 자동 허용 ==> Allow file edits automatically
파일 읽기 ==> Read a file
파일 찾기 ==> Find files
폴더 보기 ==> List folder
폴더 선택… ==> Choose Folder…
폴더 없음 ==> No folder
폴더 연결 ==> Connect Folder
폴더 해제 ==> Remove Folder
필터 (예: turn/, item/, error) ==> Filter (e.g. turn/, item/, error)
한 AI 가 만들고 다른 AI 가 검토해 고칠 점을 돌려주는 걸 자동으로 반복합니다. 명령 실행은 직접 허용합니다. ==> One AI builds, another reviews and sends back fixes, automatically. You still allow commands yourself.
할 일 정리 ==> Organize tasks
해제 ==> Remove
허용 ==> Allow
허용됨 ==> Allowed
허용됨: {} ==> Allowed: {}
허용할까요? ==> Allow?
현재 답변이 끝난 뒤 새 대화를 만들 수 있습니다. ==> You can start a new conversation after the current reply finishes.
확인 전 ==> Not checked
시스템 설정 따르기 ==> Follow system setting
화면 ==> Appearance
GitHub CLI(gh)가 없습니다. 명령을 복사해 설치하고 로그인하세요 ==> GitHub CLI (gh) isn't installed. Copy the command to install it and sign in
로그인되어 있지 않습니다 ==> Not signed in
{} 로 로그인됨 ==> Signed in as {}
폴더 대화에서 AI 가 승인을 받고 git·gh 를 씁니다 ==> In folder conversations, the AI uses git and gh with your approval
GitHub 명령을 복사했습니다. 터미널에 붙여넣어 실행한 뒤 ‘다시 확인’을 눌러 주세요. ==> GitHub command copied. Paste it into Terminal, run it, then press Check Again.
다른 프로그램 제어 ==> Control other apps
Claude 가 명령으로 앱을 열고 조작합니다. 실행 전마다 승인합니다 ==> Claude opens and controls apps with commands. You approve each one
제어 대화 시작 ==> Start Control Conversation
이 대화에서 AI 는 명령으로 다른 앱을 열고 조작합니다. 명령마다 승인 카드가 뜹니다. ==> In this conversation, the AI opens and controls other apps with commands. Each command needs your approval.
다른 프로그램 제어는 Claude 구독 로그인이 필요합니다. ‘연결 관리’의 ‘로그인 명령 복사’를 이용해 주세요. ==> Controlling other apps requires a Claude subscription sign-in. Use Copy Sign-in Command in Connections.
웹 검색 ==> Web search
웹 페이지 읽기 ==> Read web page
웹 사용 중 ==> Using the web
웹 검색 중 ==> Searching the web
웹 페이지 읽는 중 ==> Reading a web page
출처 ==> Sources
API 대화에서 AI 가 웹을 검색하고 링크를 읽습니다. 검색 1회당 약 $0.01 과 결과 토큰 비용이 예산에 더해집니다. ==> In API conversations, the AI can search the web and read links. Each search adds about $0.01 plus the cost of result tokens to the budget.
이 API 계정이나 모델에서 웹 검색을 쓸 수 없어 웹 검색 없이 답합니다. ==> Web search isn't available for this API account or model, so the AI will answer without it.
앱스토어판에는 구독 연결, 작업 폴더, MCP 도구(Figma·Mobbin·Xcode), 로컬 AI 가 없습니다. 이 기능은 직접 설치판에서 제공합니다. 앱스토어 샌드박스 안에서는 다른 앱을 조작할 수 없습니다. ==> The App Store version doesn't include subscription connections, project folders, MCP tools (Figma, Mobbin, Xcode), or Local AI. These are in the direct-install version. Apps in the App Store sandbox can't control other apps.
Chrome 브라우저를 AI 가 열고 읽고 누르게 하는 도구(Chrome DevTools MCP). 직접 설치판 전용이며 Node 가 필요합니다. 첫 실행 때 npx 가 내려받습니다. ==> Lets the AI open, read, and click in Chrome (Chrome DevTools MCP). Direct-install only; requires Node. npx downloads it on first run.
컨텍스트 {}% ==> Context {}%
컨텍스트 ==> Context
사용량 ==> Usage
이 대화의 컨텍스트와 사용량 보기 ==> Show context and usage for this conversation
AI 가 이 대화에서 한 번에 기억하는 양입니다. 가득 차면 답이 실패하거나 앞부분을 잊을 수 있으니 새 대화를 시작하세요. ==> How much the AI can hold in mind for this conversation at once. When it's full, replies can fail or forget earlier parts, so start a new conversation.
{} / {} 토큰 ({}%) ==> {} / {} tokens ({}%)
{} 토큰 ==> {} tokens
이 모델의 한도는 알 수 없습니다 ==> This model's limit is unknown
첫 답변이 끝나면 표시합니다. ==> Shown after the first reply.
이 대화에서 주고받은 토큰 ==> Tokens used in this conversation
메시지를 보낼 때마다 앞선 대화도 함께 보내므로 보낸 토큰은 빠르게 늘어납니다. ==> Each message also resends the earlier conversation, so tokens sent grow quickly.
보냄 {} ==> Sent {}
받음 {} ==> Received {}
비용 ==> Cost
구독 ==> Subscription
구독은 달러 비용 대신 한도를 얼마나 썼는지만 표시합니다. ==> Subscriptions show how much of your limit you've used, not dollar costs.
메시지를 보내면 표시합니다. ==> Shown after you send a message.
사용 창 ==> Usage window
밝게 ==> Light
어둡게 ==> Dark
밝은 화면으로 ==> Switch to light mode
어두운 화면으로 ==> Switch to dark mode
API 연결에 실패했습니다. 네트워크 상태를 확인한 뒤 다시 시도해 주세요. (오류 코드 {}) ==> Couldn't reach the API. Check your network and try again. (error code {})
'{}' 응답이 시간 안에 오지 않았습니다. ==> '{}' didn't respond in time.
토큰 {} / 창 {} ==> Tokens {} / window {}
이번 턴 추정 ${} ==> This turn estimated ${}
도구 호출 시도 {} ==> Tool attempt {}
도구 {} ==> Tool {}
빌드 {} ==> Build {}
… 외 {}개 ==> … and {} more
명령 처리 끝 ({}) ==> Command finished ({})
언어 ==> Language
일반 ==> General
추천 설정 ==> Recommended Settings
추천 설정 적용 ==> Apply Recommended Settings
추천 설정 사용 중 ==> Using Recommended Settings
추천 설정을 적용했습니다. ==> Recommended settings applied.
처음이라면 이 설정이 무난합니다. 키·로그인·폴더는 바꾸지 않습니다. ==> A good place to start. Keys, sign-ins, and folders aren't changed.
Claude 구독 모델 ==> Claude subscription model
계정 기본값 · 요금제에 맞는 모델을 자동으로 씁니다 ==> Account default · uses the right model for your plan
Claude API 모델 ==> Claude API model
Sonnet 5.5 · 품질과 비용의 균형이 좋습니다 ==> Sonnet 5.5 · a good balance of quality and cost
OpenAI API 모델 ==> OpenAI API model
GPT-6.1 Sol · 기본 모델입니다 ==> GPT-6.1 Sol · the default model
새 대화 예산 ==> New conversation budget
$1 · 넘으면 멈춰서 안심입니다 ==> $1 · stops when it runs out, so there are no surprises
릴레이 횟수 ==> Relay rounds
3회 · 대부분 이 안에서 끝납니다 ==> 3 rounds · most work finishes within this
릴레이 자동 수정·빌드 확인 ==> Relay auto-fix and build check
켬 · 손이 덜 갑니다 ==> On · less work for you
끔 · 고치기 전에 내용을 확인합니다 ==> Off · you check changes before they happen
"""#
}
// swiftlint:enable line_length
