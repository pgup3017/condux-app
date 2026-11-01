import AppKit
import CoreText
import Foundation

/// 테스트용 작은 PNG·PDF·ZIP 파일을 만듭니다.
enum TestFiles {
    /// 단색 PNG (기본 빨강 64×64)
    static func png(at url: URL, color: NSColor = .red, size: Int = 64) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    /// 글자 한 줄이 들어간 1쪽짜리 PDF
    static func pdf(at url: URL, text: String) throws {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        try data.write(to: url)
    }

    /// 가짜 Claude CLI: 인수를 args.txt 에 적고, 사용자 메시지마다 "답변" 한 턴을 돌려줍니다 (AppModelClaudeFlowTests 와 같은 모양).
    static func fakeClaudeCLI(at executable: URL) throws {
        let fixture = #"""
        #!/bin/sh
        printf '%s\n' "$@" > "$(dirname "$0")/args.txt"
        if [ "$1" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
        if [ "$1" = "auth" ]; then echo '{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max", "email": "x@example.com"}'; exit 0; fi
        exec /usr/bin/python3 -u -c '
        import json, sys
        sid = None
        argv = open(sys.argv[1]).read().split("\n")
        for i, a in enumerate(argv):
            if a in ("--session-id", "--resume"): sid = argv[i+1]
        def out(o): print(json.dumps(o, ensure_ascii=False), flush=True)
        out({"type":"system","subtype":"init","session_id":sid,"model":"fake-model","tools":[],"mcp_servers":[]})
        for line in sys.stdin:
            obj = json.loads(line)
            if obj.get("type") == "user":
                out({"type":"stream_event","session_id":sid,"api_message_id":"msg_1","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"답변"}}})
                out({"type":"assistant","session_id":sid,"message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"답변"}]}})
                out({"type":"result","subtype":"success","is_error":False,"terminal_reason":"completed","session_id":sid,"result":"답변","usage":{"input_tokens":10,"output_tokens":3}})
        ' "$(dirname "$0")/args.txt"
        """#
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    /// 주어진 파일들(이름 → 내용)을 담은 ZIP. `/usr/bin/zip` 사용.
    static func zip(at url: URL, files: [String: String]) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent("zip-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, content) in files {
            let file = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", url.path] + files.keys.sorted()
        process.currentDirectoryURL = staging
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: staging)
    }
}
