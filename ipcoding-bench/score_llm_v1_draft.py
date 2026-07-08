#!/usr/bin/env python3.11
"""score_llm_v1_draft.py — results_llm_v1.csv 수동 채점 컬럼 채우기 (초안, v1 프롬프트).

기준은 score_llm_draft.py(v0 채점)와 동일 — BENCH.md §4, 보수적("애매하면 X").
- 교정 대상 9문장 동일: s04, s08, s17, s20, s23, s25, s26, s27, s29.
  (s26의 교정 판정은 v0과 동일 기준: 중복 '디바운싱' 정리 여부.
   '검색기는→검색 기능' 복원은 두 버전 모두 불가로 보고 요구하지 않음.)
- 9b의 <<<...>>> 구분자 에코는 채점 전 스트립하되 rule_violation에
  delimiter_echo로 추가 기록 (bench-protocol 스킬: 래핑은 스트립 + 위반 카운트).
"""

import csv
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent

SCORES = {
    ("qwen3.5:4b", "s01"): ("해당없음", "X", "", "'useState 말고' 누락 — 전환 원점 정보 삭제"),
    ("qwen3.5:4b", "s02"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:4b", "s03"): ("해당없음", "O", "", "async/try catch 소문자 유지(v0 대문자화 해소)"),
    ("qwen3.5:4b", "s04"): ("X", "X", "", "Type→타입 교정 / Generic 미교정(규칙1 '확신 없으면 유지' 준수), '이 함수' 누락"),
    ("qwen3.5:4b", "s05"): ("해당없음", "O", "", "v0의 '(300초)' 추가 해소, '5 분 으로' 띄어쓰기 어색(경미)"),
    ("qwen3.5:4b", "s06"): ("해당없음", "O", "", ""),
    ("qwen3.5:4b", "s07"): ("해당없음", "O", "", ""),
    ("qwen3.5:4b", "s08"): ("O", "O", "", "mid layer→middleware 의미 복원, '이' 누락(경미)"),
    ("qwen3.5:4b", "s09"): ("해당없음", "O", "", "다크모드→'다크 모드' 띄어쓰기(경미)"),
    ("qwen3.5:4b", "s10"): ("해당없음", "O", "", "pane·테스트 워처 유지(v0 날조 해소) / 어투 존댓말화(돌리세요, 경미)"),
    ("qwen3.5:4b", "s11"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:4b", "s12"): ("해당없음", "O", "", "뽑아줘→추출해 줘 바꿔쓰기(규칙2 위반 경미)"),
    ("qwen3.5:4b", "s13"): ("해당없음", "O", "", "원문 유지(v0 '환경 변수' 날조 해소)"),
    ("qwen3.5:4b", "s14"): ("해당없음", "X", "", "'너무 길게는 말고'→'말하지 마' — 주석 길이 제한이 발화 금지로 왜곡"),
    ("qwen3.5:4b", "s15"): ("해당없음", "X", "", "'이거 왜 안 되는지' 누락 — 문제 서술 삭제(군말 제거 과적용)"),
    ("qwen3.5:4b", "s16"): ("해당없음", "O", "", "원문 유지(v0 영어 선언문 삽입 해소)"),
    ("qwen3.5:4b", "s17"): ("X", "O", "", "error log 미교정(원문 유지 — 소심화) / npm run dev·보여줘 보존(v0 누출 해소)"),
    ("qwen3.5:4b", "s18"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:4b", "s19"): ("해당없음", "O", "", "한국어 구조 유지(v0 전문 번역 해소)"),
    ("qwen3.5:4b", "s20"): ("X", "O", "", "environment variable→'환경 변수', API key→'API 키' 한국어화(규칙5 역방향) + '읽기 변경해줘' 비문 잔존"),
    ("qwen3.5:4b", "s21"): ("해당없음", "O", "", "무변경 통과 ✓(v0 영어 번역 해소, few-shot 효과)"),
    ("qwen3.5:4b", "s22"): ("해당없음", "O", "", "어투 존댓말화(돌리세요, 경미) — v0 영어 번역 해소"),
    ("qwen3.5:4b", "s23"): ("O", "O", "", "Build→빌드 교정 ✓(v0 영어 번역 해소)"),
    ("qwen3.5:4b", "s24"): ("해당없음", "O", "", "에러→오류 바꿔쓰기(경미) — v0 영어 번역 해소"),
    ("qwen3.5:4b", "s25"): ("X", "O", "2/3·자연4", "만료→'완료' 잔존(미교정), 리다이렉트·테스트 유지, v0 '파이테스트' 날조 해소"),
    ("qwen3.5:4b", "s26"): ("O", "O", "3/3·자연4", "중복 디바운싱 정리 ✓, 'API 호출이 줄어들도록' — v0 의미 반전 해소"),
    ("qwen3.5:4b", "s27"): ("O", "O", "2/2·자연4", "리페트링→리팩토링 ✓, 재시도 3번 유지"),
    ("qwen3.5:4b", "s28"): ("해당없음", "O", "2/2·자연4", "localStorage·버그 언급 모두 유지"),
    ("qwen3.5:4b", "s29"): ("X", "O", "2/3·자연4", "콘솔로→'콘솔을'(콘솔 로그 미복원 — 부분 교정), 커밋 메시지 유지"),
    ("qwen3.5:4b", "s30"): ("해당없음", "O", "2/2·자연4", ""),

    ("qwen3.5:9b", "s01"): ("해당없음", "O", "", "구분자 에코(스트립 후 원문 보존)"),
    ("qwen3.5:9b", "s02"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:9b", "s03"): ("해당없음", "O", "", "소문자 유지"),
    ("qwen3.5:9b", "s04"): ("X", "O", "", "구분자 에코 + Generic·Type 미교정(v0은 교정했음 — 무변경 통과 과적용)"),
    ("qwen3.5:9b", "s05"): ("해당없음", "O", "", "구분자 에코, v0 '(300초)' 추가 해소"),
    ("qwen3.5:9b", "s06"): ("해당없음", "X", "", "구분자 에코 + '커밋 세 개를 하나로'→'3 개를' — 대상·목표 누락"),
    ("qwen3.5:9b", "s07"): ("해당없음", "O", "", "구분자 에코"),
    ("qwen3.5:9b", "s08"): ("O", "O", "", "구분자 에코 + mid layer→middleware 교정, 붙여줘→추가해줘(경미)"),
    ("qwen3.5:9b", "s09"): ("해당없음", "O", "", "구분자 에코"),
    ("qwen3.5:9b", "s10"): ("해당없음", "O", "", "구분자 에코 + 테스트 워처→'test watcher' 영어화(규칙5 위반)"),
    ("qwen3.5:9b", "s11"): ("해당없음", "O", "", "구분자 에코"),
    ("qwen3.5:9b", "s12"): ("해당없음", "O", "", "원문 유지(뽑아줘 보존)"),
    ("qwen3.5:9b", "s13"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:9b", "s14"): ("해당없음", "O", "", "바꿔쓰기(경미) + 존댓말화"),
    ("qwen3.5:9b", "s15"): ("해당없음", "O", "", "완전 원문 통과 ✓(v0 논리 반전 해소)"),
    ("qwen3.5:9b", "s16"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:9b", "s17"): ("X", "O", "", "error log 미교정(원문 유지) / 보여줘 보존(v0 누락 해소), 백틱 해소"),
    ("qwen3.5:9b", "s18"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:9b", "s19"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:9b", "s20"): ("X", "O", "", "구분자 에코 + 읽어오기 비문 미교정(원문 통과) — v0 한국어화는 해소"),
    ("qwen3.5:9b", "s21"): ("해당없음", "O", "", "무변경 통과 ✓(v0 '커밋 메시지 작성' 왜곡 해소, few-shot 효과)"),
    ("qwen3.5:9b", "s22"): ("해당없음", "X", "", "few-shot 예시 출력('pytest로 유닛 테스트 좀 돌려줘')을 그대로 복사 — 예시 누출·날조"),
    ("qwen3.5:9b", "s23"): ("O", "O", "", "Build→빌드 교정 ✓"),
    ("qwen3.5:9b", "s24"): ("해당없음", "X", "", "'린트 에러 고쳐줘'→'링트에러고쳐줘' — 사전 쌍(링트→린트) 역적용 + 공백 파괴"),
    ("qwen3.5:9b", "s25"): ("X", "O", "2/3·자연3", "만료→완료 잔존(미교정), 원문 수준 통과 — v0 '성공적으로' 왜곡 해소"),
    ("qwen3.5:9b", "s26"): ("O", "O", "3/3·자연4", "중복 디바운싱 정리 ✓, API 호출 줄이기 보존"),
    ("qwen3.5:9b", "s27"): ("X", "X", "1/2·자연2", "구분자 에코 + 리페트링→'린팅' 오교정 + 재시도→'제시도' 사전 역적용"),
    ("qwen3.5:9b", "s28"): ("해당없음", "X", "1/2·자연3", "localStorage→'environment variable' 날조 스왑 — 저장 위치 요구 변조(심각)"),
    ("qwen3.5:9b", "s29"): ("X", "X", "2/3·자연2", "구분자 에코 + '코믹 메시지가 아닌' 사전 쌍 문구 혼입 + 콘솔로→'console.log 로 지워주고' 비문·영어화"),
    ("qwen3.5:9b", "s30"): ("해당없음", "O", "2/2·자연4", ""),
}

# 구분자 에코가 확인된 행 (rule_violation에 delimiter_echo 추가)
DELIM_ECHO = {
    ("qwen3.5:9b", s) for s in
    ["s01", "s04", "s05", "s06", "s07", "s08", "s09", "s10", "s11", "s20", "s27", "s29"]
}


def main():
    path = BENCH_DIR / "results_llm_v1.csv"
    rows = list(csv.DictReader(open(path, encoding="utf-8")))
    for r in rows:
        key = (r["model"], r["sentence_id"])
        if key in SCORES:
            r["교정성공"], r["의도보존"], r["정돈품질"], r["비고"] = SCORES[key]
        if key in DELIM_ECHO:
            r["rule_violation"] = (r["rule_violation"] + ";" if r["rule_violation"] else "") + "delimiter_echo"
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    print("v1 채점 초안 기입 완료:", path)
    import statistics
    for m in sorted({r["model"] for r in rows}):
        g = [r for r in rows if r["model"] == m]
        fails = [r["sentence_id"] for r in g if r["의도보존"] == "X"]
        corr = [r for r in g if r["교정성공"] in ("O", "X")]
        ok = sum(1 for r in corr if r["교정성공"] == "O")
        e_rows = [r for r in g if r["정돈품질"]]
        cl_hit = sum(int(r["정돈품질"].split("/")[0]) for r in e_rows)
        cl_tot = sum(int(r["정돈품질"].split("/")[1].split("·")[0]) for r in e_rows)
        nat = [int(r["정돈품질"].split("자연")[1]) for r in e_rows]
        ttft = statistics.median(float(r["ttft_s"]) for r in g if r["ttft_s"])
        total = statistics.median(float(r["total_s"]) for r in g if r["total_s"])
        print(f"\n{m}")
        print(f"  의도보존 실패: {len(fails)}건 {fails}")
        print(f"  교정 성공률: {ok}/{len(corr)} = {ok/len(corr):.0%}")
        print(f"  정돈(E): 체크리스트 {cl_hit}/{cl_tot} = {cl_hit/cl_tot:.0%}, 자연스러움 평균 {sum(nat)/len(nat):.1f}")
        print(f"  TTFT p50 {ttft:.2f}s / 총시간 p50 {total:.2f}s")


if __name__ == "__main__":
    main()
