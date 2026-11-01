import XCTest
@testable import Condux

final class MCPServersTests: XCTestCase {
    func testPresetsAreValidAndProduceClaudeConfig() throws {
        for preset in MCPServer.presets { XCTAssertTrue(preset.isValid, preset.name) }
        let json = MCPServerList.claudeConfigJSON([MCPServer.figmaRemote, MCPServer.xcode])
        let config = try JSONValue.parse(json)
        XCTAssertEqual(config["mcpServers"]?["figma"]?["type"]?.stringValue, "http")
        XCTAssertEqual(config["mcpServers"]?["figma"]?["url"]?.stringValue, "https://mcp.figma.com/mcp")
        XCTAssertEqual(config["mcpServers"]?["xcode"]?["type"]?.stringValue, "stdio")
        XCTAssertEqual(config["mcpServers"]?["xcode"]?["command"]?.stringValue, "npx")
        XCTAssertEqual(config["mcpServers"]?["xcode"]?["args"]?.arrayValue?.compactMap(\.stringValue), ["-y", "mobilebuildmcp@latest", "mcp"])
        XCTAssertEqual(MCPServerList.claudeToolNames([MCPServer.figmaRemote, MCPServer.xcode]), ["mcp__figma", "mcp__xcode"])
        XCTAssertEqual(MCPServerList.claudeAllowedTools([MCPServer.figmaRemote, MCPServer.xcode]), ["mcp__figma"], "xcode 프리셋은 자동 허용 아님")
        XCTAssertEqual(MCPServerList.claudeConfigJSON([]), "")
    }

    func testDisabledOrInvalidServersAreSkipped() throws {
        var off = MCPServer.mobbin
        off.enabled = false
        let bad = MCPServer(name: "bad name", transport: .http, url: "https://x/mcp")
        let noURL = MCPServer(name: "nourl", transport: .http, url: "")
        XCTAssertFalse(bad.isValid)
        XCTAssertFalse(noURL.isValid)
        XCTAssertEqual(MCPServerList.claudeConfigJSON([off, bad, noURL]), "")
        XCTAssertTrue(MCPServerList.codexOverrides([off, bad]).isEmpty)
    }

    func testCodexOverridesAndLoginCommands() {
        XCTAssertEqual(MCPServer.mobbin.codexOverrides, ["-c", "mcp_servers.mobbin.url=\"https://api.mobbin.com/mcp\""])
        XCTAssertEqual(MCPServer.xcode.codexOverrides,
                       ["-c", "mcp_servers.xcode.command=\"npx\"", "-c", "mcp_servers.xcode.args=[\"-y\",\"mobilebuildmcp@latest\",\"mcp\"]"])
        let login = MCPServer.figmaRemote.loginCommands ?? ""
        XCTAssertTrue(login.contains("claude mcp add --scope user --transport http figma https://mcp.figma.com/mcp"))
        XCTAssertTrue(login.contains("claude mcp login figma"))
        XCTAssertTrue(login.contains("codex mcp login figma"))
        XCTAssertNil(MCPServer.xcode.loginCommands)
        XCTAssertEqual(MCPServerList.statusText("needs-auth"), "로그인 필요")
    }

    func testSaveAndLoadRoundTrip() {
        let suite = "condux-mcp-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var custom = MCPServer(name: "my-server", transport: .stdio, command: "node", args: ["server.js"], autoAllow: true)
        custom.enabled = false
        MCPServerList.save([MCPServer.mobbin, custom], to: defaults)
        let loaded = MCPServerList.load(from: defaults)
        XCTAssertEqual(loaded, [MCPServer.mobbin, custom])
    }
}
