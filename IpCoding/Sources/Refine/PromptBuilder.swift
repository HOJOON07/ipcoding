import Foundation
import os

enum PromptBuilderError: Error {
    /// 번들에 refine_v2.txt 리소스가 없음 — 빌드 구성 오류.
    case templateMissing
    /// 템플릿의 {raw_text} 플레이스홀더가 정확히 1개가 아님 — 프롬프트 파일 손상.
    case rawTextPlaceholderInvalid
}

/// ChatML로 감싼 교정 프롬프트를 {raw_text} 기준으로 가른 두 조각 (TDD §3.5).
/// prefix는 세션 간 불변이라 RefineEngine이 KV에 상주시키는 프롬프트 캐시 대상 (§3.4).
struct RefinePromptParts: Equatable, Sendable {
    /// {raw_text} 앞: ChatML user 열기 + 시스템 프롬프트 앞부분 (고정 프리픽스).
    let prefix: String
    /// {raw_text} 뒤: 프롬프트 뒷부분 + ChatML 닫기 + assistant 씽킹 시드 (고정 접미부).
    let suffix: String
}

/// 프롬프트 조립 전담 (TDD §3.5, 태스크 2.3). 두 가지를 만든다:
/// ① 교정 프롬프트 — 번들의 시스템 프롬프트 v2에 {dictionary_pairs}="(없음)" 고정(§3.6,
///    Phase 0에서 LLM 프롬프트 사전 주입의 역적용 사고 검증) 후 ChatML 조립.
/// ② Whisper initial_prompt — 사용자 사전의 표준 표기(written)를 콤마로 결합(§3.3,
///    Phase 0 실측 적중률 +26.9%p). 사전이 도그푸딩으로 자라면 힌트도 함께 자란다.
@MainActor
final class PromptBuilder {

    private let dictionary: UserDictionary
    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "prompt")

    init(dictionary: UserDictionary) {
        self.dictionary = dictionary
    }

    // MARK: - ① 교정 프롬프트 (RefineEngine용)

    /// 번들의 v2 템플릿을 로드해 ChatML 프리픽스/접미부로 조립한다. 앱 시작 시 1회.
    func refinePromptParts() throws -> RefinePromptParts {
        guard let url = Bundle.main.url(forResource: "refine_v2", withExtension: "txt") else {
            logger.error("번들에 refine_v2.txt 없음")
            throw PromptBuilderError.templateMissing
        }
        let template = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "{dictionary_pairs}", with: "(없음)")

        // {raw_text}는 정확히 1개여야 한다 — 2개 이상이면 두 번째 이후가 침묵 탈락하므로 잠근다.
        let parts = template.components(separatedBy: "{raw_text}")
        guard parts.count == 2 else {
            throw PromptBuilderError.rawTextPlaceholderInvalid
        }
        let beforeRaw = parts[0]
        let afterRaw = parts[1]

        // ChatML 조립 + 씽킹 시드 (TDD §3.5, 2.1 스파이크 — auto 씽킹 누출 차단).
        return RefinePromptParts(
            prefix: "<|im_start|>user\n" + beforeRaw,
            suffix: afterRaw + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        )
    }

    // MARK: - ② Whisper initial_prompt (TranscribeEngine용)

    /// 사전의 표준 표기를 콤마로 결합. 사전이 비면 nil (힌트 없이 전사 — Phase 0 no_prompt 조건).
    func whisperInitialPrompt() -> String? {
        let terms = dictionary.entries.map(\.written)
        guard !terms.isEmpty else { return nil }
        let unique = NSOrderedSet(array: terms).array as? [String] ?? terms
        return unique.joined(separator: ", ")
    }
}
