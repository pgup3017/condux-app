import XCTest
@testable import Condux

final class FriendlyTextTests: XCTestCase {
    func testToolLabelsAndActivityTitles() {
        XCTAssertEqual(FriendlyText.toolLabel("Read"), "파일 읽기")
        XCTAssertEqual(FriendlyText.toolLabel("mcp__figma__get_design_context"), "figma 도구 · get_design_context")
        XCTAssertEqual(FriendlyText.toolLabel("SomethingNew"), "SomethingNew")
        XCTAssertEqual(FriendlyText.activityTitle("도구 Bash"), "명령 실행 (Bash)")
        XCTAssertEqual(FriendlyText.activityTitle("도구 호출 시도 Write"), "도구 없음 · 파일 만들기·쓰기 (Write)")
        XCTAssertEqual(FriendlyText.activityTitle("승인 요청 · Edit"), "허용할까요? 파일 고치기 (Edit)")
        XCTAssertEqual(FriendlyText.activityTitle("빌드 결과 · 성공 · 4초"), "빌드 결과 · 성공 · 4초", "모르는 제목은 그대로")
        XCTAssertEqual(FriendlyText.activityTitle("도구 Unknown"), "도구 Unknown")
    }

    func testApprovalHintsAndExamples() {
        XCTAssertTrue(FriendlyText.approvalHint(tool: "Bash").contains("명령"))
        XCTAssertTrue(FriendlyText.approvalHint(tool: "Write").contains("백업"))
        XCTAssertTrue(FriendlyText.approvalHint(tool: "mcp__mobbin__search_screens").contains("MCP"))
        XCTAssertFalse(FriendlyText.examplePrompts(provider: .codex, hasWorkspace: true).isEmpty)
        XCTAssertNotEqual(FriendlyText.examplePrompts(provider: .claudeAPI, hasWorkspace: false),
                          FriendlyText.examplePrompts(provider: .claude, hasWorkspace: false))
        // 앱 문구 규칙: 존댓말(~합니다/~세요)만 쓰고 ‘~해요’체는 쓰지 않습니다.
        for text in [FriendlyText.codexBoxHint, FriendlyText.claudeBoxHint, FriendlyText.apiBoxHint, FriendlyText.workspaceBoxHint, FriendlyText.relayHint]
            + ["Bash", "Write", "Edit", "mcp__x__y", "Other"].map { FriendlyText.approvalHint(tool: $0) } {
            XCTAssertFalse(text.contains("해요") || text.contains("어요") || text.contains("예요"), text)
        }
    }
}
