import Foundation

/// 구독판에서 Claude CLI·Codex 에 넘기는 MCP 서버 설정 하나.
/// 로그인(OAuth)은 앱이 하지 않습니다. 사용자가 터미널에서 `claude mcp login` / `codex mcp login` 으로 한 번 하면
/// 두 CLI 가 각자 보관한 로그인을 다시 씁니다(Claude 는 서버 주소 기준). 앱은 토큰을 읽거나 저장하지 않습니다.
struct MCPServer: Codable, Identifiable, Equatable {
    enum Transport: String, Codable { case http, stdio }

    var id: String = UUID().uuidString
    /// 영문·숫자·`-`·`_` 만. 도구 이름 `mcp__<name>__<tool>` 의 일부가 됩니다.
    var name: String
    var transport: Transport
    var url: String = ""
    var command: String = ""
    var args: [String] = []
    var enabled = true
    /// 이 서버의 도구 호출을 승인 카드 없이 허용 (읽기 전용 서버에 권장)
    var autoAllow = false
    /// 프리셋 안내 문구
    var note = ""

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    var isValid: Bool {
        guard Self.isValidName(name) else { return false }
        switch transport {
        case .http: return URL(string: url).map { $0.scheme == "https" || $0.scheme == "http" } ?? false
        case .stdio: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var locationText: String { transport == .http ? url : ([command] + args).joined(separator: " ") }

    /// Claude CLI `--mcp-config` 의 서버 항목
    var claudeConfig: JSONValue {
        switch transport {
        case .http: return ["type": "http", "url": .string(url)]
        case .stdio: return ["type": "stdio", "command": .string(command), "args": .array(args.map { .string($0) })]
        }
    }

    /// Claude 권한 규칙·도구 목록에 쓰는 서버 단위 이름
    var claudeToolName: String { "mcp__\(name)" }

    /// Codex app-server 실행 시 `-c` 로 넘기는 설정 (config.toml 과 같은 키)
    var codexOverrides: [String] {
        func toml(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        switch transport {
        case .http:
            return ["-c", "mcp_servers.\(name).url=\(toml(url))"]
        case .stdio:
            return ["-c", "mcp_servers.\(name).command=\(toml(command))",
                    "-c", "mcp_servers.\(name).args=[\(args.map(toml).joined(separator: ","))]"]
        }
    }

    /// 터미널에서 한 번 실행할 로그인 명령 (http 서버만). 앱은 이 명령을 복사만 해 줍니다.
    var loginCommands: String? {
        guard transport == .http else { return nil }
        return """
        claude mcp add --scope user --transport http \(name) \(url)
        claude mcp login \(name)
        codex mcp add \(name) --url \(url)
        codex mcp login \(name)
        """
    }

    // MARK: 프리셋

    static let figmaRemote = MCPServer(name: "figma", transport: .http, url: "https://mcp.figma.com/mcp", autoAllow: true,
                                       note: "Figma 원격 서버. 터미널에서 로그인 한 번 필요(로그인 명령 복사).")
    static let figmaDesktop = MCPServer(name: "figma-desktop", transport: .http, url: "http://127.0.0.1:3845/mcp", autoAllow: true,
                                        note: "Figma 데스크톱 앱 ▸ 환경설정 ▸ ‘로컬 MCP 서버 활성화’ 를 켜야 합니다(Dev/Full 시트). 선택한 프레임을 바로 읽습니다.")
    static let mobbin = MCPServer(name: "mobbin", transport: .http, url: "https://api.mobbin.com/mcp", autoAllow: true,
                                  note: "Mobbin 디자인 레퍼런스. 터미널에서 로그인 한 번 필요.")
    static let xcode = MCPServer(name: "xcode", transport: .stdio, command: "npx", args: ["-y", "mobilebuildmcp@latest", "mcp"],
                                 note: "Xcode 빌드·시뮬레이터 도구(MobileBuildMCP). Node 18+ 와 Xcode 16+ 필요. 첫 실행 때 npx 가 내려받습니다.")
    static let chrome = MCPServer(name: "chrome", transport: .stdio, command: "npx", args: ["-y", "chrome-devtools-mcp@latest", "--no-usage-statistics"],
                                  note: "Chrome 브라우저를 AI 가 열고 읽고 누르게 하는 도구(Chrome DevTools MCP). 직접 설치판 전용이며 Node 가 필요합니다. 첫 실행 때 npx 가 내려받습니다.")
    static let presets: [MCPServer] = [figmaRemote, figmaDesktop, mobbin, xcode, chrome]
}

enum MCPServerList {
    static let defaultsKey = "mcpServers"

    static func load(from defaults: UserDefaults) -> [MCPServer] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([MCPServer].self, from: data)) ?? []
    }

    static func save(_ servers: [MCPServer], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: defaultsKey) }
    }

    /// Claude CLI `--mcp-config` 에 넘길 JSON 문자열. 켜진 서버가 없으면 빈 문자열.
    static func claudeConfigJSON(_ servers: [MCPServer]) -> String {
        let enabled = servers.filter { $0.enabled && $0.isValid }
        guard !enabled.isEmpty else { return "" }
        var map: [String: JSONValue] = [:]
        for server in enabled { map[server.name] = server.claudeConfig }
        return (try? JSONValue.object(["mcpServers": .object(map)]).compactJSON()) ?? ""
    }

    static func claudeToolNames(_ servers: [MCPServer]) -> [String] {
        servers.filter { $0.enabled && $0.isValid }.map(\.claudeToolName)
    }

    static func claudeAllowedTools(_ servers: [MCPServer]) -> [String] {
        servers.filter { $0.enabled && $0.isValid && $0.autoAllow }.map(\.claudeToolName)
    }

    static func codexOverrides(_ servers: [MCPServer]) -> [String] {
        servers.filter { $0.enabled && $0.isValid }.flatMap(\.codexOverrides)
    }

    /// `system/init` 의 mcp_servers 상태 → 한국어
    static func statusText(_ status: String?) -> String {
        switch status {
        case "connected": return "연결됨"
        case "needs-auth": return "로그인 필요"
        case "failed": return "연결 실패"
        case "pending": return "연결 중"
        case nil: return "미확인"
        default: return status ?? ""
        }
    }
}
