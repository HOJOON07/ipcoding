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

    func markToken() {
        lock.lock(); defer { lock.unlock() }
        firstTokenSeen = true
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

    /// 세대 토큰 — hotkeyDown이 미룬 엔진 start를, 그 사이 도착한 up/cancel이 무효화하는 데 쓴다.
    private var startGeneration = 0

    // 세션 데이터 (TDD §2 Session). idle 복귀 시 폐기.
    private var rawText: String?
    private var refinedText: String?

    /// refining 중 콜백과 공유하는 진행 상태 (Esc·타임아웃).
    private var refineProgress: RefineProgress?
    /// awaitingInjection의 자동 주입 타이머 태스크.
    private var injectionTimer: Task<Void, Never>?

    /// 자동 주입 대기시간 N — 기본 1.0s (PRD §10-3, 태스크 2.7에서 도그푸딩으로 확정·조절 UI).
    private let autoInjectDelay: Duration = .seconds(1)

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
            transition(to: .idle)
        case .awaitingInjection:
            injectionTimer?.cancel()
            transition(to: .idle)
        default:
            break
        }
    }

    /// Tab (TDD §2): awaitingInjection에서 교정 대신 원문(사전 치환본)을 주입.
    /// 키 인터셉트 배선은 태스크 2.6.
    func tabPressed() {
        guard state == .awaitingInjection, let raw = rawText else { return }
        injectionTimer?.cancel()
        Task { await performInjection(raw) }
    }

    // MARK: - 파이프라인: transcribing → refining → awaitingInjection → injecting

    private func finishRecording() {
        let samples = audioCapture.stop()
        transition(to: .transcribing)
        Task { await runTranscribe(samples) }
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

    /// sttDone(raw) → refining (TDD §2). LLM 미준비면 곧장 원문으로 awaitingInjection (원칙 3).
    private func sttDone(_ text: String) {
        guard state == .transcribing else { return }
        rawText = text
        transition(to: .refining)
        Task { await runRefine(text) }
    }

    private func runRefine(_ raw: String) async {
        guard await refineEngine.isLoaded else {
            logger.warning("[refine] 엔진 미준비 — 원문 폴백 (원칙 3)")
            enterAwaitingInjection(with: raw)
            return
        }

        let progress = RefineProgress()
        refineProgress = progress
        do {
            let refined = try await refineEngine.refine(
                rawText: raw,
                onToken: { _ in progress.markToken() },  // 스트리밍 HUD 렌더는 2.5
                isCancelled: { progress.shouldCancel() }
            )
            refineProgress = nil
            guard state == .refining else { return }
            // 빈 교정은 원문 폴백 (원칙 3 — 말이 증발하지 않는다).
            let result = refined.isEmpty ? raw : refined
            logger.info("[refine] 완료 — \(result.count, privacy: .public)자")
            enterAwaitingInjection(with: result)
        } catch RefineError.cancelled {
            refineProgress = nil
            if progress.escRequested {
                // escPressed가 이미 idle로 전이함 — 여기는 뒷정리 로그만 (이중 전이 방지).
                logger.info("[refine] Esc 취소 완료")
                if state == .refining { transition(to: .idle) }
            } else {
                // llmTimeout → 원문 폴백 후 정상 흐름 계속 (TDD §2/§5, 원칙 3). "원문 사용" 배지는 2.5.
                logger.warning("[refine] llmTimeout — 원문 폴백")
                enterAwaitingInjection(with: raw)
            }
        } catch {
            refineProgress = nil
            // llmError → 원문 폴백 (TDD §2/§5, 원칙 3).
            logger.error("[refine] llmError — 원문 폴백: \(String(describing: error), privacy: .public)")
            enterAwaitingInjection(with: raw)
        }
    }

    /// refining → awaitingInjection: N초 타이머 시작 (TDD §2). ready HUD·힌트 바는 2.5.
    private func enterAwaitingInjection(with text: String) {
        guard state == .refining else { return }  // 전이표에 있는 진입 경로는 refining뿐
        refinedText = text
        transition(to: .awaitingInjection)
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
        transition(to: .injecting)
        do {
            try await injector.inject(text)
            logger.info("[inject] 주입 완료")
        } catch {
            // 주입 실패 시 HUD 결과 유지 + 복사 버튼은 TDD §5 — HUD 확장(2.5+) 몫. 지금은 로그만.
            logger.error("[inject] 주입 실패: \(String(describing: error), privacy: .public)")
        }
        transition(to: .idle)
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
        }
        updateHUD(for: next)
    }

    /// 세션 상태 → HUD 매핑. raw 표시·스트리밍 렌더·ready 힌트 바는 2.5에서 확장 —
    /// 2.4는 refining/awaitingInjection도 스피너로 표시한다.
    private func updateHUD(for state: SessionState) {
        switch state {
        case .idle:        hud.update(.hidden)
        case .recording:   hud.update(.recording)
        case .transcribing, .refining, .awaitingInjection, .injecting:
            hud.update(.processing)
        }
    }
}
