import SwiftUI
import AVFoundation
import ApplicationServices

/// 온보딩 플로우 (태스크 3.1, TDD §4). 권한 2종(마이크·손쉬운 사용)을 한 화면씩:
/// "왜 필요한지 한 문장 + 허용 버튼/시스템 설정 딥링크 + 허용 감지 시 자동 다음 단계".
///
/// 요청 다이얼로그는 TCC 엔트리가 없을 때만 뜬다(거부 이력이 있으면 안 뜸) — 그래서
/// 각 단계는 요청 버튼과 딥링크를 함께 제공하고, 부여 감지는 0.7s 폴링으로 한다
/// (AXIsProcessTrusted/authorizationStatus 모두 매 호출 신선값 — 2026-07 조사).
/// 손쉬운 사용 부여를 감지하면 onAccessibilityGranted로 알린다 — 앱이 이벤트 탭을
/// 재생성해야 반영된다(기존 탭은 살아나지 않음).
struct OnboardingView: View {

    private enum Step {
        case welcome, microphone, accessibility, models, done
    }

    @State private var step: Step = .welcome
    @State private var micStatus = AudioCapture.microphoneAuthorization
    @State private var axTrusted = AXIsProcessTrusted()
    // 모델 다운로드 상태 (태스크 3.2 — 온보딩 통합, PRD "모델 다운로드 진행 표시")
    @State private var modelProgress: [String: DownloadProgress] = [:]
    @State private var downloadError: String?
    @State private var downloading = false
    @State private var retryToken = 0

