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

    /// refining 스트리밍 누적 텍스트 전달 (TDD §2 token(t) → HUD.append).
    func setStreamedText(_ full: String) {
        viewModel.setStreamedText(full)
    }

    /// 마지막 flashError의 세대 — 같은 메시지가 연달아 떠도 이전 타이머가 새 표시를 못 죽이게 한다.
    private var flashGeneration = 0

    /// 에러 배지를 duration 동안 표시 후 자동 소멸 (TDD §5 "1.5초 표시 후 소멸").
    /// 소멸 시점에 다른 상태(새 세션의 recording, 새 flash)면 건드리지 않는다.
    func flashError(_ message: String, duration: Duration) {
        flashGeneration += 1
        let generation = flashGeneration
        update(.error(message))
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            if generation == self.flashGeneration, self.viewModel.state == .error(message) {
                self.update(.hidden)
            }
        }
    }

    /// 세션 동안 고정할 화면 — 표시 시점에 마우스가 있는 화면으로 정하고, 스트리밍 리사이즈
    /// 중 마우스가 다른 모니터로 넘어가도 HUD가 점프하지 않는다.
    private var sessionScreen: NSScreen?

    private func show() {
        let panel = ensurePanel()
        if !panel.isVisible {
            sessionScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        reposition(panel)
        // orderFrontRegardless: 활성화 없이 앞으로 (makeKeyAndOrderFront 금지 — key window화 방지).
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        sessionScreen = nil
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

        // SwiftUI가 렌더 후 실제 크기를 보고하면 패널을 맞춘다 (스트리밍 중 실시간 성장).
        // hidden(EmptyView)의 축소 보고는 무시 — 다음 show()가 stale 소형 크기로 시작하는 글리치 방지.
        viewModel.onContentSizeChange = { [weak self] size in
            guard let self, let panel = self.panel, self.viewModel.state != .hidden else { return }
            let newSize = NSSize(width: size.width, height: size.height)
            if newSize != self.contentSize {
                self.contentSize = newSize
                if panel.isVisible { self.reposition(panel) }
            }
        }

        self.panel = panel
        return panel
    }

    /// 현재 콘텐츠 크기 — SwiftUI가 onGeometryChange로 보고 (2.5 동적 크기: 텍스트 상태는
    /// 내용에 따라 자람. 전이 직후 fittingSize를 동기로 읽는 방식의 stale 글리치를 회피).
    private var contentSize = NSSize(width: 220, height: 64)

    /// 세션 화면(표시 시점 마우스 위치 기준) 하단 중앙에 배치. NSScreen.main은 key window
    /// 기준이라 부적합(macos-quirks). 하단 앵커 고정 — 높이가 자라도 위로만 자란다.
    private func reposition(_ panel: NSPanel) {
        let screen = sessionScreen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }

        panel.setContentSize(contentSize)
        let screenFrame = screen.frame
        let x = screenFrame.midX - contentSize.width / 2
        let y = screenFrame.minY + bottomMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
