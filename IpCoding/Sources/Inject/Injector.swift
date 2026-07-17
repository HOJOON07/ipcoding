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
    /// CGEvent/CGEventSource 생성 실패 (유니코드 주입 — 태스크 3.4).
    case eventSynthesisFailed
}

/// 주입 방식 (설정 — 태스크 3.4, TDD §3.7). UserDefaults 키 "injectionMethod".
enum InjectionMethod: String, CaseIterable {
    /// 클립보드 경유 ⌘V (기본) — 빠르고 안정적, 클립보드는 백업·복원.
    case pasteboard
    /// 유니코드 직접 입력 — 클립보드 미사용, 긴 텍스트는 다소 느림(청크 분할).
    case unicode

    var displayName: String {
        switch self {
        case .pasteboard: return "클립보드 (⌘V, 기본)"
        case .unicode: return "유니코드 직접 입력 (클립보드 미사용)"
        }
    }
}

/// 설정에 따라 주입기를 전환하는 라우터 (태스크 3.4). 코디네이터는 Injecting 하나만 알고,
/// 방식 선택은 앱 구성 계층의 책임 — 코디네이터 단방향 규칙 유지.
@MainActor
final class InjectorRouter: Injecting {
    var method: InjectionMethod = .pasteboard
    private let pasteboard = PasteboardInjector()
    private let unicode = UnicodeEventInjector()

    func inject(_ text: String) async throws {
        switch method {
        case .pasteboard: try await pasteboard.inject(text)
        case .unicode: try await unicode.inject(text)
        }
    }
}
