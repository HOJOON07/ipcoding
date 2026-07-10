import SwiftUI

/// HUD 표시 상태 (Phase 1 최소 — raw/refining/ready/error는 Phase 2 §2.5에서 확장).
enum HUDState: Equatable {
    case hidden
    case recording
    case processing
}

/// HUD가 렌더할 상태와 마이크 레벨을 담는 관찰 모델 (TDD §3.8).
/// recording 동안 타이머로 레벨 provider를 폴링해 레벨 미터를 갱신한다.
@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state: HUDState = .hidden
    @Published private(set) var level: Float = 0

    /// 마이크 레벨(0~1) 공급자. 코디네이터가 AudioCapture.currentLevel로 연결한다.
    var levelProvider: (() -> Float)?

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
