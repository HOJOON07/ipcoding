import SwiftUI

/// HUD 내용 뷰 (Phase 1 최소): recording은 마이크 레벨 미터, processing은 스피너.
struct HUDView: View {
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .recording:
                LevelMeterView(level: viewModel.level)
            case .processing:
                ProcessingView()
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.85))
        )
        .frame(minWidth: 160)
    }
}

/// 마이크 입력 레벨에 반응하는 막대 미터.
private struct LevelMeterView: View {
    let level: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
            HStack(spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    let threshold = Float(index + 1) / Float(barCount)
                    Capsule()
                        .fill(level >= threshold * 0.7 ? Color.white : Color.white.opacity(0.25))
                        .frame(width: 5, height: barHeight(for: index))
                }
            }
            .animation(.easeOut(duration: 0.08), value: level)
        }
        .foregroundStyle(.white)
    }

    private func barHeight(for index: Int) -> CGFloat {
        8 + CGFloat(index) * 5
    }
}

/// 처리 중 스피너.
private struct ProcessingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("처리 중…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}
