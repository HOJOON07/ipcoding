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

    /// 파일에 기록된 순서 그대로의 사본 (편집 UI 표시용 — entries는 매칭용 정렬본이라
    /// 사용자가 파일에서 잡아둔 순서를 잃는다).
    private(set) var fileOrderedEntries: [DictionaryEntry] = []

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("dictionary.json")
    }

    /// dictionary.json 로드. 파일이 없으면 빈 사전(정상 — 사전 없이도 파이프라인 동작).
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            fileOrderedEntries = []
            logger.info("사전 파일 없음 — 빈 사전으로 시작")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
            fileOrderedEntries = decoded
            entries = decoded.sorted { $0.spoken.count > $1.spoken.count }
            logger.info("사전 로드 완료 — \(self.entries.count, privacy: .public)개 항목")
        } catch {
            // 손상된 사전이 파이프라인을 막지 않도록 빈 사전 폴백.
            entries = []
            fileOrderedEntries = []
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

    /// 편집 UI의 저장 경로 (태스크 2.8, TDD §3.6 — 변경 즉시 파일 저장 + 메모리 반영).
    /// 파일에는 주어진(편집 화면) 순서를 그대로 쓰고, 메모리는 최장매칭 규칙(길이 내림차순)으로
    /// 정렬해 반영한다. 쓰기 실패 시 메모리를 바꾸지 않는다 — 파일과 메모리의 불일치 방지.
    func update(_ newEntries: [DictionaryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(newEntries)
        try data.write(to: fileURL, options: .atomic)
        fileOrderedEntries = newEntries
        entries = newEntries.sorted { $0.spoken.count > $1.spoken.count }
        // 편집 UI가 키 입력 단위로 호출하므로 debug 레벨 (info면 로그 스팸).
        logger.debug("사전 갱신 — \(newEntries.count, privacy: .public)개 항목")
    }

    // initial_prompt 용어 생성은 PromptBuilder 소관 (TDD §3.3, 태스크 2.3에서 이관).
    // 이 타입은 치환 데이터(entries)와 적용(apply)만 담당한다.
}
