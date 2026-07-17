import AppKit
import ApplicationServices
import SwiftUI
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
    private let injector = InjectorRouter()  // 방식 전환은 설정 (태스크 3.4)
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

        // 설정 기본값 등록 (태스크 2.7·3.3) — 메뉴 체크마크가 읽으므로 메뉴 생성보다 먼저.
        UserDefaults.standard.register(defaults: [
            Self.injectDelayKey: 500,
            SettingsView.hotkeyComboKey: HotkeyCombo.commandFn.rawValue,
            SettingsView.firstTokenTimeoutKey: 3000,
            SettingsView.totalTimeoutKey: 8000,
            SettingsView.injectionMethodKey: InjectionMethod.pasteboard.rawValue,
        ])
        // 목록 외 저장값(수동 편집 등)은 기본값으로 정규화 — 체크마크 실종·이상 지연 방어.
        if !Self.injectDelayOptions.contains(UserDefaults.standard.integer(forKey: Self.injectDelayKey)) {
            UserDefaults.standard.set(500, forKey: Self.injectDelayKey)
        }
        // 타임아웃도 동일 정규화 (3.3 리뷰 N2 — 0ms 등 이상값이 즉시 원문 폴백을 유발 방지).
        if ![2000, 3000, 5000].contains(UserDefaults.standard.integer(forKey: SettingsView.firstTokenTimeoutKey)) {
            UserDefaults.standard.set(3000, forKey: SettingsView.firstTokenTimeoutKey)
        }
        if ![5000, 8000, 12000].contains(UserDefaults.standard.integer(forKey: SettingsView.totalTimeoutKey)) {
            UserDefaults.standard.set(8000, forKey: SettingsView.totalTimeoutKey)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: "입코딩"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "입코딩 v0.1 (Phase 2)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let dictItem = NSMenuItem(title: "사전 편집…", action: #selector(openDictionaryEditor), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)
        // 온보딩 재진입점 (3.1 리뷰 N1) — 나중에 권한을 주려는 사용자의 유일한 경로가
        // 앱 재시작이 되지 않도록. 권한이 이미 다 있으면 완료 화면으로 직행한다.
        let permItem = NSMenuItem(title: "권한 설정…", action: #selector(openOnboardingFromMenu), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)
        let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(makeInjectDelayMenuItem())
        menu.addItem(makeStatsMenuItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "종료",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        item.menu = menu

        statusItem = item

        coordinator.autoInjectDelay = .milliseconds(UserDefaults.standard.integer(forKey: Self.injectDelayKey))
        applyStoredSettings()

        // 메뉴바 아이콘 상태 연동 (TDD §3.8) — 코디네이터 전이가 구동.
        coordinator.menuBarUpdater = { [weak self] state in
            self?.updateStatusIcon(for: state)
        }

        prepareModels()
        startInput()
    }

    /// Launchpad/Finder에서 앱을 다시 실행하면 설정 창을 연다 (3.3 도그푸딩 피드백 —
    /// 메뉴바가 꽉 차 아이콘이 가려지면 설정·사전 접근 경로가 사라지는 문제의 우회로).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - 자동 주입 대기 N 메뉴 (태스크 2.7, PRD §10-3)

    private static let injectDelayKey = "autoInjectDelayMs"
    private static let injectDelayOptions: Set<Int> = [0, 500, 1000, 1500, 2000]

    private var injectDelaySubmenu: NSMenu?

    private func makeInjectDelayMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "자동 주입 대기", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self  // 설정 창에서 바꿔도 체크마크가 최신이도록 열 때마다 갱신 (3.3)
        injectDelaySubmenu = submenu
        let current = UserDefaults.standard.integer(forKey: Self.injectDelayKey)
        let options: [(String, Int)] = [
            ("즉시 (Tab/Esc 창 없음)", 0),
            ("0.5초", 500), ("1.0초", 1000), ("1.5초", 1500), ("2.0초", 2000),
        ]
        for (label, ms) in options {
            let item = NSMenuItem(title: label, action: #selector(selectInjectDelay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ms
            item.state = (ms == current) ? .on : .off
            submenu.addItem(item)
        }
        root.submenu = submenu
        return root
    }

    @objc private func selectInjectDelay(_ sender: NSMenuItem) {
        guard let ms = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(ms, forKey: Self.injectDelayKey)
        coordinator.autoInjectDelay = .milliseconds(ms)
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
        logger.info("자동 주입 대기 변경 — \(ms, privacy: .public)ms")
    }

    // MARK: - 설정 창 (태스크 3.3)

    private var settingsWindow: NSWindow?

    /// UserDefaults의 설정값을 런타임 객체에 반영 (시작 시 + 설정 변경 시 공용).
    private func applyStoredSettings() {
        let defaults = UserDefaults.standard
        if let combo = HotkeyCombo(rawValue: defaults.string(forKey: SettingsView.hotkeyComboKey) ?? "") {
            hotkeyManager.combo = combo
        }
        coordinator.llmFirstTokenTimeout = .milliseconds(defaults.integer(forKey: SettingsView.firstTokenTimeoutKey))
        coordinator.llmTotalTimeout = .milliseconds(defaults.integer(forKey: SettingsView.totalTimeoutKey))
        let deviceUID = defaults.string(forKey: SettingsView.inputDeviceUIDKey) ?? ""
        audioCapture.fixedDeviceUID = deviceUID.isEmpty ? nil : deviceUID
        if let method = InjectionMethod(rawValue: defaults.string(forKey: SettingsView.injectionMethodKey) ?? "") {
            injector.method = method
        }
    }

    /// 설정 창 — 온보딩과 같은 비재사용 구조 (닫히면 해제). 재다운로드 Task는 unstructured라
    /// 창과 독립적으로 백그라운드에서 계속되며, 중복 시작은 ModelManager의 전역 배타
    /// (activeDownloadId)가 차단한다 (3.3 리뷰 W1 — 정책: 창 닫힘은 취소가 아니다).
    /// 주입 자기창 가드(2.8)가 이 창의 주입 오염도 막는다.
    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            modelManager: modelManager,
            onHotkeyChange: { [weak self] combo in
                self?.hotkeyManager.combo = combo
                self?.logger.info("핫키 변경 — \(combo.rawValue, privacy: .public)")
            },
            onInjectDelayChange: { [weak self] ms in
                self?.coordinator.autoInjectDelay = .milliseconds(ms)
            },
            onTimeoutChange: { [weak self] firstMs, totalMs in
                self?.coordinator.llmFirstTokenTimeout = .milliseconds(firstMs)
                self?.coordinator.llmTotalTimeout = .milliseconds(totalMs)
            },
            onInputDeviceChange: { [weak self] uid in
                self?.audioCapture.fixedDeviceUID = uid
                self?.logger.info("입력 장치 변경 — \(uid == nil ? "시스템 기본" : "고정 장치", privacy: .public)")
            },
            onInjectionMethodChange: { [weak self] method in
                self?.injector.method = method
                self?.logger.info("주입 방식 변경 — \(method.rawValue, privacy: .public)")
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "입코딩 설정"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false  // 해제는 windowWillClose에서 참조 해제로
        window.delegate = self
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 사전 편집 창 (태스크 2.8, TDD §3.6)

    private var dictionaryWindow: NSWindow?
    /// 저장 실패 알림은 창 세션당 1회 — 편집이 키 입력 단위로 저장되므로 디스크 오류 시
    /// runModal이 키 입력마다 반복되는 것을 막는다 (실패 자체는 매번 로그).
    private var dictionarySaveErrorShown = false

    @objc private func openDictionaryEditor() {
        dictionarySaveErrorShown = false
        if let window = dictionaryWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 표시 순서는 파일 순서 (entries는 매칭용 길이 정렬본 — 그대로 쓰면 첫 저장이
        // 사용자가 파일에서 잡아둔 순서를 정렬 순서로 덮는다, 리뷰 N1).
        let editor = DictionaryEditorView(entries: userDictionary.fileOrderedEntries) { [weak self] entries in
            guard let self else { return }
            do {
                try self.userDictionary.update(entries)
                self.dictionarySaveErrorShown = false  // 오류 해소 후 재발 시 다시 알림 (리뷰 N3)
            } catch {
                self.logger.error("사전 저장 실패: \(String(describing: error), privacy: .public)")
                guard !self.dictionarySaveErrorShown else { return }
                self.dictionarySaveErrorShown = true
                // 뷰 갱신 트랜잭션(onDisappear 경유 flushSave) 안에서 runModal 중첩 방지 —
                // 다음 런루프 턴으로 미룬다 (리뷰 W3).
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "사전 저장 실패"
                    alert.informativeText = "dictionary.json에 쓸 수 없습니다. 디스크 상태 확인 후 다시 편집해주세요."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "사전 편집"
        window.contentView = NSHostingView(rootView: editor)
        window.isReleasedWhenClosed = false  // 닫아도 인스턴스 재사용 (편집 상태 유지)
        window.center()
        dictionaryWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 타이밍 통계 디버그 메뉴 (태스크 2.9, TDD §6)

    private var statsSubmenu: NSMenu?

    private func makeStatsMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "타이밍 통계", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self  // 열 때마다 최신 통계로 재구성
        submenu.autoenablesItems = false  // 표시 전용 항목의 비활성을 명시적으로 (리뷰 N5)
        root.submenu = submenu
        statsSubmenu = submenu
        return root
    }

    /// 통계 서브메뉴를 현재 값으로 재구성 (표시 전용 — 항목 비활성).
    private func rebuildStatsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = coordinator.metrics

        func row(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        guard !store.recent.isEmpty else {
            row("아직 완료된 세션이 없습니다")
            return
        }

        func statLine(_ label: String, _ keyPath: KeyPath<SessionMetrics, Duration?>) {
            let p50 = store.percentile(0.5, of: keyPath)?.displaySeconds ?? "–"
            let p90 = store.percentile(0.9, of: keyPath)?.displaySeconds ?? "–"
            row("\(label)  p50 \(p50) · p90 \(p90)")
        }

        row("최근 \(store.recent.count)세션 (메모리)")
        menu.addItem(.separator())
        statLine("전사 T_raw", \.tRaw)
        statLine("첫 토큰", \.tFirstToken)
        statLine("교정 완성 T_ready", \.tReady)
        statLine("주입 T_inject", \.tInject)
        menu.addItem(.separator())
        let fallbacks = store.recent.filter(\.usedFallback).count
        row("원문 폴백 \(fallbacks)/\(store.recent.count)")
        if let rate = store.escCancelRate {
            row(String(format: "Esc 취소율 %.0f%% (%d/%d)", rate * 100,
                       store.escCancelCount, store.completedCount + store.escCancelCount))
        }
        row("Tab 원문 사용 \(store.tabRawCount)회")
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

    /// 엔진 로드 중복 방지 — 시작 시(설치돼 있으면)와 온보딩 다운로드 완료 시 양쪽에서
    /// prepareModels가 불릴 수 있다 (태스크 3.2).
    private var sttLoadStarted = false
    private var llmLoadStarted = false

    /// 태스크 1.4·1.5: 모델 디렉토리 보장 + 사전 로드 + whisper 로드·워밍업. 멱등.
    private func prepareModels() {
        do {
            try modelManager.ensureModelsDirectory()
        } catch {
            logger.error("모델 디렉토리 생성 실패: \(String(describing: error), privacy: .public)")
        }
        userDictionary.load()
        let turbo = ModelManager.whisperTurbo
        guard modelManager.isInstalled(turbo) else {
            logger.warning("STT 모델 \(turbo.filename, privacy: .public) 없음 — 온보딩에서 다운로드")
            prepareRefineEngine()
            return
        }
        if !sttLoadStarted {
            sttLoadStarted = true
            Task {
                do {
                    let path = try modelManager.resolvedPath(for: turbo)
                    try await transcribeEngine.load(modelPath: path.path)
                    await transcribeEngine.warmUp()
                    logger.info("STT 엔진 준비 완료")
                } catch {
                    self.sttLoadStarted = false  // 같은 실행에서 재시도 가능하게 (리뷰 N3)
                    logger.error("STT 엔진 준비 실패: \(String(describing: error), privacy: .public)")
                }
            }
        }

        prepareRefineEngine()
    }

    /// 태스크 2.2·2.3: 교정 LLM 로드 + PromptBuilder 조립 프롬프트로 프리픽스 캐시 준비.
    /// 파이프라인 배선은 2.4. 멱등 (llmLoadStarted).
    private func prepareRefineEngine() {
        let qwen = ModelManager.qwenRefine
        guard modelManager.isInstalled(qwen) else {
            logger.warning("LLM 모델 \(qwen.filename, privacy: .public) 없음 — 온보딩에서 다운로드")
            return
        }
        guard !llmLoadStarted else { return }
        llmLoadStarted = true
        Task {
            do {
                let parts = try promptBuilder.refinePromptParts()  // 번들 v2 + ChatML (TDD §3.5)
                let modelPath = try modelManager.resolvedPath(for: qwen)
                try await refineEngine.load(modelPath: modelPath.path)
                try await refineEngine.preparePrompt(parts: parts)
                await refineEngine.warmUp()  // Metal 커널·생성 경로 예열 (첫 교정 지연 제거)
                logger.info("교정 엔진 준비 완료")
            } catch {
                self.llmLoadStarted = false  // 같은 실행에서 재시도 가능하게 (리뷰 N3)
                logger.error("교정 엔진 준비 실패: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 이벤트 탭 시작 + 권한 재검사. 핫키·오디오 이벤트는 코디네이터로 직접 전달된다(TDD §2).
    /// 권한이 미충족이면 온보딩 창으로 유도 — 요청 다이얼로그는 온보딩 단계 버튼에서 띄운다
    /// (TDD §4 요청 시점 = 온보딩 1·2단계. 시작 시 무맥락 다이얼로그 남발 금지).
    private func startInput() {
        hotkeyManager.delegate = self
        audioCapture.delegate = self
        // Tab/Esc 인터셉트 모드: 코디네이터 지시 → HotkeyManager (태스크 2.6, 단방향).
        coordinator.keyInterceptUpdater = { [weak self] mode in
            self?.hotkeyManager.interceptMode = mode
        }
        if !hotkeyManager.start() {
            logger.warning("이벤트 탭 시작 실패 — 손쉬운 사용 미부여, 온보딩으로 유도")
        }
        // 권한·모델 상태는 앱 시작 시마다 재검사한다 (TDD §4, §3.9).
        if AudioCapture.microphoneAuthorization != .authorized || !AXIsProcessTrusted()
            || !modelManager.allModelsInstalled {
            openOnboarding()
        }
    }

    // MARK: - 온보딩 창 (태스크 3.1, TDD §4)

    private var onboardingWindow: NSWindow?

    @objc private func openOnboardingFromMenu() {
        openOnboarding()
    }

    /// 온보딩 창은 사전 편집 창과 달리 **재사용하지 않는다** — 닫히면 참조를 놓아 해제하고
    /// (windowWillClose), 다음 열기에서 현재 권한 상태로 새로 만든다. 해제가 NSHostingView와
    /// 뷰의 .task 폴링을 확정적으로 끝내므로 폴링 잔존·스테일 상태 문제가 없다 (3.1 리뷰 W2).
    private func openOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            modelManager: modelManager,
            onAccessibilityGranted: { [weak self] in
                guard let self else { return }
                // 부여 전에 만든(또는 실패한) 탭은 부여만으로 살아나지 않는다 — 재생성 필수.
                self.hotkeyManager.stop()
                if self.hotkeyManager.start() {
                    self.logger.info("손쉬운 사용 부여 감지 — 이벤트 탭 재생성 완료")
                } else {
                    self.logger.warning("부여 감지 후에도 탭 재생성 실패 — 앱 재시작 필요할 수 있음")
                }
            },
            onModelsReady: { [weak self] in
                // 다운로드·검증 직후 엔진 로드 (멱등 — 이미 로드됐으면 스킵).
                self?.prepareModels()
            },
            onFinished: { [weak self] in
                self?.onboardingWindow?.close()
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "입코딩 시작하기"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false  // 해제는 windowWillClose에서 참조 해제로 관리
        window.delegate = self
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    func escKeyPressed() {
        coordinator.escPressed()
    }

    func tabKeyPressed() {
        coordinator.tabPressed()
    }
}

extension IpCodingApp: AudioCaptureDelegate {
    func audioCaptureDidReachMaxDuration() {
        coordinator.audioReachedMaxDuration()
    }
}

// MARK: - NSWindowDelegate (온보딩 창 해제 — 3.1 리뷰 W2)

extension IpCodingApp: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // 참조 해제 → NSHostingView·뷰의 .task(폴링/다운로드)가 확정적으로 종료.
        if window === onboardingWindow { onboardingWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
    }
}

// MARK: - NSMenuDelegate (타이밍 통계 서브메뉴 갱신)

extension IpCodingApp: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statsSubmenu {
            rebuildStatsMenu(menu)
        } else if menu === injectDelaySubmenu {
            // 설정 창과 UserDefaults를 공유하므로 열 때 현재 값으로 체크마크 재계산 (3.3).
            let current = UserDefaults.standard.integer(forKey: Self.injectDelayKey)
            for item in menu.items {
                item.state = ((item.representedObject as? Int) == current) ? .on : .off
            }
        }
        // 그 외 메뉴는 건드리지 않는다 (2.9 리뷰 N4).
    }
}
