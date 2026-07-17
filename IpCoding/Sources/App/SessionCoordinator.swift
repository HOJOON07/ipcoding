import AppKit
import Foundation
import os

/// 세션 상태 (TDD §2 전이표 전수 — 태스크 2.4).
enum SessionState: Equatable {
    case idle
    case recording
    case transcribing
    case refining
    case awaitingInjection
    case injecting
}

/// refining 진행 상태 공유함 — RefineEngine의 @Sendable 콜백(onToken/isCancelled)과 코디네이터가
/// 공유한다. 타임아웃(TDD §3.4: 첫 토큰 3s/전체 8s)과 Esc 취소를 isCancelled 하나로 전달하고,
/// 취소 원인은 코디네이터가 escRequested로 구분한다(2.2 리뷰 W3 계약).
private final class RefineProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var firstTokenSeen = false
    private var esc = false

    private let firstTokenTimeout: Duration = .seconds(3)
    private let totalTimeout: Duration = .seconds(8)

    init() { startedAt = clock.now }

    private var accumulated = ""

    /// 토큰을 누적하고 전체 스냅샷을 반환 (첫 토큰 마킹 겸용). HUD에는 스냅샷을 통째로 전달해
    /// 개별 Task 홉의 실행 순서 비보장(토큰 A,B가 B,A로 도착) 문제를 원천 제거한다 (2.5 리뷰 W2).
    func appendToken(_ token: String) -> String {
        lock.lock(); defer { lock.unlock() }
        firstTokenSeen = true
        accumulated += token
        return accumulated
    }

    func requestEsc() {
        lock.lock(); defer { lock.unlock() }
        esc = true
    }

    var escRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return esc
    }

    /// RefineEngine이 매 생성 스텝마다 호출. Esc 또는 데드라인 초과면 true.
    func shouldCancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if esc { return true }
        let elapsed = clock.now - startedAt
        return firstTokenSeen ? elapsed > totalTimeout : elapsed > firstTokenTimeout
    }
}

/// 앱의 심장 (TDD §2). 한 번의 발화 = 한 세션. 모든 모듈은 이벤트를 코디네이터로 보내고,
/// 코디네이터만 상태를 전이시킨다. @MainActor — 상태·전이는 단일 스레드에서 직렬 처리되어
/// 겹친 세션의 레이스가 원천 차단된다.
@MainActor
final class SessionCoordinator {

    private(set) var state: SessionState = .idle

    /// 메뉴바 아이콘 갱신 훅 (TDD §3.8: 코디네이터가 구동, 아이콘 쪽엔 상태 머신 없음).
    var menuBarUpdater: ((SessionState) -> Void)?
    /// Tab/Esc 인터셉트 모드 지시 훅 (TDD §3.1, 태스크 2.6) — 코디네이터가 세션 상태에 맞춰
    /// 지시한다. refining=Esc만, awaitingInjection=Esc·Tab, 그 외(injected 유지 카드 포함)=none.
    var keyInterceptUpdater: ((KeyInterceptMode) -> Void)?

    /// 세대 토큰 — hotkeyDown이 미룬 엔진 start를, 그 사이 도착한 up/cancel이 무효화하는 데 쓴다.
    private var startGeneration = 0

    // 세션 데이터 (TDD §2 Session). idle 복귀 시 폐기.
    private var rawText: String?
    private var refinedText: String?

    /// refining 중 콜백과 공유하는 진행 상태 (Esc·타임아웃).
    private var refineProgress: RefineProgress?
    /// awaitingInjection의 자동 주입 타이머 태스크.
    private var injectionTimer: Task<Void, Never>?

    /// 자동 주입 대기시간 N (PRD §10-3 확정: 기본 0.5s — 2026-07-12 도그푸딩). 앱이
    /// UserDefaults/메뉴에서 설정한다 (태스크 2.7). 0 = 즉시 주입 (Tab/Esc 창 사실상 없음).
    var autoInjectDelay: Duration = .milliseconds(500)

