import AppKit
import SwiftUI

/// 답변 텍스트를 블록 단위로 나눕니다: 코드 울타리, 제목, 목록, 표, 문단. 가벼운 파서라 중첩은 다루지 않습니다.
enum MarkdownBlocks {
    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullet(items: [String], ordered: Bool)
        case code(language: String, text: String)
        case table(rows: [[String]])
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var cursor = index + 1
                while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces) != "```" {
                    body.append(lines[cursor]); cursor += 1
                }
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                index = cursor + 1 // 닫는 울타리가 없으면(스트리밍 중) 끝까지 코드로 봅니다.
                continue
            }
            if line.isEmpty { flushParagraph(); index += 1; continue }
            if line == "---" || line == "***" || line == "___" { flushParagraph(); blocks.append(.rule); index += 1; continue }
            if let level = headingLevel(line) {
                flushParagraph()
                blocks.append(.heading(level: level, text: String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                index += 1; continue
            }
            if line.hasPrefix("|") {
                flushParagraph()
                var rows: [[String]] = []
                var cursor = index
                while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = lines[cursor].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } && !$0.isEmpty }) { rows.append(cells) }
                    cursor += 1
                }
                blocks.append(.table(rows: rows))
                index = cursor; continue
            }
            if let item = bulletItem(line) {
                flushParagraph()
                var items: [String] = []
                var cursor = index
                let ordered = item.ordered
                while cursor < lines.count, let next = bulletItem(lines[cursor].trimmingCharacters(in: .whitespaces)), next.ordered == ordered {
                    items.append(next.text)
                    cursor += 1
                    // 들여쓴 이어지는 줄은 같은 항목에 붙입니다.
                    while cursor < lines.count, lines[cursor].hasPrefix("  "), bulletItem(lines[cursor].trimmingCharacters(in: .whitespaces)) == nil,
                          !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                        items[items.count - 1] += " " + lines[cursor].trimmingCharacters(in: .whitespaces)
                        cursor += 1
                    }
                }
                blocks.append(.bullet(items: items, ordered: ordered))
                index = cursor; continue
            }
            paragraph.append(raw)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bulletItem(_ line: String) -> (text: String, ordered: Bool)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { return (String(line.dropFirst(2)), false) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") {
            return (String(line.dropFirst(digits.count + 2)), true)
        }
        return nil
    }

    /// 인라인 마크다운(굵게·기울임·코드·링크)만 해석하고 줄바꿈은 그대로 둡니다.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// 답변 말풍선 안의 본문. 코드 블록은 복사 버튼이 있는 상자로, 표는 격자로 보여줍니다.
struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let body):
                    Text(MarkdownBlocks.inline(body)).textSelection(.enabled)
                case .heading(let level, let body):
                    Text(MarkdownBlocks.inline(body))
                        .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, 4).textSelection(.enabled)
                case .bullet(let items, let ordered):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ordered ? "\(offset + 1)." : "•").foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                                Text(MarkdownBlocks.inline(item)).textSelection(.enabled)
                            }
                        }
                    }
                case .code(let language, let body):
                    CodeBlockView(language: language, text: body)
                case .table(let rows):
                    TableBlockView(rows: rows)
                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeBlockView: View {
    let language: String
    let text: String
    @State private var copied = false

    private var isFileBlock: Bool { language.hasPrefix("file:") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isFileBlock ? "파일 · " + String(language.dropFirst(5)) : (language.isEmpty ? "코드" : language))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? tr("복사됨") : tr("복사")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .controlSize(.mini).buttonStyle(.plain).foregroundStyle(ConduxTheme.blue)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(ConduxTheme.codeHeader)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(ConduxTheme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ConduxTheme.borderSubtle, lineWidth: 1))
    }
}

struct TableBlockView: View {
    let rows: [[String]]

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(MarkdownBlocks.inline(column < row.count ? row[column] : ""))
                                .font(rowIndex == 0 ? .callout.bold() : .callout)
                                .textSelection(.enabled)
                        }
                    }
                    if rowIndex == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(8)
        }
        .background(ConduxTheme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}
