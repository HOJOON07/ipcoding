import SwiftUI

/// 브랜드 그라데이션 (Siri풍 인디고→퍼플). 오브 채움·글로우·카드 테두리에 공통 사용.
enum HUDStyle {
    static let gradientColors = [
        Color(red: 0.37, green: 0.36, blue: 0.92),   // 인디고
        Color(red: 0.62, green: 0.33, blue: 0.96),   // 바이올렛
        Color(red: 0.78, green: 0.36, blue: 0.95),   // 퍼플
    ]
    static var gradient: LinearGradient {
        LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let orbSize: CGFloat = 64
    static let cardWidth: CGFloat = 560
    static let glowColor = Color(red: 0.62, green: 0.33, blue: 0.96)
    /// 글로우가 퍼질 투명 여백 — 패널 경계에서 블러가 사각형으로 잘리는 아티팩트 방지.
    static let glowPadding: CGFloat = 32
}

/// HUD 내용 뷰 (TDD §3.8 리디자인 — 모핑 오브). 오브(녹음·처리) ↔ 카드(텍스트 단계)가
/// 하나의 컨테이너에서 스프링 모핑으로 전환된다. 우상단 앵커는 HUDController가 담당.
struct HUDView: View {
    @ObservedObject var viewModel: HUDViewModel

    /// 크기 클래스: 오브(녹음·처리, 64pt 원) / 카드(텍스트 단계, 560pt — 원칙 4 미리보기) /
    /// 배지(완료·에러 — 내용 크기의 컴팩트 필).
    private enum SizeClass { case orb, card, badge }

    private var sizeClass: SizeClass {
        switch viewModel.state {
        case .recording, .processing: return .orb
        case .refining, .ready, .injected: return .card
        case .error, .hidden: return .badge
        }
    }

    private var cornerRadius: CGFloat {
        switch sizeClass {
        case .orb: return HUDStyle.orbSize / 2
        case .card: return 20
        case .badge: return 14
        }
    }

    var body: some View {
        content
            .frame(width: sizeClass == .card ? HUDStyle.cardWidth : (sizeClass == .orb ? HUDStyle.orbSize : nil))
            .frame(minHeight: sizeClass == .orb ? HUDStyle.orbSize : nil)
            .background(backgroundShape)
            // 글로우 여백 — 그림자·블러가 패널 경계 안에서 자연 감쇠하도록 (사각 잘림 방지).
            .padding(HUDStyle.glowPadding)
            .fixedSize(horizontal: sizeClass != .card, vertical: true)
            // 상태 전환(오브↔카드↔배지 크기·모서리·내용)이 스프링으로 모핑된다.
            .animation(.spring(duration: 0.35, bounce: 0.25), value: viewModel.state)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                viewModel.onContentSizeChange?(size)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .recording:
            OrbWaveformView(level: viewModel.level)
                .frame(width: HUDStyle.orbSize, height: HUDStyle.orbSize)
                .transition(.opacity)
        case .processing:
            OrbProcessingView()
                .frame(width: HUDStyle.orbSize, height: HUDStyle.orbSize)
                .transition(.opacity)
        case .refining(let raw, let streamed):
            RefiningCardView(raw: raw, streamed: streamed)
                .transition(.opacity)
        case .ready(let raw, let text, let usedFallback):
            ReadyCardView(raw: raw, text: text, usedFallback: usedFallback)
                .transition(.opacity)
        case .injected(let raw, let text):
            InjectedCardView(raw: raw, text: text)
                .transition(.opacity)
        case .error(let message):
            ErrorBadgeView(message: message)
                .transition(.opacity)
        case .hidden:
            EmptyView()
        }
    }

    /// 오브: 그라데이션 채움 + 목소리 반응 글로우 / 카드·배지: 머티리얼 + 그라데이션 테두리.
    @ViewBuilder
    private var backgroundShape: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if sizeClass == .orb {
            shape.fill(HUDStyle.gradient)
                .shadow(
                    color: HUDStyle.glowColor.opacity(0.45 + Double(viewModel.level) * 0.4),
                    radius: 14 + CGFloat(viewModel.level) * 14
                )
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(.black.opacity(0.35)))
                .overlay(shape.strokeBorder(HUDStyle.gradient.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
    }
}

// MARK: - 오브 (녹음: 웨이브폼 / 처리: 회전 링)

/// 목소리에 춤추는 웨이브폼 + 숨쉬는 스케일.
private struct OrbWaveformView: View {
    let level: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: barHeight(index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .scaleEffect(1 + CGFloat(level) * 0.08)  // 숨쉬는 오브
    }

