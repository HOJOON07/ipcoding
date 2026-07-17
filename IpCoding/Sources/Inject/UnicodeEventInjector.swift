import AppKit
import os

/// 유니코드 직접 주입 (TDD §3.7 옵션, 태스크 3.4) — 클립보드를 건드리기 싫은 사용자용.
/// `CGEventKeyboardSetUnicodeString`은 이벤트당 실을 수 있는 길이가 짧다(UTF-16 20단위
/// 안팎이 안전선 — macos-quirks) → 청크 분할 + 청크 간 1ms 대기. 서러게이트 쌍은 가르지
/// 않는다(갈리면 대상 앱에 깨진 문자). 완성형 한글 문자열은 IME 조합을 거치지 않고 들어간다.
@MainActor
final class UnicodeEventInjector: Injecting {

    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "inject")

    /// 이벤트당 UTF-16 단위 상한 (macos-quirks 안전선).
    private let chunkSize = 20

    func inject(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            logger.error("손쉬운 사용 권한 없음 — 주입 불가")
            throw InjectionError.accessibilityNotAuthorized
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InjectionError.eventSynthesisFailed
        }

        if let front = NSWorkspace.shared.frontmostApplication {
            // 사용 앱 정보는 privacy 마스킹 (리뷰 N3 — 코디네이터의 .private와 정렬).
            logger.info("주입 대상(유니코드): \(front.bundleIdentifier ?? "unknown", privacy: .private)")
        }

        // 대상 앱의 IME 조합 중 상태(한글 미완성 글자)가 마감될 짧은 여유 (macos-quirks).
        try await Task.sleep(for: .milliseconds(50))

        // 개행 → 공백 치환 (TDD §3.7, 사용자 결정 2026-07-18): 키 입력 방식은 bracketed
        // paste 보호가 없어 개행이 터미널에서 Enter로 즉시 실행된다 — 조기 실행 원천 차단.
        let sanitized = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        let units = Array(sanitized.utf16)
        var index = 0
        while index < units.count {
            var end = min(index + chunkSize, units.count)
            // 경계가 서러게이트 쌍의 리드 유닛이면 한 단위 물러선다.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            var chunk = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw InjectionError.eventSynthesisFailed
            }
            // 수정자 상속 차단 (리뷰 W1): 합성 이벤트는 현재 하드웨어 수정자 상태를 상속하므로,
            // 콤보 키(⌘/⌥/⌃)를 아직 쥔 채면 텍스트가 단축키로 해석된다 — flags를 비운다.
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            // keyUp에도 동일 문자열 미러링 — 일부 앱 호환 여유분 (리뷰 N1, 레퍼런스 구현 관례).
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            index = end
            try await Task.sleep(for: .milliseconds(1))  // 청크 간 대기 (TDD §3.7)
        }
        logger.info("[inject] 유니코드 주입 완료 — \(units.count, privacy: .public) UTF-16 units")
    }
}
