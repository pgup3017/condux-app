import AppKit
import Foundation
import UserNotifications

/// 앱이 뒤에 있을 때만 macOS 알림을 띄우고 Dock 아이콘을 튀게 합니다.
/// 테스트(번들 없는 프로세스)에서는 아무것도 하지 않습니다.
enum Notifier {
    /// 테스트에서 끌 수 있게 열어 둡니다.
    nonisolated(unsafe) static var isEnabled = Bundle.main.bundleIdentifier != nil && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    nonisolated(unsafe) private static var requested = false
    /// 마지막으로 보낸 알림 (테스트·디버그 확인용)
    nonisolated(unsafe) private(set) static var lastSent: (title: String, body: String)?

    @MainActor
    static func notify(title rawTitle: String, body rawBody: String, force: Bool = false) {
        let title = tr(rawTitle), body = tr(rawBody)
        // NSApp 이 없으면(테스트·명령줄) 활성 상태로 보고 알림을 보내지 않습니다.
        let application: NSApplication? = NSApp
        let isActive = application?.isActive ?? true
        guard force || !isActive else { return }
        lastSent = (title, body)
        guard isEnabled else { return }
        application?.requestUserAttention(.informationalRequest)
        let center = UNUserNotificationCenter.current()
        if !requested {
            requested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
