import XCTest
@testable import Condux

final class MarkdownBlocksTests: XCTestCase {
    func testParsesFencesHeadingsListsTablesAndParagraphs() {
        let text = """
        # 제목

        설명 문단 **굵게**
        둘째 줄

        ```swift
        let x = 1
        ```

        - 하나
        - 둘
          이어지는 줄
        1. 첫째
        2. 둘째

        | 이름 | 값 |
        | --- | --- |
        | a | 1 |

        ---
        끝
        """
        let blocks = MarkdownBlocks.parse(text)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "제목"),
            .paragraph("설명 문단 **굵게**\n둘째 줄"),
            .code(language: "swift", text: "let x = 1"),
            .bullet(items: ["하나", "둘 이어지는 줄"], ordered: false),
            .bullet(items: ["첫째", "둘째"], ordered: true),
            .table(rows: [["이름", "값"], ["a", "1"]]),
            .rule,
            .paragraph("끝"),
        ])
    }

    func testUnclosedFenceWhileStreamingIsStillCode() {
        let blocks = MarkdownBlocks.parse("앞\n```file:hello.txt\n안녕\n아직")
        XCTAssertEqual(blocks, [.paragraph("앞"), .code(language: "file:hello.txt", text: "안녕\n아직")])
    }

    func testInlineMarkdownKeepsNewlinesAndPlainTextSurvives() {
        let attributed = MarkdownBlocks.inline("a **b**\nc")
        XCTAssertEqual(String(attributed.characters), "a b\nc")
        XCTAssertEqual(String(MarkdownBlocks.inline("1 < 2 & *").characters), "1 < 2 & *")
        XCTAssertEqual(MarkdownBlocks.parse("   "), [])
    }
}
