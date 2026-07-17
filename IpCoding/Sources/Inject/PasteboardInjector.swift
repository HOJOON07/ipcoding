import AppKit
import os

/// 클립보드 경유 주입 (TDD §3.7 기본). 순서 엄수: 백업 → set → ⌘V → 복원.
/// 손쉬운 사용 권한 필요 (CGEvent post). HUD가 key window가 아니어야 대상 앱에 붙는다.
@MainActor
final class PasteboardInjector: Injecting {

    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "inject")

    /// ⌘V post 후 복원까지의 지연 (TDD §3.7·macos-quirks: 250ms 안팎).
    /// 대상 앱의 붙여넣기 읽기 시간 확보 + 사용자 복사 충돌 회피의 균형점.
    private let restoreDelay: Duration = .milliseconds(250)

    func inject(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            logger.error("손쉬운 사용 권한 없음 — 주입 불가")
            throw InjectionError.accessibilityNotAuthorized
        }

        let pasteboard = NSPasteboard.general

        // ① 현재 클립보드 백업 — 문자열만이 아니라 아이템 전체를 보존
        //    (macos-quirks: 이미지·파일 복사 상태를 문자열 복원으로 덮으면 데이터 손실).
        let backup = backupItems(pasteboard)

        // ② 텍스트 set.
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // set 실패 — 백업 복원 후 에러.
            restore(backup, to: pasteboard)
            throw InjectionError.pasteboardWriteFailed
        }
        let changeCountAfterSet = pasteboard.changeCount

        // 대상 앱 로깅 (디버깅용 — HUD가 frontmost가 아님을 보장하는 것이 non-activating 요구의 이유).
        if let front = NSWorkspace.shared.frontmostApplication {
            // 사용 앱 정보는 privacy 마스킹 (3.4 리뷰 N3 — 코디네이터의 .private와 정렬).
            logger.info("주입 대상: \(front.bundleIdentifier ?? "unknown", privacy: .private)")
        }

        // ③ ⌘V post — 실패 시 전사문이 클립보드에 남지 않도록 복원 후 재-throw.
        do {
            try postCommandV()
        } catch {
            restore(backup, to: pasteboard)
            throw error
        }

        // ④ 대상 앱이 클립보드를 읽을 시간 확보 후 복원.
        //    단, set 이후 changeCount가 또 바뀌었으면(사용자가 그 사이 복사) 복원 포기.
        //    ⌘V는 읽기라 changeCount를 바꾸지 않으므로 자기 유발 오탐은 없다.
        try? await Task.sleep(for: restoreDelay)
        if pasteboard.changeCount == changeCountAfterSet {
            restore(backup, to: pasteboard)
            logger.debug("클립보드 복원 완료")
        } else {
            logger.info("클립보드가 주입 후 변경됨 — 복원 포기 (사용자 복사 보호)")
        }
    }

    // MARK: - 클립보드 백업/복원 (아이템 단위)

    private func backupItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        // NSPasteboardItem은 재사용 불가 — 타입별 데이터를 새 아이템에 복제.
        return items.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    // MARK: - ⌘V 합성

    private func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InjectionError.accessibilityNotAuthorized
        }
        let vKeyCode: CGKeyCode = 9  // 'v'

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            throw InjectionError.accessibilityNotAuthorized
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // 대상 앱의 이벤트 스트림에 주입 (annotatedSession = 현재 로그인 세션).
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
