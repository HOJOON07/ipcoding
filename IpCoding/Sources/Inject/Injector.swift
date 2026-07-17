import Foundation

/// 텍스트 주입 전략 (TDD §3.7). 기본은 PasteboardInjector, 옵션은 UnicodeEventInjector(3.4).
@MainActor
protocol Injecting {
    func inject(_ text: String) async throws
}

enum InjectionError: Error {
    /// 손쉬운 사용 권한 없음 — CGEvent post 불가. 온보딩으로 유도.
    case accessibilityNotAuthorized
    /// 클립보드에 텍스트 설정 실패.
    case pasteboardWriteFailed
    /// 자기 앱이 frontmost — 자체 창(사전 편집 등)에 ⌘V가 꽂히는 사고 차단 (TDD §3.7 가드).
    /// 코디네이터의 주입 선행 검사에서 던진다 (Injecting 구현 공통 규칙, 태스크 2.8).
    case selfIsFrontmost
}
