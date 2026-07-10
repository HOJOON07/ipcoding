import Foundation
import os

/// 세션 상태 (TDD §2). Phase 1 축소판 — refining/awaitingInjection은 Phase 2(2.4)에서 추가.
enum SessionState: Equatable {
    case idle
    case recording
    case transcribing
    case injecting
}

/// 앱의 심장 (TDD §2). 한 번의 발화 = 한 세션. 모든 모듈은 이벤트를 코디네이터로 보내고,
/// 코디네이터만 상태를 전이시킨다. @MainActor — 상태·전이는 단일 스레드에서 직렬 처리되어
/// 겹친 세션의 레이스가 원천 차단된다(임시 배선의 sessionGeneration 가드를 대체).
@MainActor
final class SessionCoordinator {

    private(set) var state: SessionState = .idle

    /// 세대 토큰 — hotkeyDown이 미룬 엔진 start를, 그 사이 도착한 up/cancel이 무효화하는 데 쓴다.
    /// (탭 콜백을 블로킹하지 않으려 start를 Task로 미루므로 생기는 "start-pending 중 stop" 가드.)
    private var startGeneration = 0

    private let audioCapture: AudioCapture
    private let transcribeEngine: TranscribeEngine
    private let userDictionary: UserDictionary
    private let promptBuilder: PromptBuilder
    private let injector: any Injecting
    private let hud: HUDController
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "coordinator")

    init(
        audioCapture: AudioCapture,
        transcribeEngine: TranscribeEngine,
        userDictionary: UserDictionary,
        promptBuilder: PromptBuilder,
        injector: any Injecting,
        hud: HUDController
    ) {
        self.audioCapture = audioCapture
        self.transcribeEngine = transcribeEngine
        self.userDictionary = userDictionary
        self.promptBuilder = promptBuilder
        self.injector = injector
        self.hud = hud
        // HUD 레벨 미터가 마이크 입력에 반응하도록 연결.
        hud.viewModel.levelProvider = { [weak audioCapture] in audioCapture?.currentLevel ?? 0 }
    }

    // MARK: - 이벤트 (HotkeyManager·AudioCapture가 코디네이터로 전달)

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
            // 이 start가 실행되기 전에 up/cancel이 왔으면(세대 변경 또는 상태 이탈) 시작하지 않는다.
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
        startGeneration += 1  // pending start 무효화.
        _ = audioCapture.stop()
        transition(to: .idle)
    }

    /// 60초 상한 — recording → transcribing 강제 마감 (TDD §2 maxDuration).
    func audioReachedMaxDuration() {
        guard state == .recording else { return }
        finishRecording()
    }

    /// recording 종료 공통 경로 (정상 릴리즈·60초 마감): 버퍼 확보 → transcribing → 전사·주입.
    private func finishRecording() {
        let samples = audioCapture.stop()
        transition(to: .transcribing)
        Task { await runTranscribeAndInject(samples) }
    }

    // MARK: - 전사 → 주입 (Phase 2에서 refining 삽입)

    private func runTranscribeAndInject(_ samples: [Float]) async {
        // 빈 캡처(무음/취소 직후)·엔진 미준비 → idle 복귀. 빈 배열은 whisper_full에 넘기면
        // baseAddress가 nil이라 전사 전에 단락한다.
        // TDD §2/§5는 sttFailed 시 error HUD("인식하지 못했어요") 1.5s를 규정하나, Phase 1 축소판은
        // 무표시 idle로 소멸한다(PLAN 1.8/1.9). error HUD는 Phase 2 배치(PLAN 2.4/2.5).
        guard !samples.isEmpty, await transcribeEngine.isLoaded else {
            logger.warning("[stt] 빈 입력 또는 엔진 미준비 — idle 복귀")
            transition(to: .idle)
            return
        }

        let text: String
        do {
            let raw = try await transcribeEngine.transcribe(
                samples: samples,
                initialPrompt: promptBuilder.whisperInitialPrompt()
            )
            text = userDictionary.apply(to: raw)  // 사전 치환 (TDD §3.6 ①)
            logger.info("[stt] 전사+치환 완료 — \(text.count, privacy: .public)자")
        } catch {
            // sttFailed → idle (error HUD는 Phase 2, 위 주석 참조).
            logger.error("[stt] 전사 실패: \(String(describing: error), privacy: .public)")
            transition(to: .idle)
            return
        }

        // 상태 전이가 직렬이라 이 시점 state는 반드시 transcribing — 겹친 세션은 hotkeyDown에서 이미 차단됨.
        transition(to: .injecting)
        do {
            try await injector.inject(text)
            logger.info("[inject] 주입 완료")
        } catch {
            logger.error("[inject] 주입 실패: \(String(describing: error), privacy: .public)")
        }
        transition(to: .idle)
    }

    // MARK: - 전이

    private func transition(to next: SessionState) {
        logger.debug("전이: \(String(describing: self.state), privacy: .public) → \(String(describing: next), privacy: .public)")
        state = next
        updateHUD(for: next)
    }

    /// 세션 상태를 HUD 표시 상태로 매핑 (Phase 1: recording 레벨미터 / transcribing·injecting 스피너).
    /// error 상태는 Phase 2에 추가 (HUDState.error, PLAN 2.4/2.5) — 현재 sttFailed는 hidden으로 소멸.
    private func updateHUD(for state: SessionState) {
        switch state {
        case .idle:        hud.update(.hidden)
        case .recording:   hud.update(.recording)
        case .transcribing, .injecting: hud.update(.processing)
        }
    }
}
