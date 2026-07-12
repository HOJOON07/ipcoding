import AppKit
@preconcurrency import CoreGraphics
import os

/// HotkeyManager가 발행하는 이벤트. 모든 상태 판단은 SessionCoordinator 몫이다 (TDD §2).
///
/// 계약: 델리게이트 메서드는 이벤트 탭 콜백 안에서 동기 호출된다. 콜백 지연은 탭 타임아웃
/// (`kCGEventTapDisabledByTimeout`)을 유발하므로, 구현측은 무거운 작업(오디오 엔진 시작 등)을
/// 즉시 리턴 후 Task로 비동기 처리해야 한다.
@MainActor
protocol HotkeyManagerDelegate: AnyObject {
    /// ⌘+Fn 콤보가 눌림 (false→true 엣지).
    func hotkeyDown()
    /// ⌘+Fn 콤보가 풀림. 디바운스(200ms)를 통과한 정상 릴리즈.
    func hotkeyUp(heldFor duration: TimeInterval)
    /// down 후 200ms 미만에 풀림 — 실수 입력으로 보고 세션 취소 (TDD §3.1).
    func hotkeyCancelled()
    /// Esc가 소비됨 (인터셉트 모드 중에만 발행, 태스크 2.6 — TDD §2 escPressed).
    func escKeyPressed()
    /// Tab이 소비됨 (escAndTab 모드 중에만 발행 — TDD §2 tabPressed).
    func tabKeyPressed()
}

/// keyDown 인터셉트 모드 (TDD §3.1/§2). 코디네이터가 세션 상태 전이에 맞춰 지시한다 —
/// HotkeyManager는 자체 상태 판단 없이 따르기만 한다 (단방향 규칙).
/// 조건 실수 = 시스템 전체 Tab/Esc 사망 사고 (macos-quirks) — 게이트는 세션 상태 기준이며
/// injected 유지 카드(idle) 중에는 반드시 .none이어야 한다.
enum KeyInterceptMode: Equatable {
    case none
    /// refining: Esc(취소)만 소비.
    case escOnly
    /// awaitingInjection: Esc(취소)·Tab(원문 주입) 소비.
    case escAndTab
}

/// ⌘+Fn 홀드 감지 + Tab/Esc 인터셉트 이벤트 탭 (TDD §3.1).
/// - flagsChanged(핫키)와 keyDown(Tab/Esc)을 구독한다.
/// - flagsChanged는 절대 소비하지 않는다. keyDown은 인터셉트 모드(코디네이터 지시)에 한해
///   Esc(53)·Tab(48)만 소비 — 조건은 handleKeyDown의 3중 안전장치 참조.
/// - 탭은 메인 런루프에 붙인다: 콜백이 메인 스레드에서 돌므로 @MainActor 진입이 안전하다.
@MainActor
final class HotkeyManager {

    enum TapState: Equatable {
        case notStarted
        case running
        case permissionDenied
    }

    weak var delegate: HotkeyManagerDelegate?
    private(set) var state: TapState = .notStarted

    /// 현재 keyDown 인터셉트 모드 — 코디네이터가 전이 시 갱신 (기본 .none = 아무것도 소비 안 함).
    var interceptMode: KeyInterceptMode = .none

    /// 디바운스 문턱 (TDD §3.1: down 후 200ms 미만의 up은 취소).
    private let debounceThreshold: TimeInterval = 0.2

