// AVFAudio의 @Sendable 콜백(installTap, AVAudioConverterInputBlock)이 아직 완전 어노테이션이
// 아니라서 preconcurrency로 완화 — 실제 동기화는 CaptureSink의 lock이 담당한다.
@preconcurrency import AVFoundation
import os

enum AudioCaptureError: Error {
    case alreadyRunning
    /// 마이크 TCC 권한 없음 (거부·미결정) — 온보딩/설정으로 유도해야 함.
    case microphoneNotAuthorized
    /// 입력 장치가 없거나 사용 불가 (포맷 0Hz) — 온보딩에서 변환 실패와 구분해 안내해야 함.
    case noInputDevice
    case converterUnavailable
    case engineStartFailed(any Error)
}

@MainActor
protocol AudioCaptureDelegate: AnyObject {
    /// 60초 상한 도달 — 코디네이터가 stop()으로 강제 마감한다 (TDD §2 maxDuration 전이).
    func audioCaptureDidReachMaxDuration()
}

/// 세션 단위 마이크 캡처 (TDD §3.2). 시작/정지는 코디네이터가 호출한다.
/// 엔진은 세션마다 start/stop — 상시 가동 금지 (마이크 표시등·BT HFP 전환은 발화 중에만).
@MainActor
final class AudioCapture {

    static let sampleRate: Double = 16_000
    static let maxDuration: TimeInterval = 60

    weak var delegate: AudioCaptureDelegate?
    private(set) var isRunning = false

    private var engine: AVAudioEngine?
    private var sink: CaptureSink?
    private var configChangeObserver: (any NSObjectProtocol)?
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "audio")

    // MARK: - 마이크 권한 (macOS TCC: kTCCServiceMicrophone)
    // 전제: Hardened Runtime + com.apple.security.device.audio-input 엔타이틀먼트.
    // 엔타이틀먼트가 없으면 아래 요청은 다이얼로그 없이 즉시 거부된다.

    static var microphoneAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 미결정 상태면 다이얼로그를 띄우고 결과를 반환. 이미 결정됐으면 즉시 현재 상태 기준.
    /// requestAccess 콜백은 임의 큐로 오지만 async 형태라 호출부 격리로 자동 복귀.
    @discardableResult
    static func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch microphoneAuthorization {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// 캡처 시작. 마이크 권한이 authorized가 아니면 시작하지 않는다 (요청은 앱 시작 시 선행).
    func start() throws {
        guard !isRunning else { throw AudioCaptureError.alreadyRunning }
        guard Self.microphoneAuthorization == .authorized else {
            throw AudioCaptureError.microphoneNotAuthorized
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        let sink = CaptureSink(
            converter: converter,
            targetFormat: targetFormat,
            maxFrames: Int(Self.sampleRate * Self.maxDuration)
        ) { [weak self] in
            // 오디오 스레드에서 오는 콜백 — MainActor로 홉.
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.logger.warning("60초 상한 도달 — 강제 마감 요청")
                self.delegate?.audioCaptureDidReachMaxDuration()
            }
        }

        // 탭 콜백은 오디오 스레드에서 실행된다 — sink 내부에서만 상태를 만진다.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            sink.append(buffer)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error)
        }

        // 장치 변경(BT 해제 등) 시 엔진이 멈출 수 있음 (macos-quirks) — 우선 로그, 처리는 1.8에서.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [logger] _ in
            logger.warning("오디오 엔진 구성 변경 감지 (입력 장치 변경 가능성)")
        }

        self.engine = engine
        self.sink = sink
        isRunning = true
        logger.info("캡처 시작 (입력: \(inputFormat.sampleRate, privacy: .public)Hz \(inputFormat.channelCount, privacy: .public)ch → 16kHz mono)")
    }

    /// 정지하고 세션 버퍼(16kHz mono Float32) 전체를 반환한다 (스트리밍 아님, PRD §4).
    @discardableResult
    func stop() -> [Float] {
        guard isRunning, let engine, let sink else { return [] }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }

        let samples = sink.drain()
        self.engine = nil
        self.sink = nil
        self.configChangeObserver = nil
        isRunning = false

        let seconds = Double(samples.count) / Self.sampleRate
        logger.info("캡처 종료 — \(samples.count, privacy: .public) 샘플 (\(String(format: "%.2f", seconds), privacy: .public)s)")
        return samples
    }
}

/// 오디오 스레드에서 도는 수집기. 내부 상태는 lock으로 보호 — 그래서 @unchecked Sendable.
private final class CaptureSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let maxFrames: Int
    private let onMaxDuration: @Sendable () -> Void

    private let lock = NSLock()
    private var samples: [Float] = []
    private var maxFired = false
    private var closed = false

    init(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        maxFrames: Int,
        onMaxDuration: @escaping @Sendable () -> Void
    ) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.maxFrames = maxFrames
        self.onMaxDuration = onMaxDuration
        samples.reserveCapacity(maxFrames)
    }

    /// 탭 콜백 (오디오 스레드): 네이티브 포맷 버퍼를 16kHz mono로 변환해 누적.
    /// converter는 스레드 안전하지 않으므로 convert 호출까지 lock 안에서 수행한다 —
    /// drain() 이후(closed) 늦게 도착한 콜백은 드롭.
    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var reached = false
        lock.lock()
        if closed {
            lock.unlock()
            return
        }

        // 입력 블록은 convert() 호출 안에서 동기 실행된다 — 동시 접근 없음 (컴파일러 보수 판정 완화).
        nonisolated(unsafe) var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status != .error {
            reached = appendFramesLocked(from: out)
        }
        lock.unlock()

        if reached {
            onMaxDuration()
        }
    }

    /// 남은 변환 잔여분까지 뽑아 전체 버퍼를 반환하고 마감한다. 이후 append는 무시된다.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        closed = true

        // 샘플레이트 변환기의 내부 잔여 프레임 플러시 (converter 접근도 lock 안).
        if let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) {
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if status != .error {
                _ = appendFramesLocked(from: out)
            }
        }

        let result = samples
        samples = []
        return result
    }

    /// lock을 쥔 상태에서만 호출할 것. 상한 초과분은 드롭(클램프)하고, 상한 최초 도달 시 true.
    private func appendFramesLocked(from out: AVAudioPCMBuffer) -> Bool {
        guard out.frameLength > 0, let channelData = out.floatChannelData else { return false }
        let frames = UnsafeBufferPointer(start: channelData[0], count: Int(out.frameLength))

        let room = maxFrames - samples.count
        guard room > 0 else { return false }
        samples.append(contentsOf: frames.prefix(room))

        if samples.count >= maxFrames && !maxFired {
            maxFired = true
            return true
        }
        return false
    }
}