    /// 가운데가 큰 산 모양 + 레벨 반응.
    private func barHeight(_ index: Int) -> CGFloat {
        let centerness = 1 - abs(CGFloat(index) - 2) / 2   // 0.0(가장자리)~1.0(중앙)
        let base: CGFloat = 8 + centerness * 6
        return base + CGFloat(level) * (10 + centerness * 14)
    }
}

/// 처리 중: 회전하는 흰색 아크 (생각 중).
private struct OrbProcessingView: View {
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.88)
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 26, height: 26)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
    }
}

// MARK: - 카드 (텍스트 단계)

/// 세션 텍스트 공통 스타일 (4줄 제한 — TDD §3.8).
private struct SessionText: View {
    let text: String
    var dimmed = false

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(dimmed ? 0.35 : 0.95))
            .lineLimit(4)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 행 라벨 ("원문"/"교정") — 어떤 텍스트가 무엇인지 명시 (주입 전 비교).
private struct RowLabel: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(accent ? AnyShapeStyle(HUDStyle.gradient) : AnyShapeStyle(.white.opacity(0.4)))
            .frame(width: 26, alignment: .leading)
            .padding(.top, 2)
    }
}

/// 교정 중 카드: "원문" dim + "교정" 스트리밍 텍스트(블록 커서).
private struct RefiningCardView: View {
    let raw: String
    let streamed: String
    @State private var cursorVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                RowLabel(text: "원문")
                SessionText(text: raw, dimmed: true)
            }
            HStack(alignment: .top, spacing: 8) {
                RowLabel(text: "교정", accent: true)
                SessionText(text: streamed + (cursorVisible ? "▌" : " "))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .task {
            // 문자열 내용 변경은 애니메이터블이 아니라 withAnimation.repeatForever가 무효 —
            // Task 루프로 토글 (뷰 소멸 시 자동 취소).
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(550))
                cursorVisible.toggle()
            }
        }
    }
}

/// 완성 카드: 원문 dim + 교정 결과 병기 (원칙 4 — 주입 전 비교, 2026-07-12 사용자 요청)
/// + 키캡 힌트 칩 (표시 전용 — 입력은 이벤트 탭, TDD §3.8).
private struct ReadyCardView: View {
    let raw: String
    let text: String
    let usedFallback: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                RowLabel(text: "원문")
                SessionText(text: raw, dimmed: true)
            }
            HStack(alignment: .top, spacing: 8) {
                RowLabel(text: "교정", accent: true)
                SessionText(text: text)
            }
            HStack(spacing: 6) {
                if usedFallback {
                    Text("원문 사용")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.orange.opacity(0.9)))
                        .foregroundStyle(.black)
                }
                KeycapChip(symbol: "timer", label: "잠시 후 자동")
                KeycapChip(symbol: "arrow.right.to.line", label: "Tab 원문")
                KeycapChip(symbol: "escape", label: "Esc 취소")
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// 키캡 스타일 힌트 칩 (시각 표시 전용 — 클릭 인터랙션은 PRD §10-8 미결).
private struct KeycapChip: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        )
    }
}

/// 주입 후 결과 유지 카드: 원문·교정 병기 + ✓ 주입 완료 (5s 유지 — 도그푸딩 2026-07-12).
/// Tab으로 원문을 주입한 경우(raw == text)엔 "원문" 단일 행 — 교정본 주입으로 오인 방지.
private struct InjectedCardView: View {
    let raw: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if raw == text {
                HStack(alignment: .top, spacing: 8) {
                    RowLabel(text: "원문", accent: true)
                    SessionText(text: text)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    RowLabel(text: "원문")
                    SessionText(text: raw, dimmed: true)
                }
                HStack(alignment: .top, spacing: 8) {
                    RowLabel(text: "교정", accent: true)
                    SessionText(text: text)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("주입 완료")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// 짧은 에러 배지 (자동 소멸은 HUDController.flashError가 관리).
private struct ErrorBadgeView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
