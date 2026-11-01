import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// 보낼 첨부 파일 하나 (PNG·JPEG·PDF·ZIP). 앱 폴더에 복사해 두므로 원본이 지워져도 남습니다.
struct Attachment: Identifiable, Equatable {
    enum Kind: String {
        case png, jpeg, pdf, zip

        var mediaType: String {
            switch self {
            case .png: return "image/png"
            case .jpeg: return "image/jpeg"
            case .pdf: return "application/pdf"
            case .zip: return "application/zip"
            }
        }
        var label: String { rawValue.uppercased() }
        var isImage: Bool { self == .png || self == .jpeg }
        var systemImage: String {
            switch self {
            case .png, .jpeg: return "photo"
            case .pdf: return "doc.richtext"
            case .zip: return "doc.zipper"
            }
        }

        static func detect(_ url: URL) -> Kind? {
            switch url.pathExtension.lowercased() {
            case "png": return .png
            case "jpg", "jpeg": return .jpeg
            case "pdf": return .pdf
            case "zip": return .zip
            default: return nil
            }
        }
    }

    let id: String
    var name: String
    var kind: Kind
    /// 앱이 복사해 둔 파일의 절대 경로
    var path: String
    var byteCount: Int

    var url: URL { URL(fileURLWithPath: path) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
    var summary: String { "\(name) (\(kind.label), \(sizeText))" }

    static let allowedTypes: [UTType] = [.png, .jpeg, .pdf, .zip]
    /// API 쪽 상한(Anthropic 이미지 5MB·PDF 32MB, OpenAI 비슷). ZIP 은 앱 자체 상한.
    static let imageLimit = 5 * 1024 * 1024
    static let pdfLimit = 32 * 1024 * 1024
    static let zipLimit = 50 * 1024 * 1024
}

enum AttachmentError: LocalizedError {
    case unsupported(String)
    case tooLarge(String, Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): return "\(name): PNG·JPEG·PDF·ZIP 파일만 첨부할 수 있습니다."
        case .tooLarge(let name, let limit):
            return "\(name): 너무 큽니다 (최대 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))."
        case .unreadable(let name): return "\(name): 파일을 읽을 수 없습니다."
        }
    }
}

/// AI 가 사용자에게 돌려준 파일 (대화별 ‘받은 파일’ 폴더에 있음)
struct ReceivedFile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
    var byteCount: Int
    var date: Date

    var url: URL { URL(fileURLWithPath: path) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
}

/// 첨부 파일 복사·변환과 ‘받은 파일’ 폴더를 맡습니다.
struct AttachmentStore {
    /// 앱 데이터 폴더(…/VibeStudio). 첨부는 attachments/<대화>/, 받은 파일은 outputs/<대화>/ 에 둡니다.
    let root: URL

