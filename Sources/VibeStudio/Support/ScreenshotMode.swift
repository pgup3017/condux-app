import AppKit
import SwiftUI

/// 앱스토어 스크린샷용. 환경변수 `CONDUX_SCREENSHOT=<저장 경로.png>` 로 실행하면
/// 실제 기록·설정·키체인을 건드리지 않는 샘플 데이터로 창을 띄우고, 창 내용을 PNG 로 저장한 뒤 종료합니다.
/// 화면 녹화 권한이 필요 없습니다(앱이 자기 뷰를 직접 그립니다).
enum ScreenshotMode {
    static var outputPath: String? { ProcessInfo.processInfo.environment["CONDUX_SCREENSHOT"] }
    static var isActive: Bool { outputPath != nil }
    /// 찍을 화면: conversation(기본), start, connections, popovers
    static var scene: String { ProcessInfo.processInfo.environment["CONDUX_SCREENSHOT_SCENE"] ?? "conversation" }

    /// 샘플 데이터가 든 AppModel. 임시 폴더·임시 UserDefaults·메모리 키 저장소를 씁니다.
    @MainActor
    static func makeSampleModel() -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("condux-screenshot-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "condux-screenshot-\(UUID().uuidString)") ?? .standard
        let secrets = InMemorySecretStore()
        secrets.write("claude-api-key", value: "sk-ant-sample")
        secrets.write("openai-api-key", value: "sk-openai-sample")
        let model = AppModel(store: ConversationStore(directory: directory), defaults: defaults,
                             secrets: secrets, apiTransport: URLSessionTransport())
        model.claudeAPIModel = "claude-opus-5-5"
        model.claudeAPIDefaultBudgetUSD = 1.0
        model.showInspector = false
        model.githubStatus = .loggedIn("octocat")

        model.openAIAPIModel = "gpt-6.1-sol"
        model.relayReviewer = .openAIAPI
        model.relayMaxRounds = 3

        let now = Date()
        func stored(_ id: String, _ kind: ChatEntry.Kind, _ text: String, title: String = "", status: String = "",
                    attachments: [String] = []) -> StoredMessage {
            StoredMessage(id: id, role: kind, title: title, text: text, status: status, attachmentNames: attachments.isEmpty ? nil : attachments)
        }
        // 받은 파일 미리보기용 샘플 파일
        let outputs = directory.appendingPathComponent("outputs/api-sample-1", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        let received = outputs.appendingPathComponent("ImageLoader.swift")
        try? """
        import AppKit

        /// 디코딩한 이미지를 메모리에 두는 작은 로더
        final class ImageLoader {
            static let shared = ImageLoader()
            private let cache = NSCache<NSURL, NSImage>()
            func image(for url: URL) async -> NSImage? { /* … */ nil }
        }
        """.write(to: received, atomically: true, encoding: .utf8)
        let english = ProcessInfo.processInfo.environment["CONDUX_LANGUAGE"] == "en"
        func t(_ korean: String, _ other: String) -> String { english ? other : korean }
        let main = StoredConversation(
            id: "api-sample-1", provider: .claudeAPI, title: t("SwiftUI 리스트가 끊기는 이유", "Why my SwiftUI list stutters"), createdAt: now.addingTimeInterval(-3600),
            updatedAt: now, messages: [
                stored("u1", .user, t("SwiftUI List 가 스크롤할 때 뚝뚝 끊겨. 요즘 권장 방법도 찾아보고 어디부터 볼지 알려 줘.",
                                      "My SwiftUI List stutters while scrolling. Look up the current guidance and tell me where to start.")),
                stored("t1", .activity, t("이미지 디코딩과 셀 식별자를 먼저 확인한다.", "Check image decoding and cell identity first."), title: "생각 정리", status: "완료"),
                stored("w1", .activity, "SwiftUI List performance image decoding", title: "웹 검색", status: "완료"),
                stored("a1", .assistant, t("""
                세 군데를 순서대로 보면 됩니다.

                1. **이미지 디코딩 위치** — 셀 `body` 안에서 이미지를 만들면 스크롤마다 메인 스레드가 막힙니다.
                2. **셀 identity** — `ForEach(items, id: \\.self)` 는 데이터가 조금만 바뀌어도 셀을 다시 만듭니다.
                3. **셀 안의 무거운 계산** — 정렬과 포매터 생성은 `body` 밖으로 뺍니다.

                **출처**
                - [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
                """, """
                Check these three things in order.

                1. **Where images decode** — Creating images inside a cell's `body` blocks the main thread on every scroll.
                2. **Cell identity** — `ForEach(items, id: \\.self)` rebuilds cells whenever the data changes slightly.
                3. **Heavy work in cells** — Move sorting and formatter creation out of `body`.

                **Sources**
                - [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
                """)),
                stored("u2", .user, t("캐시 로더를 만들어 줘. 지금 셀 코드 캡처 붙일게.", "Build me a cache loader. Here's a capture of my cell."), attachments: ["ListCell.png"]),
                stored("r0", .activity, t("캐시 로더를 만들고 셀에 적용해 줘", "Build a cache loader and use it in the cell"), title: "릴레이 시작 · 구현 Claude API → 검토 OpenAI API · 최대 3회", status: "완료"),
                stored("a2", .assistant, t("""
                디코딩한 이미지를 메모리에 두는 로더입니다.

                ```swift
                final class ImageLoader {
                    static let shared = ImageLoader()
                    private let cache = NSCache<NSURL, NSImage>()
                }
                ```
                """, """
                This loader keeps decoded images in memory.

                ```swift
                final class ImageLoader {
                    static let shared = ImageLoader()
                    private let cache = NSCache<NSURL, NSImage>()
                }
                ```
                """)),
                stored("f1", .file, received.path, title: "ImageLoader.swift", status: "312 bytes"),
                stored("r1", .activity, t("APPROVED 요청대로 구현됐습니다.", "APPROVED Implemented as requested."), title: "검토자 의견 · OpenAI API · 라운드 1/3", status: "승인"),
                stored("r2", .activity, t("라운드 1/3에서 끝났습니다.", "Finished in round 1 of 3."), title: "릴레이 완료 · 검토자 승인 (라운드 1)", status: "완료"),
            ], apiBudgetUSD: 1.0, apiSpentUSD: 0.0531)
        let second = StoredConversation(
            id: "api-sample-2", provider: .openAIAPI, title: t("앱 출시 전 체크리스트", "App launch checklist"), createdAt: now.addingTimeInterval(-9000),
            updatedAt: now.addingTimeInterval(-7200), messages: [], apiBudgetUSD: 1.0, apiSpentUSD: 0.12)
        let third = StoredConversation(
            id: "api-sample-3", provider: .claudeAPI, title: t("커밋 메시지 다듬기", "Polish a commit message"), createdAt: now.addingTimeInterval(-100000),
            updatedAt: now.addingTimeInterval(-90000), messages: [], apiBudgetUSD: 1.0, apiSpentUSD: 0.03)
        model.conversations = [main, second, third]
        model.conversations[0].usage = ConversationUsage(contextTokens: 184_200, contextWindow: 1_000_000,
                                                         totalInputTokens: 412_800, totalOutputTokens: 9_560)
        if scene == "popovers" {
            model.conversations[0].workspacePath = "/Users/sample/Projects/MyApp"
            model.buildCommandDraft = "xcodebuild -scheme MyApp build"
        }
        model.select("api-sample-1")
        if scene == "start" { model.startFreshConversation() }
        if scene == "connections" { model.showConnections = true }
        if scene == "settings" { model.showSettings = true }
        model.progress.state = .completed
        model.progress.phase = "완료"
        model.tokenSummary = "토큰 입력 1,842 · 출력 356"
        model.relay = RelayState(conversationID: "api-sample-1", task: t("캐시 로더를 만들고 셀에 적용해 줘", "Build a cache loader and use it in the cell"), reviewer: .openAIAPI,
                                 maxRounds: 3, round: 1, phase: .done, summary: "검토자 승인 (라운드 1)")
        return model
    }

    /// 샌드박스 안에서 파일 선택 창과 ZIP 읽기가 되는지 단계마다 표준 오류로 보고하고 끝냅니다. 파일을 고르지는 않습니다.
    @MainActor
    static func runSandboxCheck() {
        func report(_ text: String) { FileHandle.standardError.write(Data("SANDBOX-CHECK \(text)\n".utf8)) }
        report("sandbox=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
        let panel = NSOpenPanel()
        panel.begin { _ in }
        report("open.begin returned")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            report("open.visible=\(panel.isVisible)")
            // 창이 하나도 없으면 닫는 순간 앱이 끝나므로 열어 둔 채로 다음 단계로 갑니다.
            let saved = NSSavePanel()
            saved.begin { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                report("save.visible=\(saved.isVisible)")
                DispatchQueue.global().async {
                    let folder = FileManager.default.temporaryDirectory
                    let source = folder.appendingPathComponent("check.txt")
                    let zip = folder.appendingPathComponent("check.zip")
                    try? "hello".write(to: source, atomically: true, encoding: .utf8)
                    try? FileManager.default.removeItem(at: zip)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    process.arguments = ["-qj", zip.path, source.path]
                    try? process.run()
                    process.waitUntilExit()
                    report("zip.made=\(FileManager.default.fileExists(atPath: zip.path))")
                    report("zip.entries=\(AttachmentEncoder.zipEntries(zip).map(\.name))")
                    exit(0)
                }
            }
        }
    }

    /// 입력창에 진짜 키 이벤트를 보내 줄바꿈과 이미지 붙여넣기를 확인합니다. 사용자의 클립보드는 건드리지 않습니다.
    @MainActor
    private static func runKeyCheck(model: AppModel) {
        func report(_ text: String) { FileHandle.standardError.write(Data("KEY-CHECK \(text)\n".utf8)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { report("창을 찾지 못했습니다"); exit(1) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            report("responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "없음") focused=\(model.composerIsFocused)")
            let board = NSPasteboard(name: NSPasteboard.Name("condux-keycheck"))
            board.clearContents()
            let image = NSImage(size: NSSize(width: 4, height: 4))
            image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
            board.writeObjects([image])
            ComposerKeyMonitor.pasteboard = board
            func press(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
                NSApp.postEvent(event, atStart: false)
            }
            press("a", 0)
            press("\r", 36, .shift)
            press("b", 11)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                report("focused=\(model.composerIsFocused) draft=\(model.draft.debugDescription) sent=\(model.progress.isBusy)")
                if let editor = window.firstResponder as? NSTextView {
                    editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    press("\r", 36, .shift)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    report("afterMarked draft=\(model.draft.debugDescription)")
                    let before = model.pendingAttachments.count
                    press("v", 9, .command)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        report("command-v attachments +\(model.pendingAttachments.count - before) draft=\(model.draft.debugDescription)")
                        press("v", 9, .control)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            report("control-v attachments +\(model.pendingAttachments.count - before) notice=\(model.notice ?? "")")
                            board.clearContents()
                            exit(0)
                        }
                    }
                }
            }
        }
    }

