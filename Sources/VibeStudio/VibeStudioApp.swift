import SwiftUI
import AppKit

@main
struct ConduxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ScreenshotMode.isActive ? ScreenshotMode.makeSampleModel() : AppModel()

    var body: some Scene {
        let _ = model.appLanguage // 언어가 바뀌면 메뉴도 다시 만듭니다.
        WindowGroup("Condux") {
            Group {
                if ScreenshotMode.scene == "popovers" {
                    HStack(alignment: .top, spacing: 24) { RelayPopover(); FolderPopover() }
                        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(ConduxTheme.canvas)
                } else {
                    ContentView().id(model.appLanguage)
                }
            }
                .environment(model)
                .sheet(isPresented: Binding(get: { model.showQuickGuide }, set: { model.showQuickGuide = $0 })) {
                    QuickGuideSheet().environment(model)
                }
                .tint(ConduxTheme.blue)
                .background(ConduxTheme.canvas)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    appDelegate.model = model
                    ComposerKeyMonitor.install(model: model)
                    if ScreenshotMode.isActive { ScreenshotMode.captureAndExit(model: model) } else { await model.startUp() }
                }
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(tr("새 대화")) { model.startFreshConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.progress.isBusy)
            }
            CommandGroup(after: .sidebar) {
                ForEach(0..<9, id: \.self) { index in
                    Button(tr("대화 \(index + 1)로 이동")) { model.selectConversation(at: index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .disabled(model.progress.isBusy)
                }
            }
            CommandGroup(after: .pasteboard) {
                Button(tr("클립보드에서 첨부")) {
                    Task {
                        guard await model.ensureConversation() else { return }
                        model.pasteAttachments()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.progress.isBusy)
            }
            CommandGroup(replacing: .appSettings) {
                Button(tr("설정…")) { model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
                Button(tr("연결 관리…")) { model.showConnections = true }.keyboardShortcut(",", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button(tr("Condux 빠른 안내")) { model.showQuickGuide = true }
                    .keyboardShortcut("?", modifiers: .command)
                Button(tr("지원 페이지 열기")) { NSWorkspace.shared.open(URL(string: "https://pgup3017.github.io/condux-site/")!) }
                Button(tr("개인정보 처리방침")) { NSWorkspace.shared.open(URL(string: "https://pgup3017.github.io/condux-site/privacy.html")!) }
            }
            CommandGroup(after: .importExport) {
                Button(tr("대화를 마크다운으로 내보내기…")) { if let id = model.selectedID { model.exportConversationMarkdown(id) } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selectedID == nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) {
        model?.flushAndDisconnect()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        AppAppearance.current.apply()
        if ScreenshotMode.isActive, ScreenshotMode.scene == "sandboxcheck" { ScreenshotMode.runSandboxCheck() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Vivid blue against a black workspace. Shared by native controls and custom surfaces.
enum ConduxTheme {
    /// 밝은·어두운 화면에 따라 저절로 바뀌는 색
    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    private static func grey(dark: CGFloat, light: CGFloat) -> Color { adaptive(dark: (dark, dark, dark), light: (light, light, light)) }

    static let blue = adaptive(dark: (0.24, 0.48, 1.0), light: (0.14, 0.40, 0.95))
    static let canvas = adaptive(dark: (0.122, 0.129, 0.149), light: (0.98, 0.98, 0.985))
    static let sidebar = adaptive(dark: (0.094, 0.098, 0.114), light: (0.94, 0.945, 0.955))
    static let surface = adaptive(dark: (0.161, 0.173, 0.2), light: (1, 1, 1))
    /// 칩·작은 버튼 배경
    static let raised = adaptive(dark: (0.2, 0.212, 0.243), light: (0.91, 0.92, 0.935))
    /// 선택한 대화, 사용자 말풍선
    static let selected = adaptive(dark: (0.169, 0.227, 0.361), light: (0.84, 0.89, 0.985))
    static let borderSubtle = adaptive(dark: (0.204, 0.216, 0.247), light: (0.88, 0.885, 0.9))
    static let borderStrong = adaptive(dark: (0.271, 0.286, 0.322), light: (0.78, 0.79, 0.81))
    static let ok = adaptive(dark: (0.298, 0.765, 0.541), light: (0.07, 0.56, 0.33))
    static let warn = adaptive(dark: (0.961, 0.647, 0.141), light: (0.76, 0.45, 0.0))
    static let off = adaptive(dark: (0.353, 0.369, 0.4), light: (0.68, 0.69, 0.71))
    /// 코드 블록
    static let codeBackground = adaptive(dark: (0.075, 0.08, 0.09), light: (0.955, 0.96, 0.97))
    static let codeHeader = adaptive(dark: (0.06, 0.063, 0.072), light: (0.92, 0.925, 0.94))
    /// 승인 카드의 추가·삭제 줄
    static let diffAdd = adaptive(dark: (0.55, 0.9, 0.6), light: (0.05, 0.48, 0.2))
    static let diffRemove = adaptive(dark: (1.0, 0.55, 0.55), light: (0.75, 0.13, 0.13))
    /// 배경 위 글자. 시스템이 흐리게 그리는 것을 막기 위해 명시합니다.
    static let textPrimary = grey(dark: 0.93, light: 0.1)
    static let textSecondary = grey(dark: 0.63, light: 0.36)
    static let textTertiary = grey(dark: 0.46, light: 0.47)
}
