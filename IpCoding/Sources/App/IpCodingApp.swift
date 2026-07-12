import AppKit
import os

/// 앱 엔트리. NSStatusItem(메뉴바)과 생명주기를 소유한다 (TDD §1).
/// LSUIElement=YES — Dock·앱 전환기에 나타나지 않는 메뉴바 상주 앱.
@main
@MainActor
final class IpCodingApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = IpCodingApp()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem?
    private let hotkeyManager = HotkeyManager()
    private let audioCapture = AudioCapture()
    private let modelManager = ModelManager()
    private let transcribeEngine = TranscribeEngine()
    private let refineEngine = RefineEngine()
    private lazy var userDictionary = UserDictionary(directory: modelManager.modelsDirectory.deletingLastPathComponent())
    private lazy var promptBuilder = PromptBuilder(dictionary: userDictionary)
    private let injector: any Injecting = PasteboardInjector()
    private let hud = HUDController()
    private lazy var coordinator = SessionCoordinator(
        audioCapture: audioCapture,
        transcribeEngine: transcribeEngine,
        refineEngine: refineEngine,
        userDictionary: userDictionary,
        promptBuilder: promptBuilder,
        injector: injector,
        hud: hud
    )
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: "입코딩"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "입코딩 v0.1 (Phase 1)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "종료",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        item.menu = menu

        statusItem = item

        // 메뉴바 아이콘 상태 연동 (TDD §3.8) — 코디네이터 전이가 구동.
        coordinator.menuBarUpdater = { [weak self] state in
            self?.updateStatusIcon(for: state)
        }

        prepareModels()
        startInput()
    }

    /// 상태별 메뉴바 아이콘: idle 마이크(템플릿) / 녹음 빨간 마이크+펄스 / 처리 웨이브폼.
    /// 임시 SF Symbol — 최종 아이콘 자산은 태스크 3.5.
    private func updateStatusIcon(for state: SessionState) {
        guard let button = statusItem?.button else { return }
        button.layer?.removeAnimation(forKey: "ipcoding.pulse")

        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "입코딩")
            button.image?.isTemplate = true
        case .recording:
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "녹음 중")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
            // 녹음 중 펄스 (숨쉬는 투명도).
            button.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            button.layer?.add(pulse, forKey: "ipcoding.pulse")
        case .transcribing, .refining, .awaitingInjection, .injecting:
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "처리 중")
            button.image?.isTemplate = true
        }
    }

    /// 태스크 1.4·1.5: 모델 디렉토리 보장 + 사전 로드 + whisper 로드·워밍업.
    private func prepareModels() {
        do {
            try modelManager.ensureModelsDirectory()
        } catch {
            logger.error("모델 디렉토리 생성 실패: \(String(describing: error), privacy: .public)")
        }
        userDictionary.load()
        let turbo = ModelManager.whisperTurbo
        guard modelManager.isInstalled(turbo) else {
            logger.warning("STT 모델 \(turbo.filename, privacy: .public) 없음 — 수동 배치 필요")
            return
        }
        Task {
            do {
                let path = try modelManager.resolvedPath(for: turbo)
                try await transcribeEngine.load(modelPath: path.path)
                await transcribeEngine.warmUp()
                logger.info("STT 엔진 준비 완료")
            } catch {
                logger.error("STT 엔진 준비 실패: \(String(describing: error), privacy: .public)")
            }
        }

        prepareRefineEngine()
    }

    /// 태스크 2.2·2.3: 교정 LLM 로드 + PromptBuilder 조립 프롬프트로 프리픽스 캐시 준비.
    /// 파이프라인 배선은 2.4.
    private func prepareRefineEngine() {
        let qwen = ModelManager.qwenRefine
        guard modelManager.isInstalled(qwen) else {
            logger.warning("LLM 모델 \(qwen.filename, privacy: .public) 없음")
            return
        }
        Task {
            do {
                let parts = try promptBuilder.refinePromptParts()  // 번들 v2 + ChatML (TDD §3.5)
                let modelPath = try modelManager.resolvedPath(for: qwen)
                try await refineEngine.load(modelPath: modelPath.path)
                try await refineEngine.preparePrompt(parts: parts)
                await refineEngine.warmUp()  // Metal 커널·생성 경로 예열 (첫 교정 지연 제거)
                logger.info("교정 엔진 준비 완료")
            } catch {
                logger.error("교정 엔진 준비 실패: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 이벤트 탭 + 마이크 권한. 핫키·오디오 이벤트는 코디네이터로 직접 전달된다(TDD §2).
    private func startInput() {
        hotkeyManager.delegate = self
        audioCapture.delegate = self
        if !hotkeyManager.start() {
            _ = HotkeyManager.promptForAccessibilityIfNeeded()
            logger.warning("손쉬운 사용 권한 미부여 — 시스템 설정에서 부여 후 앱 재시작 필요")
        }

        // 마이크 권한을 시작 시 선행 요청 (첫 발화 때 무음 방지). 온보딩은 태스크 3.1.
        Task { @MainActor in
            let granted = await AudioCapture.requestMicrophoneAccessIfNeeded()
            if !granted {
                self.logger.warning("마이크 권한 미부여(\(String(describing: AudioCapture.microphoneAuthorization.rawValue), privacy: .public)) — 시스템 설정 > 마이크에서 부여 필요")
            }
        }
    }
}

// MARK: - 입력 이벤트 → 코디네이터 (얇은 전달만 — 판단·전이는 코디네이터)

extension IpCodingApp: HotkeyManagerDelegate {
    func hotkeyDown() {
        coordinator.hotkeyDown()
    }

    func hotkeyUp(heldFor duration: TimeInterval) {
        coordinator.hotkeyUp()
    }

    func hotkeyCancelled() {
        coordinator.hotkeyCancelled()
    }
}

extension IpCodingApp: AudioCaptureDelegate {
    func audioCaptureDidReachMaxDuration() {
        coordinator.audioReachedMaxDuration()
    }
}