    private static func safe(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "_") }

    func attachmentsDirectory(for conversationID: String) -> URL {
        root.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(Self.safe(conversationID), isDirectory: true)
    }

    func outputsDirectory(for conversationID: String) -> URL {
        root.appendingPathComponent("outputs", isDirectory: true).appendingPathComponent(Self.safe(conversationID), isDirectory: true)
    }

    /// 고른 파일을 대화의 첨부 폴더로 복사합니다. 상한보다 큰 이미지는 줄여 JPEG 로 바꿉니다.
    /// 샌드박스(앱스토어판)에서는 열기 창·드롭으로 받은 URL 의 보안 범위를 복사하는 동안만 엽니다.
    func importFile(_ source: URL, conversationID: String, imageLimit: Int = Attachment.imageLimit) throws -> Attachment {
        guard let kind = Attachment.Kind.detect(source) else { throw AttachmentError.unsupported(source.lastPathComponent) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source) else { throw AttachmentError.unreadable(source.lastPathComponent) }

        let directory = attachmentsDirectory(for: conversationID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        var name = source.lastPathComponent
        var finalKind = kind
        var finalData = data
        switch kind {
        case .png, .jpeg:
            if data.count > imageLimit {
                guard let shrunk = Self.shrinkImage(data, targetBytes: imageLimit) else { throw AttachmentError.tooLarge(name, imageLimit) }
                finalData = shrunk
                finalKind = .jpeg
                name = (name as NSString).deletingPathExtension + ".jpg"
            }
        case .pdf:
            guard data.count <= Attachment.pdfLimit else { throw AttachmentError.tooLarge(name, Attachment.pdfLimit) }
        case .zip:
            guard data.count <= Attachment.zipLimit else { throw AttachmentError.tooLarge(name, Attachment.zipLimit) }
        }
        let destination = directory.appendingPathComponent("\(id.prefix(8))-\(name)")
        try finalData.write(to: destination, options: .atomic)
        return Attachment(id: id, name: name, kind: finalKind, path: destination.path, byteCount: finalData.count)
    }

    /// 긴 변을 줄이고 JPEG 로 저장해 목표 크기 아래로 맞춥니다. 실패하면 nil.
    static func shrinkImage(_ data: Data, targetBytes: Int) -> Data? {
        guard let image = NSImage(data: data), let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? data) else { return nil }
        var longest = max(rep.pixelsWide, rep.pixelsHigh)
        var quality = 0.85
        for _ in 0..<8 {
            let scale = min(1, Double(longest) / Double(max(rep.pixelsWide, rep.pixelsHigh)))
            let size = NSSize(width: Double(rep.pixelsWide) * scale, height: Double(rep.pixelsHigh) * scale)
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            if let jpeg = out.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= targetBytes { return jpeg }
            longest = Int(Double(longest) * 0.7)
            quality = max(0.5, quality - 0.1)
            if longest < 200 { break }
        }
        return nil
    }

    /// ‘받은 파일’ 폴더에서 아직 기록되지 않은 파일을 찾습니다(수정 시각 순).
    func newReceivedFiles(for conversationID: String, known: Set<String>) -> [ReceivedFile] {
        let directory = outputsDirectory(for: conversationID)
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return [] }
        return items.compactMap { url -> ReceivedFile? in
            guard !url.lastPathComponent.hasPrefix("."), !known.contains(url.path) else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            return ReceivedFile(id: UUID().uuidString, name: url.lastPathComponent, path: url.path,
                                byteCount: values?.fileSize ?? 0, date: values?.contentModificationDate ?? Date())
        }
        .sorted { $0.date < $1.date }
    }

    /// 답변 속 ```file:이름 코드 블록을 ‘받은 파일’ 폴더에 씁니다. 같은 이름이 있으면 번호를 붙입니다.
    @discardableResult
    func writeFileBlocks(from text: String, conversationID: String) -> [URL] {
        let blocks = FileBlockParser.blocks(in: text)
        guard !blocks.isEmpty else { return [] }
        let directory = outputsDirectory(for: conversationID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for block in blocks {
            var target = directory.appendingPathComponent(block.name)
            var counter = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = (block.name as NSString).deletingPathExtension
                let ext = (block.name as NSString).pathExtension
                target = directory.appendingPathComponent(ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)")
                counter += 1
            }
            if (try? block.content.write(to: target, atomically: true, encoding: .utf8)) != nil { written.append(target) }
        }
        return written
    }
}

/// 답변 텍스트에서 ```file:이름.확장자 … ``` 블록을 뽑습니다. 이름은 한 단어(경로 구분자 없음)만 받습니다.
enum FileBlockParser {
    struct Block: Equatable { var name: String; var content: String }

    static func blocks(in text: String) -> [Block] {
        var result: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```file:"), let name = sanitize(String(line.dropFirst("```file:".count))) {
                var body: [String] = []
                var cursor = index + 1
                var closed = false
                while cursor < lines.count {
                    if lines[cursor].trimmingCharacters(in: .whitespaces) == "```" { closed = true; break }
                    body.append(lines[cursor])
                    cursor += 1
                }
                if closed {
                    result.append(Block(name: name, content: body.joined(separator: "\n") + "\n"))
                    index = cursor + 1
                    continue
                }
            }
            index += 1
        }
        return result
    }

    static func sanitize(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), name.count <= 120 else { return nil }
        return name
    }
}

