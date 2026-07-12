import SwiftUI

/// HUD 내용 뷰 (TDD §3.8). 텍스트 상태는 폭 최대 560pt·4줄 제한.
struct HUDView: View {
    @ObservedObject var viewModel: HUDViewModel

    /// 텍스트 상태(refining/ready)인지 — 확정 폭을 줘야 줄바꿈·4줄 제한이 동작한다.
    private var isTextState: Bool {
        switch viewModel.state {
        case .refining, .ready: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .recording:
                LevelMeterView(level: viewModel.level)
            case .processing:
                ProcessingView()
            case .refining(let raw, let streamed):
                RefiningView(raw: raw, streamed: streamed)
            case .ready(let text, let usedFallback):
                ReadyView(text: text, usedFallback: usedFallback)
            case .error(let message):
                ErrorView(message: message)
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        // 텍스트 상태는 확정 폭 560 — 줄바꿈·lineLimit(4)이 동작하고(리뷰 CRITICAL),
        // 스트리밍 중 폭이 변하지 않아 가로 지터도 없다(W3). 세로만 내용에 맞게(fixedSize V).
        .frame(width: isTextState ? 560 : nil)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.85))
        )
        .fixedSize(horizontal: !isTextState, vertical: true)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            viewModel.onContentSizeChange?(size)
        }
    }
}

/// 세션 텍스트 공통 스타일 (4줄 제한 — TDD §3.8. 페이드 대신 꼬리 말줄임, 폴리시는 §3.8 후속).
private struct SessionText: View {
    let text: String
    var dimmed = false

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(dimmed ? 0.35 : 1))
            .lineLimit(4)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 교정 중: 원문 dim + 스트리밍 텍스트가 타자 치듯 쌓임 (PRD §4 ③).
private struct RefiningView: View {
    let raw: String
    let streamed: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SessionText(text: raw, dimmed: true)
            HStack(spacing: 0) {
                SessionText(text: streamed)
                if streamed.isEmpty {
                    ProgressView().controlSize(.mini).tint(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// 완성 텍스트 + 단축키 힌트 바 (PRD §4 ④). usedFallback이면 "원문 사용" 배지 (TDD §2).
private struct ReadyView: View {
    let text: String
    let usedFallback: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionText(text: text)
            HStack(spacing: 8) {
                if usedFallback {
                    Text("원문 사용")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.85)))
                        .foregroundStyle(.black)
                }
                Text("잠시 후 자동 주입 · Esc 취소 · Tab 원문 사용")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

/// 짧은 에러 배지 (자동 소멸은 HUDController.flashError가 관리).
private struct ErrorView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
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