    // 타이밍 계측 (TDD §6, 태스크 2.9). T0 = hotkeyUp, 메모리에만 보관.
    let metrics = MetricsStore()
    private let metricsClock = ContinuousClock()
    private var sessionT0: ContinuousClock.Instant?
    private var currentMetrics = SessionMetrics()

    private let audioCapture: AudioCapture
    private let transcribeEngine: TranscribeEngine
    private let refineEngine: RefineEngine
    private let userDictionary: UserDictionary
    private let promptBuilder: PromptBuilder
    private let injector: any Injecting
    private let hud: HUDController
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "coordinator")

    init(
        audioCapture: AudioCapture,
        transcribeEngine: TranscribeEngine,
        refineEngine: RefineEngine,
        userDictionary: UserDictionary,
        promptBuilder: PromptBuilder,
        injector: any Injecting,
        hud: HUDController
    ) {
        self.audioCapture = audioCapture
        self.transcribeEngine = transcribeEngine
        self.refineEngine = refineEngine
        self.userDictionary = userDictionary
        self.promptBuilder = promptBuilder
        self.injector = injector
        self.hud = hud
        // HUD 레벨 미터가 마이크 입력에 반응하도록 연결.
        hud.viewModel.levelProvider = { [weak audioCapture] in audioCapture?.currentLevel ?? 0 }
    }

    // MARK: - 입력 이벤트 (HotkeyManager·AudioCapture → 코디네이터)

    /// idle에서만 유효 (TDD §2: 세션 중 재입력 무시).
    /// state는 즉시 확정하고(직렬 처리라 상태 레이스 없음), 무거운 엔진 start만 Task로 미룬다
    /// — 이벤트 탭 콜백을 블로킹하지 않기 위함(HotkeyManagerDelegate 계약).
    func hotkeyDown() {
        guard state == .idle else {
            logger.debug("hotkeyDown 무시 — 현재 \(String(describing: self.state), privacy: .public)")
            return
        }
        startGeneration += 1
        let generation = startGeneration
        transition(to: .recording)
        Task { @MainActor in
            guard generation == self.startGeneration, self.state == .recording else { return }
            do {
                try self.audioCapture.start()
            } catch AudioCaptureError.microphoneNotAuthorized {
                // TDD §4 "녹음 불가 — 기능 정지 + 안내": 온보딩을 건너뛴 사용자가 침묵 실패를
                // 겪지 않도록 안내한다 (3.1 리뷰 W1). 온보딩 재진입은 메뉴바 "권한 설정…".
                self.logger.error("캡처 시작 실패 — 마이크 권한 미부여")
                self.transition(to: .idle)
                self.hud.flashError("마이크 권한이 필요해요 — 메뉴바 > 권한 설정", duration: .milliseconds(2500))
            } catch {
                self.logger.error("캡처 시작 실패: \(String(describing: error), privacy: .public)")
                self.transition(to: .idle)
            }
        }
    }

    /// recording → transcribing. 그 외 상태에서는 무시.
    func hotkeyUp() {
        guard state == .recording else { return }
        startGeneration += 1  // 아직 실행 안 된 pending start를 무효화.
        finishRecording()
    }

    /// recording → idle (디바운스 오조작 — 버퍼 폐기, 에러 표시 없음). TDD §2.
    func hotkeyCancelled() {
        guard state == .recording else { return }
        startGeneration += 1
        _ = audioCapture.stop()
        transition(to: .idle)
    }

    /// 60초 상한 — recording → transcribing 강제 마감 (TDD §2 maxDuration).
    func audioReachedMaxDuration() {
        guard state == .recording else { return }
        finishRecording()
    }

    /// Esc (TDD §2): refining이면 LLM 취소 → idle, awaitingInjection이면 주입 취소 → idle.
    /// 키 인터셉트 배선은 태스크 2.6 — 그 전까지 호출원 없음.
    func escPressed() {
        switch state {
        case .refining:
            // 즉시 idle 전이 — refine Task가 서스펜션 구간(isLoaded await 등)에 있어도 Esc가
            // 유실되지 않는다(잔여 Task는 상태 가드로 무력화). LLM 생성 자체는 requestEsc로 중단.
            refineProgress?.requestEsc()
            metrics.recordEscCancel()  // Esc 취소율 (Phase 2 완료 기준 — 측정 시작)
            transition(to: .idle)
        case .awaitingInjection:
            injectionTimer?.cancel()
            metrics.recordEscCancel()
            transition(to: .idle)
        default:
            break
        }
    }

    /// Tab (TDD §2): awaitingInjection에서 교정 대신 원문(사전 치환본)을 주입.
    /// 키 인터셉트 배선은 태스크 2.6.
    func tabPressed() {
        guard state == .awaitingInjection, let raw = rawText else { return }
        metrics.recordTabRaw()  // 교정 거부(원문 선택) 지표 — 리뷰 N6
        injectionTimer?.cancel()
        Task { await performInjection(raw) }
    }

    // MARK: - 파이프라인: transcribing → refining → awaitingInjection → injecting

    private func finishRecording() {
        sessionT0 = metricsClock.now  // T0 = hotkeyUp/60s 마감 — stop() 비용 포함 측정 (TDD §6, 리뷰 W1)
        currentMetrics = SessionMetrics()
        let samples = audioCapture.stop()
        transition(to: .transcribing)
        Task { await runTranscribe(samples) }
    }

    /// T0 기준 경과 시간 (세션 밖이면 nil).
    private func elapsedSinceT0() -> Duration? {
        guard let t0 = sessionT0 else { return nil }
        return metricsClock.now - t0
    }

    /// 무음 판정 에너지 문턱 (RMS). 1.3 실측에서 발화 RMS ≈ 0.0097 — 그 1/5 수준의 잠정값.
    /// 실기기 캘리브레이션용으로 매 세션 RMS를 로깅한다 (숫자만 — 개인 데이터 아님).
    private static let energyGate: Float = 0.002

    private func runTranscribe(_ samples: [Float]) async {
        // 빈 캡처는 whisper_full에 넘기면 baseAddress가 nil이라 전사 전에 단락 → sttFailed.
        guard !samples.isEmpty, await transcribeEngine.isLoaded else {
            sttFailed(reason: "빈 입력 또는 STT 엔진 미준비")
            return
        }
        // 에너지 게이트 — 무음 환각 2차 방어. whisper는 무음에서 "감사합니다"류를 확신을 갖고
        // 지어내(no_speech 확률 낮음, 실기기 관찰) 1차 방어(no_speech 필터)를 뚫는다.
        // 물리 신호 에너지는 못 속이므로 모델 이전에 거른다.
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        logger.info("[stt] 입력 RMS \(String(format: "%.4f", rms), privacy: .public)")
        guard rms >= Self.energyGate else {
            sttFailed(reason: "무음 입력 (RMS \(String(format: "%.4f", rms)))")
            return
        }
        do {
            let raw = try await transcribeEngine.transcribe(
                samples: samples,
                initialPrompt: promptBuilder.whisperInitialPrompt()
            )
            let text = userDictionary.apply(to: raw)  // 사전 치환 (TDD §3.6 ①)
            logger.info("[stt] 전사+치환 완료 — \(text.count, privacy: .public)자")
            sttDone(text)
        } catch {
            sttFailed(reason: String(describing: error))
        }
    }

    /// sttFailed → idle + error HUD "인식하지 못했어요" 1.5s (TDD §2/§5, PLAN 2.4).
    private func sttFailed(reason: String) {
        logger.warning("[stt] 실패 — \(reason, privacy: .public)")
        transition(to: .idle)
        hud.flashError("인식하지 못했어요", duration: .milliseconds(1500))
    }

    /// sttDone(raw) → refining: 원문 dim 표시 + 스트리밍 시작 (TDD §2).
    private func sttDone(_ text: String) {
        guard state == .transcribing else { return }
        rawText = text
        currentMetrics.tRaw = elapsedSinceT0()  // T_raw (TDD §6)
        transition(to: .refining)
        Task { await runRefine(text) }
    }

    private func runRefine(_ raw: String) async {
        guard await refineEngine.isLoaded else {
            logger.warning("[refine] 엔진 미준비 — 원문 폴백 (원칙 3)")
            enterAwaitingInjection(with: raw, usedFallback: true)
            return
        }

        let progress = RefineProgress()
        refineProgress = progress
        do {
            let refined = try await refineEngine.refine(
                rawText: raw,
                onToken: { [weak self] token in
                    // 스트리밍 렌더 (TDD §2 token(t) → HUD.append) — 누적 스냅샷을 MainActor로 홉.
                    let snapshot = progress.appendToken(token)
                    // 토큰 도착 시각은 콜백 스레드에서 캡처 (홉 지연 배제 — 리뷰 N3).
                    let tokenInstant = ContinuousClock().now
                    Task { @MainActor in
                        // 세션 가드 — 취소된 이전 refine의 지연 토큰이 새 세션 계측·HUD를
                        // 오염시키지 않는다 (리뷰 W2).
                        guard let self, self.state == .refining,
                              self.refineProgress === progress else { return }
                        if self.currentMetrics.tFirstToken == nil, let t0 = self.sessionT0 {
                            self.currentMetrics.tFirstToken = tokenInstant - t0  // T_first_token
                        }
                        self.hud.setStreamedText(snapshot)
                    }
                },
                isCancelled: { progress.shouldCancel() }
            )
            refineProgress = nil
            guard state == .refining else { return }
            // 빈 교정은 원문 폴백 (원칙 3 — 말이 증발하지 않는다).
            let result = refined.isEmpty ? raw : refined
            logger.info("[refine] 완료 — \(result.count, privacy: .public)자")
            enterAwaitingInjection(with: result, usedFallback: refined.isEmpty)
        } catch RefineError.cancelled {
            refineProgress = nil
            if progress.escRequested {
                // escPressed가 이미 idle로 전이함 — 여기는 뒷정리 로그만 (이중 전이 방지).
                logger.info("[refine] Esc 취소 완료")
                if state == .refining { transition(to: .idle) }
            } else {
                // llmTimeout → 원문 폴백 후 정상 흐름 계속 (TDD §2/§5, 원칙 3) + "원문 사용" 배지.
                logger.warning("[refine] llmTimeout — 원문 폴백")
                enterAwaitingInjection(with: raw, usedFallback: true)
            }
        } catch {
            refineProgress = nil
            // llmError → 원문 폴백 (TDD §2/§5, 원칙 3) + "원문 사용" 배지.
            logger.error("[refine] llmError — 원문 폴백: \(String(describing: error), privacy: .public)")
            enterAwaitingInjection(with: raw, usedFallback: true)
        }
    }

    /// refining → awaitingInjection: ready HUD(힌트 바, 폴백 배지) + N초 타이머 시작 (TDD §2).
    private func enterAwaitingInjection(with text: String, usedFallback: Bool) {
        guard state == .refining else { return }  // 전이표에 있는 진입 경로는 refining뿐
        currentMetrics.tReady = elapsedSinceT0()  // T_ready (TDD §6, 폴백 포함)
        currentMetrics.usedFallback = usedFallback
        refinedText = text
        transition(to: .awaitingInjection)
        hud.update(.ready(raw: rawText ?? text, text: text, usedFallback: usedFallback))
        injectionTimer = Task { @MainActor in
            try? await Task.sleep(for: autoInjectDelay)
            guard !Task.isCancelled else { return }
            await self.performInjection(text)
        }
    }

    /// awaitingInjection → injecting → idle (TDD §2). 진입 가드 — Task 큐잉과 실행 사이에
    /// Esc 등으로 상태가 바뀌었으면 주입하지 않는다 (idle→injecting은 전이표에 없음).
    private func performInjection(_ text: String) async {
        guard state == .awaitingInjection else { return }
        let raw = rawText ?? text  // idle 전이가 세션 데이터를 폐기하므로 유지 카드용으로 캡처
        transition(to: .injecting)
        var injected = false
        do {
            // 자기창 가드 (TDD §3.7 대상 검증): frontmost가 자기 자신이면 클립보드를 건드리지
            // 않고 typed error로 실패 처리 — 사전 편집 등 자체 창의 TextField에 ⌘V가 꽂혀
            // 대상·사전이 오염되는 사고 차단 (2.8). Injecting 구현 공통 규칙이라 주입기 앞의
            // 이 한 곳에서 검사한다. check-then-act라 검사~⌘V 착지 사이 수 ms 창에서의 포커스
            // 전환까지 막지는 못한다(축소이지 절대 보장 아님). frontmost가 nil이면(드묾 —
            // 식별 불가) 기존 동작대로 주입을 진행한다.
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                throw InjectionError.selfIsFrontmost
            }
            logger.debug("[inject] 대상 앱: \(frontmost?.bundleIdentifier ?? "?", privacy: .private)")
            try await injector.inject(text)
            injected = true
            logger.info("[inject] 주입 완료")
        } catch InjectionError.selfIsFrontmost {
            logger.warning("[inject] 자기 앱이 frontmost — 주입 거부 (TDD §3.7 가드)")
        } catch {
            logger.error("[inject] 주입 실패: \(String(describing: error), privacy: .public)")
        }
        if injected {
            currentMetrics.tInject = elapsedSinceT0()  // T_inject (TDD §6)
            metrics.recordCompleted(currentMetrics)
        }
        transition(to: .idle)
        if injected {
            // 주입 후 원문·교정 비교 카드를 5s 유지 (도그푸딩 2026-07-12 — 충분한 관찰 시간).
            // 새 세션이 시작되면 즉시 대체된다.
            hud.flash(.injected(raw: raw, text: text), duration: .seconds(5))
        } else {
            // injecting --failed--> idle (TDD §2, 2026-07-17): 결과 텍스트를 5s 유지해
            // 발화가 증발하지 않게 한다 (§5 최소 이행, 원칙 3). 복사 버튼은 후속.
            hud.flash(.injectFailed(raw: raw, text: text), duration: .seconds(5))
        }
    }

    // MARK: - 전이

    private func transition(to next: SessionState) {
        logger.debug("전이: \(String(describing: self.state), privacy: .public) → \(String(describing: next), privacy: .public)")
        state = next
        if next == .idle {
            // 세션 데이터 폐기 + 잔여 타이머 정리 (음성·텍스트는 메모리에만, 세션 종료 시 폐기).
            rawText = nil
            refinedText = nil
            refineProgress = nil
            injectionTimer?.cancel()
            injectionTimer = nil
            sessionT0 = nil  // 계측 세션 경계 (elapsedSinceT0의 "세션 밖 nil" 계약)
        }
        updateHUD(for: next)
        menuBarUpdater?(next)
        keyInterceptUpdater?(interceptMode(for: next))
    }

    /// 세션 상태 → keyDown 인터셉트 모드 (TDD §3.1). 소비 게이트는 세션 상태 기준 —
    /// injected 유지 카드(idle)에선 절대 소비하지 않는다 (PLAN 2.6).
    private func interceptMode(for state: SessionState) -> KeyInterceptMode {
        switch state {
        case .refining: return .escOnly
        case .awaitingInjection: return .escAndTab
        default: return .none
        }
    }

    /// 세션 상태 → HUD 매핑 (TDD §3.8 상태별 뷰, 2.5).
    private func updateHUD(for state: SessionState) {
        switch state {
        case .idle:
            hud.update(.hidden)
        case .recording:
            hud.update(.recording)
        case .transcribing:
            hud.update(.processing)
        case .refining:
            // 원문 dim + 스트리밍 텍스트 (PRD §4 ③). 토큰은 appendStreamToken으로 쌓임.
            hud.update(.refining(raw: rawText ?? "", streamed: ""))
        case .awaitingInjection:
            break  // enterAwaitingInjection이 .ready(폴백 배지 포함)를 직접 설정
        case .injecting:
            break  // 주입(수백 ms) 동안 ready 표시 유지 — idle 전이에서 소멸 (TDD §2 done→소멸)
        }
    }
}