/// 첨부 파일을 각 연결의 메시지 형식으로 바꿉니다.
enum AttachmentEncoder {
    static let pdfTextLimit = 60_000
    static let zipTextLimit = 200_000
    static let textLikeExtensions: Set<String> = ["txt", "md", "markdown", "json", "swift", "py", "js", "ts", "tsx", "jsx", "html", "htm", "css", "csv", "tsv",
                                                 "yaml", "yml", "xml", "toml", "sh", "zsh", "bash", "m", "h", "c", "cc", "cpp", "hpp", "java", "kt", "kts",
                                                 "rs", "go", "sql", "log", "ini", "cfg", "conf", "plist", "strings", "rb", "php", "gradle", "pbxproj", "entitlements"]

    static func base64(_ attachment: Attachment) -> String {
        (try? Data(contentsOf: attachment.url))?.base64EncodedString() ?? ""
    }

    /// 전사본에 넣는 자리표시자. 실제 base64 는 보낼 때만 만듭니다(기록 파일이 커지지 않게).
    static func placeholder(_ attachment: Attachment) -> JSONValue {
        ["type": "condux_attachment", "id": .string(attachment.id), "name": .string(attachment.name),
         "kind": .string(attachment.kind.rawValue), "path": .string(attachment.path), "byteCount": .number(Double(attachment.byteCount))]
    }

    static func attachment(fromPlaceholder value: JSONValue) -> Attachment? {
        guard value["type"]?.stringValue == "condux_attachment", let path = value["path"]?.stringValue,
              let kind = Attachment.Kind(rawValue: value["kind"]?.stringValue ?? "") else { return nil }
        return Attachment(id: value["id"]?.stringValue ?? UUID().uuidString, name: value["name"]?.stringValue ?? (path as NSString).lastPathComponent,
                          kind: kind, path: path, byteCount: value["byteCount"]?.intValue ?? 0)
    }

    // MARK: Anthropic Messages API / Claude Code stream-json (같은 블록 형식)

