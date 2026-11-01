import XCTest
@testable import Condux

/// 첨부 파일 복사·변환·받은 파일 처리 (AI 호출 없음)
final class AttachmentsTests: XCTestCase {
    private var root: URL!
    private var store: AttachmentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("condux-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = AttachmentStore(root: root.appendingPathComponent("app"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImportCopiesSupportedFilesAndRejectsOthers() throws {
        let png = root.appendingPathComponent("그림.PNG")
        try TestFiles.png(at: png)
        let attachment = try store.importFile(png, conversationID: "c/1")
        XCTAssertEqual(attachment.kind, .png)
        XCTAssertEqual(attachment.name, "그림.PNG")
        XCTAssertTrue(attachment.path.contains("/attachments/c_1/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
        XCTAssertEqual(attachment.byteCount, try Data(contentsOf: png).count)
        try FileManager.default.removeItem(at: png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path), "원본을 지워도 복사본은 남습니다")

        let txt = root.appendingPathComponent("메모.txt")
        try "x".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.importFile(txt, conversationID: "c")) { error in
            XCTAssertTrue(error.localizedDescription.contains("PNG·JPEG·PDF·ZIP"))
        }
    }

    func testOversizedImageIsShrunkToJPEG() throws {
        let png = root.appendingPathComponent("big.png")
        try TestFiles.png(at: png, size: 600)
        let attachment = try store.importFile(png, conversationID: "c", imageLimit: 3_000)
        XCTAssertEqual(attachment.kind, .jpeg)
        XCTAssertEqual(attachment.name, "big.jpg")
        XCTAssertLessThanOrEqual(attachment.byteCount, 3_000)
        XCTAssertNotNil(NSImage(contentsOfFile: attachment.path))
    }

    func testPDFTextAndClaudeOpenAIBlocks() throws {
        let pdf = root.appendingPathComponent("doc.pdf")
        try TestFiles.pdf(at: pdf, text: "Hello Condux 2026")
        let attachment = try store.importFile(pdf, conversationID: "c")
        let text = AttachmentEncoder.pdfText(attachment)
        XCTAssertTrue(text.contains("Hello Condux 2026"), text)
        XCTAssertTrue(text.hasPrefix("[첨부 PDF doc.pdf · 1쪽"))

        let claude = AttachmentEncoder.claudeBlocks(attachment)
        XCTAssertEqual(claude.count, 1)
        XCTAssertEqual(claude[0]["type"]?.stringValue, "document")
        XCTAssertEqual(claude[0]["source"]?["media_type"]?.stringValue, "application/pdf")
        XCTAssertEqual(claude[0]["source"]?["data"]?.stringValue, try Data(contentsOf: pdf).base64EncodedString())
        let openAI = AttachmentEncoder.openAIParts(attachment)
        XCTAssertEqual(openAI[0]["type"]?.stringValue, "input_file")
        XCTAssertEqual(openAI[0]["filename"]?.stringValue, "doc.pdf")
        XCTAssertTrue(openAI[0]["file_data"]?.stringValue?.hasPrefix("data:application/pdf;base64,") ?? false)

        let png = root.appendingPathComponent("a.png")
        try TestFiles.png(at: png)
        let image = try store.importFile(png, conversationID: "c")
        XCTAssertEqual(AttachmentEncoder.claudeBlocks(image)[0]["source"]?["media_type"]?.stringValue, "image/png")
        XCTAssertTrue(AttachmentEncoder.openAIParts(image)[0]["image_url"]?.stringValue?.hasPrefix("data:image/png;base64,") ?? false)
    }

    func testZipSummaryListsEntriesAndIncludesTextFiles() throws {
        let zip = root.appendingPathComponent("번들.zip")
        try TestFiles.zip(at: zip, files: ["notes/readme.md": "# 안내\n내용", "src/main.swift": "print(1)", "bin/data.bin": "\u{0}\u{1}"])
        let attachment = try store.importFile(zip, conversationID: "c")
        let entries = AttachmentEncoder.zipEntries(attachment.url)
        XCTAssertEqual(Set(entries.map(\.name)), ["notes/readme.md", "src/main.swift", "bin/data.bin"])
        let summary = AttachmentEncoder.zipSummary(attachment)
        XCTAssertTrue(summary.hasPrefix("[첨부 ZIP 번들.zip"), summary)
        XCTAssertTrue(summary.contains("- src/main.swift"))
        XCTAssertTrue(summary.contains("### notes/readme.md\n```\n# 안내\n내용\n```"), summary)
        XCTAssertTrue(summary.contains("print(1)"))
        XCTAssertFalse(summary.contains("### bin/data.bin"), "텍스트가 아닌 파일 내용은 넣지 않습니다")
        XCTAssertEqual(AttachmentEncoder.claudeBlocks(attachment)[0]["type"]?.stringValue, "text")
        XCTAssertEqual(AttachmentEncoder.openAIParts(attachment)[0]["type"]?.stringValue, "input_text")
    }

    func testPlaceholderRoundTripsAndExpands() throws {
        let png = root.appendingPathComponent("a.png")
        try TestFiles.png(at: png)
        let image = try store.importFile(png, conversationID: "c")
        let placeholder = AttachmentEncoder.placeholder(image)
        XCTAssertEqual(AttachmentEncoder.attachment(fromPlaceholder: placeholder), image)
        let transcript: [JSONValue] = [["role": "user", "content": [["type": "text", "text": "봐 줘"], placeholder]],
                                       ["role": "assistant", "content": [["type": "text", "text": "네"]]]]
        let expanded = AttachmentEncoder.expandClaude(transcript)
        XCTAssertEqual(expanded[0]["content"]?[1]?["type"]?.stringValue, "image")
        XCTAssertEqual(expanded[1], transcript[1])
        let openAI = AttachmentEncoder.expandOpenAI([["role": "user", "content": [["type": "input_text", "text": "봐 줘"], placeholder]]])
        XCTAssertEqual(openAI[0]["content"]?[1]?["type"]?.stringValue, "input_image")
        // 전사본 자체에는 base64 가 없습니다.
        XCTAssertFalse(try transcript[0].compactJSON().contains("base64"))
    }

    func testFileBlockParserAndReceivedFiles() throws {
        let text = """
        결과입니다.

        ```file:hello.txt
        안녕
        둘째 줄
        ```

        ```swift
        let x = 1
        ```

        ```file:../evil.sh
        rm -rf /
        ```

        ```file:report.md 설명
        # 보고
        ```
        """
        let blocks = FileBlockParser.blocks(in: text)
        XCTAssertEqual(blocks.map(\.name), ["hello.txt", "report.md"])
        XCTAssertEqual(blocks[0].content, "안녕\n둘째 줄\n")

        let written = store.writeFileBlocks(from: text, conversationID: "c")
        XCTAssertEqual(written.map(\.lastPathComponent), ["hello.txt", "report.md"])
        let again = store.writeFileBlocks(from: text, conversationID: "c")
        XCTAssertEqual(again.map(\.lastPathComponent), ["hello-2.txt", "report-2.md"], "같은 이름은 번호를 붙입니다")

        let fresh = store.newReceivedFiles(for: "c", known: [])
        XCTAssertEqual(Set(fresh.map(\.name)), ["hello.txt", "report.md", "hello-2.txt", "report-2.md"])
        let known = Set(fresh.map(\.path))
        XCTAssertTrue(store.newReceivedFiles(for: "c", known: known).isEmpty)
        XCTAssertEqual(try String(contentsOf: store.outputsDirectory(for: "c").appendingPathComponent("hello.txt")), "안녕\n둘째 줄\n")
    }
}