    /// 사용량 팝오버 내용만 PNG 로 저장합니다.
    @MainActor
    private static func captureUsageDetails(model: AppModel, path: String) {
        let host = NSHostingView(rootView: UsageDetails().environment(model).background(ConduxTheme.surface))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Data("스크린샷 저장: \(path)\n".utf8))
            }
            exit(0)
        }
    }

    /// 이벤트 로그를 여는 동안 왼쪽 목록과 창이 움직이는지 재서 표준 오류로 보고합니다.
    @MainActor
    private static func runLogPanelCheck(model: AppModel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let root = window.contentView?.superview else {
                FileHandle.standardError.write(Data("LOG-CHECK 창을 찾지 못했습니다\n".utf8)); exit(1)
            }
            if let width = ProcessInfo.processInfo.environment["CONDUX_LOGCHECK_WIDTH"].flatMap(Double.init) {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
                window.layoutIfNeeded()
            }
            func splits(in view: NSView) -> [NSSplitView] {
                (view as? NSSplitView).map { [$0] } .map { $0 + view.subviews.flatMap(splits(in:)) } ?? view.subviews.flatMap(splits(in:))
            }
            func measure() -> String {
                let columns = splits(in: root).map { split in
                    split.arrangedSubviews.map { column -> String in
                        let frame = column.convert(column.bounds, to: nil)
                        return "\(Int(frame.minX))+\(Int(frame.width))"
                    }.joined(separator: ",")
                }.joined(separator: " / ")
                return "columns[\(columns)] window w=\(Int(window.frame.width))"
            }
            // 왼쪽 목록 자리의 실제 그림이 바뀌는지도 비교합니다.
            let left = NSRect(x: 0, y: 0, width: 250, height: root.bounds.height)
            func leftPicture() -> Int {
                guard let rep = root.bitmapImageRepForCachingDisplay(in: left) else { return 0 }
                root.cacheDisplay(in: left, to: rep)
                return rep.tiffRepresentation?.hashValue ?? 0
            }
            var pictures = [leftPicture()]
            var seen = [measure()]
            model.showInspector = true
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let now = measure()
                    if seen.last != now { seen.append(now) }
                    let picture = leftPicture()
                    if pictures.last != picture { pictures.append(picture) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                timer.invalidate()
                FileHandle.standardError.write(Data("LOG-CHECK inspector=\(model.showInspector) changes=\(seen.count - 1) leftPictureChanges=\(pictures.count - 1)\n\(seen.prefix(3).joined(separator: "\n"))\n...\n\(seen.suffix(2).joined(separator: "\n"))\n".utf8))
                let target = root
                if let path = outputPath, let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) {
                    target.cacheDisplay(in: target.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(firstScrollView(in:)).first
    }

    /// 창이 그려진 뒤 PNG 로 저장하고 앱을 종료합니다.
    @MainActor
    static func captureAndExit(model: AppModel, after delay: TimeInterval = 2.5) {
        guard let path = outputPath else { return }
        if scene == "sandboxcheck" { return }
        if scene == "logcheck" { runLogPanelCheck(model: model); return }
        if scene == "keycheck" { runKeyCheck(model: model); return }
        if scene == "usage" { captureUsageDetails(model: model, path: path); return }
        if let switched = ProcessInfo.processInfo.environment["CONDUX_SWITCH_APPEARANCE"].flatMap(AppAppearance.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) { switched.apply() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView else {
                FileHandle.standardError.write(Data("스크린샷: 창을 찾지 못했습니다\n".utf8))
                NSApp.terminate(nil); return
            }
            // 앱스토어 권장 비율 16:10. 포인트 1440×900 → 레티나에서 2880×1800 픽셀.
            var frame = window.frame
            frame.size = NSSize(width: 1440, height: 900 + (window.frame.height - view.frame.height))
            window.setFrame(frame, display: true)
            window.layoutIfNeeded()
            if ProcessInfo.processInfo.environment["CONDUX_SCREENSHOT_TOOLBAR"] != nil {
                NSApp.activate(ignoringOtherApps: true) // 제목 줄과 신호등 버튼을 활성 상태로 찍습니다.
                window.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if ProcessInfo.processInfo.environment["CONDUX_SCREENSHOT_SCROLL_END"] != nil, let scroll = firstScrollView(in: window.attachedSheet?.contentView ?? view) {
                    scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView?.isFlipped == true ? (scroll.documentView?.frame.height ?? 0) : 0))
                }
                let withToolbar = ProcessInfo.processInfo.environment["CONDUX_SCREENSHOT_TOOLBAR"] != nil
                let target = window.attachedSheet?.contentView ?? (withToolbar ? view.superview ?? view : view)
                guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { NSApp.terminate(nil); return }
                target.cacheDisplay(in: target.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    FileHandle.standardError.write(Data("스크린샷 저장: \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))\n".utf8))
                }
                exit(0) // 시트가 열려 있으면 NSApp.terminate 가 멈춥니다.
            }
        }
    }
}
