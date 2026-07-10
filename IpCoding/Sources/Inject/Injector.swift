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
}
