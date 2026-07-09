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
}

/// ⌘+Fn 홀드 감지 전용 이벤트 탭 (TDD §3.1).
/// - flagsChanged만 구독한다. Tab/Esc 인터셉트(keyDown)는 태스크 2.6에서 확장.
/// - 이벤트를 소비하지 않는다 — flagsChanged는 항상 시스템에 통과시킨다.
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

    /// 디바운스 문턱 (TDD §3.1: down 후 200ms 미만의 up은 취소).
    private let debounceThreshold: TimeInterval = 0.2

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var comboActive = false
    private var comboDownAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "hotkey")

    /// 이벤트 탭 생성·시작. 실패(권한 없음) 시 false.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return state == .running }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue

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
        logger.info("이벤트 탭 시작 (flagsChanged, ⌘+Fn)")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        comboActive = false
        comboDownAt = nil
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

    /// kAXTrustedCheckOptionPrompt 전역이 concurrency-safe하지 않아 1회 읽어 격리 래핑.
    /// CFString 상수는 불변이라 실질 안전.
    private nonisolated(unsafe) static let axPromptKey =
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

    /// 권한 다이얼로그 유도 (개발·온보딩용). 이미 신뢰된 경우 true.
    static func promptForAccessibilityIfNeeded() -> Bool {
        let options = [axPromptKey: true] as CFDictionary
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
