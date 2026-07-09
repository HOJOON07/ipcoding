import Foundation
import os

/// 사전 항목 (TDD §3.6). spoken(오인식 형태) → written(표준 표기).
struct DictionaryEntry: Codable, Equatable {
    let spoken: String
    let written: String
}

/// 사용자 사전 (TDD §3.6). Phase 1은 UI 없이 dictionary.json 직접 편집.
/// 두 곳에 쓰인다: ① 전사 직후 원문 치환 ② Whisper initial_prompt 용어 주입.
/// (LLM 프롬프트 주입은 하지 않는다 — Phase 0 실험 B에서 역효과 검증, TDD §3.6.)
@MainActor
final class UserDictionary {

    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "dictionary")
    let fileURL: URL

    /// spoken 길이 내림차순으로 정렬해 보관 — 여러 항목이 같은 위치에서 겹칠 때 긴 항목이
    /// 먼저 매칭되도록 한다(예: "Docker 파일"이 "Docker"보다 우선).
    /// 한계: 이 정렬은 항목끼리의 우선순위만 정한다. 사전에 없는 임의 단어의 부분 매칭
    /// (spoken="페인"이 "페인트"에 걸리는 경우)은 막지 못한다 — 오염 위험 항목은 사전 선정에서
    /// 배제한다(Phase 0 REPORT: 페인/제시도).
    private(set) var entries: [DictionaryEntry] = []

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("dictionary.json")
    }

    /// dictionary.json 로드. 파일이 없으면 빈 사전(정상 — 사전 없이도 파이프라인 동작).
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            logger.info("사전 파일 없음 — 빈 사전으로 시작")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
            entries = decoded.sorted { $0.spoken.count > $1.spoken.count }
            logger.info("사전 로드 완료 — \(self.entries.count, privacy: .public)개 항목")
        } catch {
            // 손상된 사전이 파이프라인을 막지 않도록 빈 사전 폴백.
            entries = []
            logger.error("사전 로드 실패 — 빈 사전 폴백: \(String(describing: error), privacy: .public)")
        }
    }

    /// 전사 원문에 사전 치환 적용. 왼쪽부터 단일 패스로 스캔하며 각 위치에서 가장 긴 spoken을
    /// 치환한다. 치환된 written은 다시 스캔되지 않으므로 연쇄 치환(한 치환 결과가 다음 항목의
    /// spoken이 되어 이중 변환)이 원천 차단된다. 대소문자 구분 — 시드 사전이 whisper의 실제
    /// 출력 형태를 기록한 것이므로 정확 매칭한다("Usestate" 같은 케이싱 흔들림은 별도 항목 필요).
    func apply(to text: String) -> String {
        guard !entries.isEmpty else { return text }
        // entries는 이미 spoken 길이 내림차순이라 첫 매칭이 곧 최장 매칭.
        let prepared: [(spoken: [Character], written: String)] = entries.compactMap {
            $0.spoken.isEmpty ? nil : (Array($0.spoken), $0.written)
        }
        let chars = Array(text)
        var result = ""
        var i = 0
        while i < chars.count {
            var matched = false
            for entry in prepared {
                let n = entry.spoken.count
                if i + n <= chars.count, Array(chars[i..<(i + n)]) == entry.spoken {
                    result += entry.written
                    i += n
                    matched = true
                    break
                }
            }
            if !matched {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    /// Whisper initial_prompt에 넣을 용어 문자열 (표준 표기를 콤마로 결합).
    /// whisper가 이 표기대로 출력하도록 유도 (Phase 0: 적중률 +26.9%p). 비면 nil.
    ///
    /// Phase 1 임시 구현: 교정 사전의 written만 용어원으로 쓴다. 한계 — 교정 사전은 "틀리는
    /// 것"만 담아 "이미 잘 맞는 용어"(useState 등)를 미포함하므로 initial_prompt 커버리지가
    /// 좁다. Phase 2(태스크 2.3)에서 PromptBuilder 도입 시, 교정 사전과 별개의 기술용어 목록을
    /// 용어원으로 분리할지 재설계한다 (TDD §3.3·§3.5). 이관 전까지 UserDictionary가 임시 담당.
    func initialPromptTerms() -> String? {
        let terms = entries.map(\.written)
        let unique = NSOrderedSet(array: terms).array as? [String] ?? terms
        let joined = unique.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }
}