    /// 이미지 → image 블록, PDF → document 블록, ZIP → 목록·텍스트 요약 블록.
    static func claudeBlocks(_ attachment: Attachment) -> [JSONValue] {
        switch attachment.kind {
        case .png, .jpeg:
            return [["type": "image", "source": ["type": "base64", "media_type": .string(attachment.kind.mediaType), "data": .string(base64(attachment))]]]
        case .pdf:
            return [["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": .string(base64(attachment))],
                     "title": .string(attachment.name)]]
        case .zip:
            return [["type": "text", "text": .string(zipSummary(attachment))]]
        }
    }

    /// 전사본의 자리표시자를 실제 블록으로 바꿉니다.
    static func expandClaude(_ messages: [JSONValue]) -> [JSONValue] {
        messages.map { message in
            guard var object = message.objectValue, let content = object["content"]?.arrayValue else { return message }
            object["content"] = .array(content.flatMap { block -> [JSONValue] in
                if let attachment = attachment(fromPlaceholder: block) { return claudeBlocks(attachment) }
                return [block]
            })
            return .object(object)
        }
    }

    // MARK: OpenAI Responses API

    static func openAIParts(_ attachment: Attachment) -> [JSONValue] {
        switch attachment.kind {
        case .png, .jpeg:
            return [["type": "input_image", "image_url": .string("data:\(attachment.kind.mediaType);base64,\(base64(attachment))")]]
        case .pdf:
            return [["type": "input_file", "filename": .string(attachment.name), "file_data": .string("data:application/pdf;base64,\(base64(attachment))")]]
        case .zip:
            return [["type": "input_text", "text": .string(zipSummary(attachment))]]
        }
    }

    static func expandOpenAI(_ input: [JSONValue]) -> [JSONValue] {
        input.map { item in
            guard var object = item.objectValue, let content = object["content"]?.arrayValue else { return item }
            object["content"] = .array(content.flatMap { part -> [JSONValue] in
                if let attachment = attachment(fromPlaceholder: part) { return openAIParts(attachment) }
                return [part]
            })
            return .object(object)
        }
    }

    // MARK: 텍스트로 풀기 (도구 없는 Codex 대화, ZIP)

    /// PDFKit 으로 글자를 뽑습니다. 스캔본이면 비어 있을 수 있습니다.
    static func pdfText(_ attachment: Attachment, limit: Int = pdfTextLimit) -> String {
        guard let document = PDFDocument(url: attachment.url) else { return "[\(attachment.name): PDF 를 열 수 없습니다]" }
        let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "[첨부 PDF \(attachment.name) · \(document.pageCount)쪽 · \(attachment.sizeText)]"
        if text.isEmpty { return header + "\n(글자를 뽑지 못했습니다. 스캔 이미지이거나 보호된 파일일 수 있습니다.)" }
        return header + "\n" + clip(text, limit)
    }

    /// ZIP 안의 파일 목록과, 텍스트 파일 내용(상한까지)을 문자열로 만듭니다. `/usr/bin/unzip` 을 씁니다.
    static func zipSummary(_ attachment: Attachment, limit: Int = zipTextLimit) -> String {
        let entries = zipEntries(attachment.url)
        var text = "[첨부 ZIP \(attachment.name) · \(attachment.sizeText) · 항목 \(entries.count)개]\n"
        text += entries.prefix(300).map { "- \($0.name) (\(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)))" }.joined(separator: "\n")
        if entries.count > 300 { text += "\n- … 외 \(entries.count - 300)개" }
        var budget = limit
        var included = 0
        for entry in entries where included < 40 && budget > 0 {
            guard !entry.name.hasSuffix("/"), textLikeExtensions.contains((entry.name as NSString).pathExtension.lowercased()),
                  entry.size <= 400_000, let content = zipEntryText(attachment.url, entry: entry.name) else { continue }
            let piece = clip(content, min(budget, 60_000))
            text += "\n\n### \(entry.name)\n```\n\(piece)\n```"
            budget -= piece.count
            included += 1
        }
        return text
    }

    struct ZipEntry: Equatable { var name: String; var size: Int }

    static func zipEntries(_ url: URL) -> [ZipEntry] {
        guard let output = run("/usr/bin/unzip", ["-l", url.path]) else { return [] }
        // "   길이  날짜 시각   이름" 줄만 고릅니다.
        let pattern = #"^\s*(\d+)\s+\S+\s+\S+\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [ZipEntry] = []
        for line in output.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let name = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard name != "Name", !name.hasPrefix("---") else { continue }
            result.append(ZipEntry(name: name, size: Int(ns.substring(with: match.range(at: 1))) ?? 0))
        }
        return result
    }

    static func zipEntryText(_ url: URL, entry: String) -> String? {
        guard let data = runData("/usr/bin/unzip", ["-p", url.path, entry]), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// 도구 없는 대화용: 이미지는 별도 전달이 안 되면 설명만, PDF/ZIP 은 글자로.
    static func textFallback(_ attachment: Attachment) -> String {
        switch attachment.kind {
        case .png, .jpeg: return "[첨부 이미지 \(attachment.name) · \(attachment.sizeText)]"
        case .pdf: return pdfText(attachment)
        case .zip: return zipSummary(attachment)
        }
    }

    /// 작업 폴더 모드용: AI 가 직접 읽을 수 있도록 경로를 알려 줍니다.
    static func pathNote(_ attachment: Attachment) -> String {
        "[첨부 \(attachment.kind.label) \(attachment.name) · \(attachment.sizeText) · 경로: \(attachment.path)]"
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…(생략, \(text.count - limit)자)" : text
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        runData(executable, arguments).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func runData(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 || !data.isEmpty ? data : nil
    }
}
