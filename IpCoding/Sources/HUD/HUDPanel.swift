import AppKit
import SwiftUI

/// 상태 HUD 패널 (TDD §3.8). **절대 key window가 되지 않는다** — 포커스를 뺏으면 주입 대상이
/// 사라진다(macos-quirks). non-activating + becomesKeyOnlyIfNeeded + makeKey 호출 금지.
@MainActor
final class HUDController {

    let viewModel = HUDViewModel()
    private var panel: NSPanel?

    /// 화면 하단에서의 여백 (TDD §3.8: 하단 중앙, 120pt).
    private let bottomMargin: CGFloat = 120

    /// 상태를 갱신하고 필요 시 패널을 표시/숨김.
    func update(_ state: HUDState) {
        viewModel.setState(state)
        if state == .hidden {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        let panel = ensurePanel()
        reposition(panel)
        // orderFrontRegardless: 활성화 없이 앞으로 (makeKeyAndOrderFront 금지 — key window화 방지).
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true  // HUD는 표시 전용 — 클릭 통과.

        let hosting = NSHostingView(rootView: HUDView(viewModel: viewModel))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// 고정 HUD 크기. 상태 전이 직후 SwiftUI 재레이아웃 전에 fittingSize를 읽으면 이전 상태
    /// 크기로 잡히는 글리치가 있어, Phase 1 최소 HUD는 고정 크기로 중앙을 안정 유지한다.
    private let hudSize = NSSize(width: 220, height: 64)

    /// 마우스가 있는 화면 하단 중앙에 배치 (멀티모니터: NSScreen.main은 key window 기준이라 부적합).
    private func reposition(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else { return }

        panel.setContentSize(hudSize)
        let screenFrame = screen.frame
        let x = screenFrame.midX - hudSize.width / 2
        let y = screenFrame.minY + bottomMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
