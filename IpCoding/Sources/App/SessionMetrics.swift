import Foundation

/// 한 세션의 구간별 타이밍 (TDD §6). T0 = hotkeyUp 시각 기준 경과.
struct SessionMetrics {
    var tRaw: Duration?         // 전사 완료 (원문 확보)
    var tFirstToken: Duration?  // 교정 첫 토큰
    var tReady: Duration?       // 교정 완성 (폴백 포함)
    var tInject: Duration?      // 주입 완료
    var usedFallback = false
}

/// 최근 20세션 타이밍과 Esc 취소율을 메모리에만 보관 (TDD §6 — 디스크 기록 없음).
/// 디버그 메뉴가 p50/p90을 읽는다. Esc 취소율은 Phase 2 완료 기준("측정 시작")의 도그푸딩 지표.
@MainActor
final class MetricsStore {

    static let capacity = 20

    private(set) var recent: [SessionMetrics] = []
    /// 주입까지 완료된 세션 수 (누적).
    private(set) var completedCount = 0
    /// Esc로 취소된 세션 수 (refining·awaitingInjection 중 취소, 누적).
    private(set) var escCancelCount = 0

    func recordCompleted(_ metrics: SessionMetrics) {
        recent.append(metrics)
        if recent.count > Self.capacity { recent.removeFirst() }
        completedCount += 1
    }

    func recordEscCancel() {
        escCancelCount += 1
    }

    /// Esc 취소율 = 취소 / (완료 + 취소). 세션이 없으면 nil.
    var escCancelRate: Double? {
        let total = completedCount + escCancelCount
        guard total > 0 else { return nil }
        return Double(escCancelCount) / Double(total)
    }

    /// 최근 세션들의 특정 구간 백분위 (nearest-rank). 값이 없으면 nil.
    func percentile(_ p: Double, of keyPath: KeyPath<SessionMetrics, Duration?>) -> Duration? {
        let values = recent.compactMap { $0[keyPath: keyPath] }.sorted()
        guard !values.isEmpty else { return nil }
        let rank = max(1, Int((p * Double(values.count)).rounded(.up)))
        return values[rank - 1]
    }
}

extension Duration {
    /// "0.52s" 형식 (디버그 메뉴 표시용).
    var displaySeconds: String {
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
    }
}
