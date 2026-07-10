import Foundation
import IpCodingEngine
import os

enum RefineError: Error {
    case modelLoadFailed(path: String)
    case contextCreationFailed
    case notLoaded
    case tokenizationFailed
    case cancelled
}

/// llama.cpp 래퍼 (TDD §3.4). llama_context는 스레드 안전하지 않으므로 actor로 격리한다
/// (TranscribeEngine와 동일 패턴). 결과 String만 경계 밖으로 나간다.
///
/// 프롬프트 캐시 (2.1 스파이크): v2 시스템 프롬프트의 고정 프리픽스를 로드 시 1회 디코드해
/// KV에 상주시키고, 세션마다 {raw_text}+접미부 델타만 프리필한다. 프리필 병목(TTFT의 대부분)을
/// 세션당 5~30토큰으로 줄인다.
actor RefineEngine {

    // deinit(비격리) 정리 접근을 위해 unsafe. 해제 시점엔 다른 참조 없음.
    private nonisolated(unsafe) var model: OpaquePointer?
    private nonisolated(unsafe) var ctx: OpaquePointer?
    private var vocab: OpaquePointer?

    /// 고정 프리픽스(ChatML user 열기 + 프롬프트의 {raw_text} 앞부분)를 토큰화·디코드한 길이.
    private var prefixTokenCount: Int32 = 0
    /// KV 캐시의 현재 위치(다음 토큰이 놓일 pos). 명시적 위치 추적 — batch_get_one 자동 추적은
    /// seq_rm 후 어긋난다.
    private var nPast: Int32 = 0
    /// {raw_text} 뒤 고정 접미부 문자열 (>>> ... 출력: + assistant 씽킹 시드).
    private var suffixString = ""
    /// {raw_text} 앞 고정 프리픽스 문자열 (ChatML user 열기 포함).
    private var prefixString = ""

    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "refine")

    // TDD §3.4 확정 파라미터.
    private let nCtx: Int32 = 2048
    private let temperature: Float = 0.2
    private let topP: Float = 0.9
    private let repeatPenalty: Float = 1.05

    var isLoaded: Bool { ctx != nil }

    /// 모델 로드 + 컨텍스트 생성 + 백엔드 초기화. Metal offload.
    func load(modelPath: String) throws {
        unload()
        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999  // 전 레이어 Metal offload

        guard let loadedModel = llama_model_load_from_file(modelPath, mparams) else {
            logger.error("모델 로드 실패: \(modelPath, privacy: .public)")
            throw RefineError.modelLoadFailed(path: modelPath)
        }
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(nCtx)
        cparams.n_batch = UInt32(nCtx)
        cparams.n_seq_max = 2  // seq 0=프리픽스 캐시, seq 1=세션 작업 (프롬프트 캐시)
        guard let context = llama_init_from_model(loadedModel, cparams) else {
            llama_model_free(loadedModel)
            model = nil
            vocab = nil  // 해제된 모델 내부 포인터 — 댕글링 방지 (N1).
            throw RefineError.contextCreationFailed
        }
        ctx = context
        logger.info("llama 컨텍스트 로드 완료")
    }

    func unload() {
        if let ctx { llama_free(ctx); self.ctx = nil }
        if let model { llama_model_free(model); self.model = nil }
        vocab = nil
        prefixTokenCount = 0
    }

    /// PromptBuilder가 조립한 ChatML 프리픽스/접미부를 받아, 고정 프리픽스를 KV에 디코드해
    /// 상주시킨다 (프롬프트 캐시 준비, TDD §3.4 — 조립은 §3.5 PromptBuilder 소관). 로드 후 1회.
    func preparePrompt(parts: RefinePromptParts) throws {
        guard let ctx, let vocab else { throw RefineError.notLoaded }

        prefixString = parts.prefix
        suffixString = parts.suffix

        // 프리픽스를 seq 0에 디코드해 상주(캐시). 매 세션 seq 1로 복사해 재사용한다.
        let prefixTokens = tokenize(prefixString, vocab: vocab, addSpecial: true)
        guard !prefixTokens.isEmpty else { throw RefineError.tokenizationFailed }
        llama_memory_clear(llama_get_memory(ctx), true)
        guard decode(tokens: prefixTokens, startPos: 0, seqId: 0, needLastLogits: false) else {
            throw RefineError.tokenizationFailed
        }
        prefixTokenCount = Int32(prefixTokens.count)
        logger.info("프롬프트 프리픽스 캐시(seq 0) 준비 — \(prefixTokens.count, privacy: .public) 토큰")
    }

    /// 로드 직후 짧은 더미 생성 1회로 첫 발화 지연 제거 (TDD §3.3 워밍업 준용).
    func warmUp() {
        _ = try? refineSync(rawText: "안녕", maxTokensCap: 4, onToken: { _ in }, isCancelled: { false })
    }

    /// 교정 실행. 프리픽스는 캐시된 채 raw_text+접미부만 디코드하고, 토큰을 스트리밍한다.
    /// onToken은 생성 토큰 조각마다 호출(HUD 렌더용), isCancelled는 매 스텝 확인(Esc 취소).
    ///
    /// 타임아웃(TDD §3.4: 첫 토큰 3s / 전체 8s → llmTimeout)은 이 엔진이 정책을 갖지 않고,
    /// 코디네이터(2.4)가 데드라인을 담은 isCancelled를 주입해 중단시킨다 — 생성 중단 메커니즘은
    /// 여기 isCancelled 훅으로 이미 존재하고, 정책·llmTimeout 이벤트 발행은 상태 머신 소관.
    func refine(
        rawText: String,
        onToken: @Sendable @escaping (String) -> Void,
        isCancelled: @Sendable @escaping () -> Bool
    ) throws -> String {
        try refineSync(rawText: rawText, maxTokensCap: nil, onToken: onToken, isCancelled: isCancelled)
    }

    // MARK: - 생성 (프롬프트 캐시 재사용)

    /// maxTokensCap: 워밍업처럼 생성 상한을 강제 제한할 때 사용 (nil이면 입력 토큰 수 기반).
    private func refineSync(
        rawText: String,
        maxTokensCap: Int?,
        onToken: @Sendable (String) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws -> String {
        guard let ctx, let vocab else { throw RefineError.notLoaded }
        guard prefixTokenCount > 0 else { throw RefineError.notLoaded }

        // 프롬프트 캐시(2.1 스파이크, 2-시퀀스): seq 1을 비우고 seq 0의 프리픽스 KV를 복사해온다
        // — 프리픽스 재디코드 없이 재사용. 세션 작업은 seq 1에서만 하고 seq 0(프리픽스)은 보존.
        let mem = llama_get_memory(ctx)
        llama_memory_seq_rm(mem, 1, -1, -1)            // seq 1 전체 비움
        llama_memory_seq_cp(mem, 0, 1, -1, -1)         // seq 0 → seq 1 프리픽스 복사
        nPast = prefixTokenCount

        // 델타 = raw_text + 고정 접미부. 프리픽스 뒤(nPast)에 seq 1로 디코드, 마지막 토큰만 logits.
        let deltaTokens = tokenize(rawText + suffixString, vocab: vocab, addSpecial: false)
        guard !deltaTokens.isEmpty else { throw RefineError.tokenizationFailed }
        guard decode(tokens: deltaTokens, startPos: nPast, seqId: 1, needLastLogits: true) else {
            throw RefineError.tokenizationFailed
        }
        nPast += Int32(deltaTokens.count)

        // max_tokens = min(1024, 입력 토큰 수 × 2) (TDD §3.4). 문자 수 아닌 토큰 수 기반.
        let maxTokens = min(maxTokensCap ?? Int.max, min(1024, max(64, deltaTokens.count * 2)))

        // 샘플러 체인: 페널티 → top_p → temp → 분포 샘플 (TDD §3.4 확정값).
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, repeatPenalty, 0, 0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(0))

        // 한글은 한 글자가 여러 토큰에 걸칠 수 있어, 바이트를 누적해 완전한 UTF-8만 방출한다.
        var outputBytes: [UInt8] = []
        var pending: [UInt8] = []
        for _ in 0..<maxTokens {
            if isCancelled() { throw RefineError.cancelled }

            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }  // <|im_end|> 등에서 종료

            let bytes = tokenBytes(token, vocab: vocab)
            outputBytes.append(contentsOf: bytes)
            pending.append(contentsOf: bytes)
            // pending이 완전한 UTF-8이면 방출하고 비움 (미완성 멀티바이트면 다음 토큰까지 보류).
            if let piece = String(bytes: pending, encoding: .utf8), !piece.isEmpty {
                onToken(piece)
                pending.removeAll(keepingCapacity: true)
            }

            llama_sampler_accept(sampler, token)
            // 방금 토큰을 seq 1의 nPast에 디코드 (다음 스텝 logits).
            guard decode(tokens: [token], startPos: nPast, seqId: 1, needLastLogits: true) else { break }
            nPast += 1
        }

        let output = String(decoding: outputBytes, as: UTF8.self)
        return postProcess(output)
    }

    // MARK: - 출력 정제 (TDD §3.4)

    /// 지시문 프리픽스 혼입 감지용 (TDD §3.4 정제 ③). 이 문구로 시작하면 콜론 뒤만 취한다.
    private static let instructionPrefixes = ["출력:", "다듬은 결과:", "정리된 텍스트:", "결과:"]

    private func postProcess(_ raw: String) -> String {
        var text = raw
        // ④ 씽킹 잔재: <think>가 있으면 마지막 </think> 이후만.
        if let range = text.range(of: "</think>", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        // ② 구분자 스트립, ① 앞뒤 공백/따옴표.
        text = text.replacingOccurrences(of: "<<<", with: "")
            .replacingOccurrences(of: ">>>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // ③ 지시문 프리픽스 혼입 제거 (v2에선 미관찰이나 방어선, TDD §3.4 "후처리 필수").
        for prefix in Self.instructionPrefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    // MARK: - C interop 헬퍼

    private func tokenize(_ text: String, vocab: OpaquePointer, addSpecial: Bool) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        let capacity = utf8Count + 16
        var tokens = [llama_token](repeating: 0, count: Int(capacity))
        let n = text.withCString { cstr in
            llama_tokenize(vocab, cstr, utf8Count, &tokens, capacity, addSpecial, true)
        }
        guard n >= 0 else { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    private func tokenBytes(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 128)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {  // 버퍼 부족 — -n 크기로 재시도 (N3, 단일 토큰엔 사실상 미발생)
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard n > 0 else { return [] }
        return buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    /// tokens를 startPos부터 seqId 시퀀스에 명시적 위치로 디코드. 0=성공.
    private func decode(tokens: [llama_token], startPos: Int32, seqId: llama_seq_id, needLastLogits: Bool) -> Bool {
        guard let ctx, !tokens.isEmpty else { return false }
        let n = Int32(tokens.count)
        var batch = llama_batch_init(n, 0, 1)
        defer { llama_batch_free(batch) }
        batch.n_tokens = n
        for i in 0..<Int(n) {
            batch.token[i] = tokens[i]
            batch.pos[i] = startPos + Int32(i)
            batch.n_seq_id[i] = 1
            if let seqRow = batch.seq_id[i] { seqRow[0] = seqId }  // batch_init이 non-nil 보장, 강제언래핑 회피
            batch.logits[i] = (needLastLogits && i == Int(n) - 1) ? 1 : 0
        }
        return llama_decode(ctx, batch) == 0
    }

    deinit {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }
}
