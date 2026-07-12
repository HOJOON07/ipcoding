import SwiftUI

/// HUD 표시 상태 (TDD §3.8 상태별 뷰 — 태스크 2.5 확장).
enum HUDState: Equatable {
    case hidden
    case recording
    /// 전사 중 스피너.
    case processing
    /// 교정 중: 원문 dim + 스트리밍 텍스트가 타자 치듯 쌓임 (PRD §4 ③).
    case refining(raw: String, streamed: String)
    /// 완성: 원문 dim과 교정 결과를 병기 (주입 전 비교 — 원칙 4) + 힌트 칩.
    /// usedFallback이면 "원문 사용" 배지 (llmTimeout/Error — TDD §2).
    case ready(raw: String, text: String, usedFallback: Bool)
    /// 짧은 에러 배지 (예: sttFailed "인식하지 못했어요" 1.5s — TDD §5).
    case error(String)
    /// 주입 후 결과 유지 카드: 원문·교정 병기 + ✓ — 사용자가 비교를 충분히 관찰하도록
    /// 5s 유지 후 소멸 (도그푸딩 피드백 2026-07-12).
    case injected(raw: String, text: String)
}

/// HUD가 렌더할 상태와 마이크 레벨을 담는 관찰 모델 (TDD §3.8).
/// recording 동안 타이머로 레벨 provider를 폴링해 레벨 미터를 갱신한다.
@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state: HUDState = .hidden
    @Published private(set) var level: Float = 0

    /// 마이크 레벨(0~1) 공급자. 코디네이터가 AudioCapture.currentLevel로 연결한다.
    var levelProvider: (() -> Float)?
    /// 콘텐츠 크기 변경 통지 — HUDController가 패널 크기·위치를 갱신한다 (동적 크기, 2.5).
    var onContentSizeChange: ((CGSize) -> Void)?

    private var levelTimer: Timer?

    func setState(_ newState: HUDState) {
        state = newState
        if newState == .recording {
            startLevelPolling()
        } else {
            stopLevelPolling()
            level = 0
        }
    }

    /// refining 중 스트리밍 텍스트 갱신 (TDD §2 token(t) → HUD.append). 누적 스냅샷을 받아
    /// 더 긴 것만 반영 — Task 홉 순서가 뒤바뀌어도 표시가 뒤로 가지 않는다. refining이 아니면
    /// 무시(늦은 스냅샷이 ready/hidden을 오염시키지 않음).
    func setStreamedText(_ full: String) {
        if case .refining(let raw, let current) = state, full.count > current.count {
            state = .refining(raw: raw, streamed: full)
        }
    }

    private func startLevelPolling() {
        guard levelTimer == nil else { return }
        // ~30fps. 부드러운 감쇠를 위해 이전 값과 보간. 타이머는 메인 런루프에서 돌므로
        // MainActor.assumeIsolated로 홉 없이 진입 (scheduledTimer는 스케줄한 런루프에서 실행).
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let target = self.levelProvider?() ?? 0
                // 상승은 즉시, 하강은 완만 (레벨 미터의 자연스러운 반응).
                self.level = target > self.level ? target : self.level * 0.8 + target * 0.2
            }
        }
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}
