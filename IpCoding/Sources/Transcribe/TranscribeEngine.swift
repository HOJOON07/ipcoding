import Foundation
import IpCodingEngine
import os

enum TranscribeError: Error {
    case modelLoadFailed(path: String)
    case notLoaded
    case emptyResult
    case transcriptionFailed(code: Int32)
}

/// whisper.cpp 래퍼 (TDD §3.3). whisper_context는 스레드 안전하지 않으므로 actor로 격리한다
/// (공식 예제 LibWhisper.swift 패턴). 추론은 이 actor에서만, 결과 String만 경계 밖으로 나간다.
actor TranscribeEngine {

    // deinit(비격리)의 최후 정리 접근을 위해 unsafe 표기. 해제 시점엔 다른 참조가 없어 안전.
    private nonisolated(unsafe) var ctx: OpaquePointer?
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "transcribe")

    var isLoaded: Bool { ctx != nil }

    /// 모델 로드 + 상주. Metal은 Apple Silicon에서 기본 활성 (xcframework에 셰이더 임베드).
    func load(modelPath: String) throws {
        unload()
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let context = whisper_init_from_file_with_params(modelPath, cparams) else {
            logger.error("모델 로드 실패: \(modelPath, privacy: .public)")
            throw TranscribeError.modelLoadFailed(path: modelPath)
        }
        ctx = context
        logger.info("whisper 컨텍스트 로드 완료")
    }

    func unload() {
        if let ctx {
            whisper_free(ctx)
            self.ctx = nil
        }
    }

    /// 로드 직후 0.5초 무음 1회 추론 — 첫 발화 지연 제거 (TDD §3.3 워밍업).
    func warmUp() {
        guard isLoaded else { return }
        let silence = [Float](repeating: 0, count: 8000)  // 0.5s @ 16kHz
        _ = try? transcribe(samples: silence, initialPrompt: nil)
        logger.info("워밍업 완료")
    }

    /// 16kHz mono Float32 입력을 전사. TDD 확정 파라미터: ko, greedy, no_timestamps.
    /// language/initial_prompt C 포인터는 whisper_full 호출이 끝날 때까지 유효해야 하므로
    /// withCString 스코프 안에서 호출한다.
    func transcribe(samples: [Float], initialPrompt: String?) throws -> String {
        guard let ctx else { throw TranscribeError.notLoaded }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.translate = false
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let code = withOptionalCString(initialPrompt) { promptPtr -> Int32 in
            "ko".withCString { langPtr -> Int32 in
                params.language = langPtr
                params.initial_prompt = promptPtr
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
        }
        guard code == 0 else { throw TranscribeError.transcriptionFailed(code: code) }

        let segments = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<segments {
            // 무음 환각 방어: whisper는 무음에서 빈 결과 대신 임의 단어를 지어낸다 (실기기에서
            // 2.3s 무음 → "스포츠" 관찰). 세그먼트별 no_speech 확률이 문턱을 넘으면 버린다 —
            // 전부 버려지면 emptyResult → sttFailed 경로 (TDD §3.2의 "무음 → sttFailed" 구현).
            let noSpeechProb = whisper_full_get_segment_no_speech_prob(ctx, i)
            guard noSpeechProb <= Self.noSpeechThreshold else {
                logger.debug("무음 세그먼트 스킵 (no_speech \(String(format: "%.2f", noSpeechProb), privacy: .public))")
                continue
            }
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cstr)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscribeError.emptyResult }
        return trimmed
    }

    /// 세그먼트를 무음으로 판정하는 no_speech 확률 문턱 (whisper 기본값 0.6과 동일).
    private static let noSpeechThreshold: Float = 0.6

    deinit {
        if let ctx { whisper_free(ctx) }
    }
}

/// nil이면 null 포인터, 아니면 withCString과 동일하게 수명이 보장된 C 문자열을 넘긴다.
private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    if let string {
        return string.withCString { body($0) }
    }
    return body(nil)
}
