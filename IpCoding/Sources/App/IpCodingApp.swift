import AppKit
import AVFoundation
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
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "app")
    /// 임시 배선의 Task 홉 순서 보장용 — down/up이 각각 세대를 올려, 늦게 실행된
    /// start가 이미 끝난 세션을 되살리지 못하게 한다 (1.8에서 코디네이터 직렬 소비로 대체).
    private var sessionGeneration = 0

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

        startHotkey()
    }

    /// 태스크 1.2: 이벤트 탭 시작. 코디네이터(1.8) 전까지는 델리게이트를 앱이 맡아 로그로 검증.
    private func startHotkey() {
        hotkeyManager.delegate = self
        audioCapture.delegate = self
        if !hotkeyManager.start() {
            // 권한 없음 — 시스템 다이얼로그로 유도 후, 부여되면 재시작 필요 (온보딩은 태스크 3.1).
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

// MARK: - HotkeyManagerDelegate (태스크 1.8에서 SessionCoordinator로 이관)

extension IpCodingApp: HotkeyManagerDelegate {
    func hotkeyDown() {
        logger.info("[hotkey] DOWN")
        sessionGeneration += 1
        let generation = sessionGeneration
        // 무거운 작업 금지 계약(HotkeyManagerDelegate) — 엔진 시작은 비동기 홉.
        Task { @MainActor in
            // up/cancel이 먼저 처리돼 세대가 바뀌었으면 시작하지 않는다 (엔진 방치 방지).
            guard generation == self.sessionGeneration else { return }
            do {
                try self.audioCapture.start()
            } catch {
                self.logger.error("캡처 시작 실패: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func hotkeyUp(heldFor duration: TimeInterval) {
        logger.info("[hotkey] UP — \(String(format: "%.2f", duration), privacy: .public)s 홀드")
        sessionGeneration += 1
        Task { @MainActor in
            let samples = self.audioCapture.stop()
            #if DEBUG
            self.dumpCaptureForVerification(samples)
            #endif
        }
    }

    func hotkeyCancelled() {
        logger.info("[hotkey] CANCELLED (디바운스)")
        sessionGeneration += 1
        Task { @MainActor in
            // 오조작 — 버퍼 폐기 (TDD §2 취소 전이).
            self.audioCapture.stop()
        }
    }

    #if DEBUG
    /// 태스크 1.3 검증용 wav 덤프 (PLAN 1.3 완료 기준). 코디네이터 도입(1.8) 시 제거.
    private func dumpCaptureForVerification(_ samples: [Float]) {
        guard !samples.isEmpty else {
            logger.warning("[debug] 캡처 버퍼 비어 있음 — 덤프 생략")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipcoding-capture.wav")
        do {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioCapture.sampleRate,
                channels: 1,
                interleaved: false
            ), let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ), let channelData = buffer.floatChannelData else { return }

            samples.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress {
                    channelData[0].update(from: baseAddress, count: samples.count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)

            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioCapture.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            logger.info("[debug] wav 덤프: \(url.path, privacy: .public)")
        } catch {
            logger.error("[debug] wav 덤프 실패: \(String(describing: error), privacy: .public)")
        }
    }
    #endif
}

// MARK: - AudioCaptureDelegate (태스크 1.8에서 SessionCoordinator로 이관)

extension IpCodingApp: AudioCaptureDelegate {
    func audioCaptureDidReachMaxDuration() {
        logger.warning("[audio] 60초 상한 — 강제 마감")
        let samples = audioCapture.stop()
        #if DEBUG
        dumpCaptureForVerification(samples)
        #endif
    }
}