    // MainActor 메서드에서만 쓰지만, deinit(비격리)의 최후 방어선 접근을 위해 unsafe 표기.
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private var comboActive = false
    private var comboDownAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "hotkey")

    /// 이벤트 탭 생성·시작. 실패(권한 없음) 시 false.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return state == .running }

        // flagsChanged(⌘+Fn) + keyDown(Tab/Esc 인터셉트, 태스크 2.6).
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        // C 함수 포인터라 self 캡처 불가 — refcon으로 전달.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            // 탭이 메인 런루프에 있으므로 여기는 항상 메인 스레드다.
            return MainActor.assumeIsolated {
                manager.handle(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // tapCreate nil = 손쉬운 사용(또는 입력 모니터링) 권한 없음 (macos-quirks).
            state = .permissionDenied
            logger.error("이벤트 탭 생성 실패 — 손쉬운 사용 권한 필요")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        state = .running
        logger.info("이벤트 탭 시작 (flagsChanged ⌘+Fn / keyDown Tab·Esc 인터셉트)")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        comboActive = false
        comboDownAt = nil
        interceptMode = .none
        state = .notStarted
    }

    /// 소유자는 해제 전 stop() 호출을 보장해야 한다 (refcon이 unretained self).
    /// deinit은 최후 방어선 — 살아있는 탭이 dangling refcon을 역참조하지 못하게 무효화만 한다.
    deinit {
        if let tap {
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    /// 권한 다이얼로그 유도 (개발·온보딩용). 이미 신뢰된 경우 true.
    static func promptForAccessibilityIfNeeded() -> Bool {
        // kAXTrustedCheckOptionPrompt(C 전역)는 어떤 접근 방식도 strict concurrency에 걸린다.
        // raw 값은 AXUIElement.h에 문서화된 안정 상수라 리터럴 사용 (값 변경 이력 없음).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 콜백 처리 (메인 스레드)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 탭이 시스템에 의해 비활성화됨 — 즉시 재활성화 (macos-quirks: 콜백 지연·유저 입력).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.warning("이벤트 탭 비활성화 감지 (\(type.rawValue)) — 재활성화")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resyncComboStateAfterReenable()
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            return handleKeyDown(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let comboNow = flags.contains(.maskCommand) && flags.contains(.maskSecondaryFn)

        if comboNow && !comboActive {
            comboActive = true
            comboDownAt = clock.now
            logger.debug("hotkeyDown (⌘+Fn)")
            delegate?.hotkeyDown()
        } else if !comboNow && comboActive {
            comboActive = false
            let duration: TimeInterval
            if let downAt = comboDownAt {
                let elapsed = clock.now - downAt
                duration = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
            } else {
                // comboActive인데 downAt이 없으면 상태 추적 버그 — 은폐하지 않는다.
                assertionFailure("comboActive인데 comboDownAt이 nil")
                logger.error("콤보 상태 불일치 — duration 0으로 취소 처리")
                duration = 0
            }
            comboDownAt = nil

            if duration < debounceThreshold {
                logger.debug("hotkeyCancelled (\(String(format: "%.0f", duration * 1000), privacy: .public)ms < 200ms)")
                delegate?.hotkeyCancelled()
            } else {
                logger.debug("hotkeyUp (held \(String(format: "%.2f", duration), privacy: .public)s)")
                delegate?.hotkeyUp(heldFor: duration)
            }
        }

        // flagsChanged는 절대 소비하지 않는다 — 시스템·다른 앱의 modifier 처리에 영향 금지.
        return Unmanaged.passUnretained(event)
    }

    /// Tab/Esc 인터셉트 (태스크 2.6, TDD §3.1/§2). nil 반환 = 이벤트 소비(대상 앱 미전달).
    /// 안전장치 3중: ① interceptMode(.none이면 무조건 통과 — 코디네이터가 세션 상태로 지시)
    /// ② ⌘/⌃/⌥ 조합 통과(⌘Tab 앱 전환 등 시스템 단축키 보호) ③ 대상 키코드(53 Esc, 48 Tab) 외 통과.
    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard interceptMode != .none else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch keyCode {
        case 53:  // Esc — refining·awaitingInjection 공통 (TDD §2 escPressed)
            if isRepeat { return nil }  // 홀드 리피트는 소비만 (델리게이트 재발행 금지)
            logger.info("Esc 소비 (모드 \(String(describing: self.interceptMode), privacy: .public))")
            delegate?.escKeyPressed()
            return nil
        case 48 where interceptMode == .escAndTab:  // Tab — awaitingInjection 한정 (tabPressed)
            // Shift+Tab(역들여쓰기)은 별개 의도 — 통과 (2.6 리뷰 N2).
            if flags.contains(.maskShift) { return Unmanaged.passUnretained(event) }
            if isRepeat { return nil }  // 홀드 리피트 소비 (잔여 엣지: injecting 전이 후 리피트는
                                        // 모드가 none이라 통과 — 창 ~0.3s, VERIFY 기록)
            logger.info("Tab 소비")
            delegate?.tabKeyPressed()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 탭 비활성 구간에서 콤보 릴리즈를 놓쳤을 수 있다 — 실제 시스템 플래그와 재동기화.
    /// 릴리즈가 유실된 경우 duration을 신뢰할 수 없으므로 세션 취소로 처리한다.
    private func resyncComboStateAfterReenable() {
        guard comboActive else { return }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let comboStillHeld = flags.contains(.maskCommand) && flags.contains(.maskSecondaryFn)
        if !comboStillHeld {
            comboActive = false
            comboDownAt = nil
            logger.warning("탭 비활성 구간에서 콤보 릴리즈 유실 — 세션 취소 발행")
            delegate?.hotkeyCancelled()
        }
    }
}