    let modelManager: ModelManager
    /// 손쉬운 사용이 새로 부여된 순간 호출 — 이벤트 탭 재생성용.
    let onAccessibilityGranted: () -> Void
    /// 모델 다운로드·검증 완료 — 엔진 로드용.
    let onModelsReady: () -> Void
    /// 완료 화면에서 "시작하기" — 창 닫기용.
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)
            content
            Spacer(minLength: 8)
            stepDots
        }
        .padding(28)
        .frame(width: 460, height: 400)
        .task { await pollPermissions() }
    }

    // MARK: - 단계별 화면

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            page(
                symbol: "mic.badge.plus", tint: .indigo,
                title: "입코딩 시작하기",
                message: "말로 코딩 지시를 내리는 로컬 음성 입력입니다.\n음성과 텍스트는 기기 밖으로 나가지 않아요."
            ) {
                Button("시작하기") { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } caption: {
                Text("권한 2가지 허용과 AI 모델 준비만 하면 바로 쓸 수 있어요")
            }

        case .microphone:
            page(
                symbol: "mic.fill", tint: .red,
                title: "마이크 허용",
                message: "말한 내용을 텍스트로 바꾸려면 마이크가 필요해요.\n음성은 기기 안에서만 처리되고 저장되지 않아요."
            ) {
                if micStatus == .notDetermined {
                    Button("마이크 허용") {
                        Task { _ = await AudioCapture.requestMicrophoneAccessIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("시스템 설정 열기") { openSettings(anchor: "Privacy_Microphone") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } caption: {
                Text(micStatus == .notDetermined
                     ? "허용하면 자동으로 다음 단계로 넘어가요"
                     : "설정 > 개인정보 보호 및 보안 > 마이크에서 입코딩을 켜주세요")
            }

        case .accessibility:
            page(
                symbol: "keyboard.badge.ellipsis", tint: .purple,
                title: "손쉬운 사용 허용",
                message: "⌘+Fn 핫키를 감지하고 완성된 텍스트를\n터미널에 붙여넣으려면(⌘V) 필요해요."
            ) {
                VStack(spacing: 10) {
                    Button("허용하기") {
                        // TCC 엔트리가 없으면 시스템 다이얼로그가 뜬다 (1회 한정 — macos-quirks).
                        _ = HotkeyManager.promptForAccessibilityIfNeeded()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("시스템 설정 직접 열기") { openSettings(anchor: "Privacy_Accessibility") }
                        .buttonStyle(.link)
                }
            } caption: {
                Text("목록에서 입코딩을 켜면 자동으로 넘어가요.\n켰는데 반응이 없으면 앱을 재시작해주세요.")
            }

        case .models:
            page(
                symbol: "arrow.down.circle", tint: .blue,
                title: "AI 모델 다운로드",
                message: "음성 인식·교정 모델을 받아요 (약 6GB).\n모델은 기기 안에서만 동작해요."
            ) {
                VStack(spacing: 12) {
                    ForEach(ModelManager.requiredModels, id: \.id) { spec in
                        modelRow(spec)
                    }
                    if let downloadError {
                        Text(downloadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("다시 시도") { retryToken += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(width: 300)
            } caption: {
                Text("Wi-Fi 연결을 권장해요. 중단돼도 이어받기가 돼요.")
            }
            .task(id: retryToken) { await runModelDownloads() }

        case .done:
            page(
                symbol: "checkmark.seal.fill", tint: .green,
                title: "준비 완료!",
                message: "⌘+Fn을 누른 채 말하고, 떼면\n교정된 텍스트가 터미널에 들어가요."
            ) {
                Button("시작하기") { onFinished() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } caption: {
                Text("Tab = 원문 사용 · Esc = 취소 · 메뉴바에서 사전 편집")
            }
        }
    }

    /// 공통 페이지 레이아웃: 심볼 + 제목 + 한 문장 + 액션 + 캡션 (TDD §4 패턴).
    private func page(
        symbol: String, tint: Color, title: String, message: String,
        @ViewBuilder action: () -> some View,
        @ViewBuilder caption: () -> Text
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(tint)
                .frame(height: 56)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            action()
                .padding(.top, 6)
            caption()
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
        .id(step)  // 단계 전환 시 transition이 실제로 발동하도록 아이덴티티 분리
    }

    /// 모델 한 줄: 이름 + 진행 바 + 바이트 표시.
    private func modelRow(_ spec: ModelSpec) -> some View {
        let progress = modelProgress[spec.id]
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(spec.displayName).font(.caption)
                Spacer()
                Text(progressLabel(spec, progress))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: progress?.fraction ?? (modelManager.isInstalled(spec) ? 1 : 0))
        }
    }

    private func progressLabel(_ spec: ModelSpec, _ progress: DownloadProgress?) -> String {
        if modelManager.isInstalled(spec) { return "완료" }
        guard let progress else { return spec.sizeBytes.formatted(.byteCount(style: .file)) }
        return progress.received.formatted(.byteCount(style: .file))
            + " / " + progress.total.formatted(.byteCount(style: .file))
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(index <= stepIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var stepIndex: Int {
        switch step {
        case .welcome: return 0
        case .microphone: return 1
        case .accessibility: return 2
        case .models: return 3
        case .done: return 4
        }
    }

    // MARK: - 권한 폴링·진행

    /// 0.7s 폴링 — 시스템 설정에서 허용하고 돌아온 것을 감지해 자동 진행 (TDD §4).
    private func pollPermissions() async {
        while !Task.isCancelled {
            micStatus = AudioCapture.microphoneAuthorization
            let ax = AXIsProcessTrusted()
            if ax && !axTrusted {
                onAccessibilityGranted()  // 새로 부여됨 — 이벤트 탭 재생성 필요
            }
            axTrusted = ax
            autoAdvance()
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    /// 현재 단계의 권한이 충족되면 다음 미충족 단계로 (welcome·done은 버튼으로만 이동).
    private func autoAdvance() {
        switch step {
        case .microphone where micStatus == .authorized,
             .accessibility where axTrusted:
            advance()
        default:
            break
        }
    }

    private func advance() {
        withAnimation(.spring(duration: 0.35)) {
            if micStatus != .authorized {
                step = .microphone
            } else if !axTrusted {
                step = .accessibility
            } else if !modelManager.allModelsInstalled {
                step = .models
            } else {
                step = .done
            }
        }
    }

    /// 필수 모델을 순서대로(작은 것 먼저) 다운로드. 완료 시 onModelsReady + 다음 단계.
    /// 취소(창 닫힘)는 조용히 중단 — partial이 남아 다음에 이어받는다.
    private func runModelDownloads() async {
        guard step == .models, !downloading else { return }
        downloading = true
        downloadError = nil
        defer { downloading = false }
        for spec in ModelManager.requiredModels where !modelManager.isInstalled(spec) {
            do {
                try await modelManager.download(spec) { progress in
                    modelProgress[spec.id] = progress
                }
            } catch {
                if !Task.isCancelled {
                    switch error {
                    case ModelManagerError.checksumMismatch:
                        downloadError = "파일 검증에 실패했어요 — 다시 시도해주세요"
                    case ModelManagerError.diskWriteFailed:
                        downloadError = "저장에 실패했어요 — 디스크 공간을 확인해주세요"
                    case ModelManagerError.anotherDownloadActive:
                        downloadError = "다른 다운로드가 진행 중이에요 — 완료 후 다시 시도해주세요"
                    default:
                        downloadError = "다운로드에 실패했어요 — 네트워크 확인 후 다시 시도해주세요"
                    }
                }
                return
            }
        }
        onModelsReady()
        advance()
    }

    private func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
