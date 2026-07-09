import AppKit
import os

/// 앱 엔트리. NSStatusItem(메뉴바)과 생명주기를 소유한다 (TDD §1).
/// LSUIElement=YES — Dock·앱 전환기에 나타나지 않는 메뉴바 상주 앱.
@main
@MainActor
final class IpCodingApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = IpCodingApp()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem?
    private let hotkeyManager = HotkeyManager()
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: "입코딩"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "입코딩 v0.1 (Phase 1)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "종료",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        item.menu = menu

        statusItem = item

        startHotkey()
    }

    /// 태스크 1.2: 이벤트 탭 시작. 코디네이터(1.8) 전까지는 델리게이트를 앱이 맡아 로그로 검증.
    private func startHotkey() {
        hotkeyManager.delegate = self
        if !hotkeyManager.start() {
            // 권한 없음 — 시스템 다이얼로그로 유도 후, 부여되면 재시작 필요 (온보딩은 태스크 3.1).
            _ = HotkeyManager.promptForAccessibilityIfNeeded()
            logger.warning("손쉬운 사용 권한 미부여 — 시스템 설정에서 부여 후 앱 재시작 필요")
        }
    }
}

// MARK: - HotkeyManagerDelegate (태스크 1.8에서 SessionCoordinator로 이관)

extension IpCodingApp: HotkeyManagerDelegate {
    func hotkeyDown() {
        logger.info("[hotkey] DOWN")
    }

    func hotkeyUp(heldFor duration: TimeInterval) {
        logger.info("[hotkey] UP — \(String(format: "%.2f", duration), privacy: .public)s 홀드")
    }

    func hotkeyCancelled() {
        logger.info("[hotkey] CANCELLED (디바운스)")
    }
}
