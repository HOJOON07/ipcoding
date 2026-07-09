import AppKit

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
    }
}
