#!/usr/bin/env python3.11
"""score_llm_v2_draft.py — results_llm_v2.csv 수동 채점 컬럼 채우기 (초안, v2 프롬프트).

기준은 v0/v1 채점 스크립트와 동일 — BENCH.md §4, 보수적("애매하면 X").
교정 대상 9문장 동일: s04, s08, s17, s20, s23, s25, s26, s27, s29.
9b s08의 구분자 에코는 스트립 후 채점 + rule_violation에 delimiter_echo 기록.
"""

import csv
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent

SCORES = {
    ("qwen3.5:4b", "s01"): ("해당없음", "X", "", "'useState 말고' 누락 재발 — v2 규칙2·맥락 보존 예시로도 미해결"),
    ("qwen3.5:4b", "s02"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:4b", "s03"): ("해당없음", "O", "", "async await→async/await 표기 변형(경미)"),
    ("qwen3.5:4b", "s04"): ("X", "X", "", "'이 함수' 누락 재발 / Type→타입 교정, Generic 유지"),
    ("qwen3.5:4b", "s05"): ("해당없음", "O", "", "'캐싱을 변경' 어색(경미), 존댓말화"),
    ("qwen3.5:4b", "s06"): ("해당없음", "O", "", "git→Git 대문자화 훼손(경미)"),
    ("qwen3.5:4b", "s07"): ("해당없음", "O", "", ""),
    ("qwen3.5:4b", "s08"): ("X", "O", "", "mid layer→'미들 레이어' 음차 — 미들웨어/middleware 복원 실패(v1 대비 후퇴)"),
    ("qwen3.5:4b", "s09"): ("해당없음", "O", "", ""),
    ("qwen3.5:4b", "s10"): ("해당없음", "O", "", "용어 훼손: pane→Pane, 워처→Watcher 대문자·영어화 / 존댓말화"),
    ("qwen3.5:4b", "s11"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:4b", "s12"): ("해당없음", "O", "", "뽑아줘→추출해 달라 바꿔쓰기(경미)"),
    ("qwen3.5:4b", "s13"): ("해당없음", "O", "", "원문 유지"),
    ("qwen3.5:4b", "s14"): ("해당없음", "O", "", "v1 '말하지 마' 왜곡 해소 — 주석 길이 제한 의미 정확, 명령문투(경미)"),
    ("qwen3.5:4b", "s15"): ("해당없음", "O", "", "완전 원문 통과 ✓ (v1 문두 누락 해소)"),
    ("qwen3.5:4b", "s16"): ("해당없음", "O", "", ""),
    ("qwen3.5:4b", "s17"): ("X", "O", "", "error log 미교정(원문 유지)"),
    ("qwen3.5:4b", "s18"): ("해당없음", "O", "", ""),
    ("qwen3.5:4b", "s19"): ("해당없음", "O", "", "rebase→'재베이스', force push→'포스 푸시' 한글 음차화(규칙5 역방향·용어 훼손 심각)"),
    ("qwen3.5:4b", "s20"): ("X", "O", "", "한국어화 재발(환경 변수·API 키) + '바꾸줘' 오타 도입, 비문 잔존"),
    ("qwen3.5:4b", "s21"): ("해당없음", "O", "", "무변경 통과 ✓"),
    ("qwen3.5:4b", "s22"): ("해당없음", "O", "", "돌려→'돌리기' 명사형 변형(경미)"),
    ("qwen3.5:4b", "s23"): ("X", "O", "", "Build 미교정(v1 '빌드' 교정에서 후퇴) + 해봐→실행해달라 바꿔쓰기"),
    ("qwen3.5:4b", "s24"): ("해당없음", "O", "", "원문 유지 ✓"),
    ("qwen3.5:4b", "s25"): ("X", "O", "2/3·자연4", "만료→완료 잔존, 리다이렉트·테스트 유지"),
    ("qwen3.5:4b", "s26"): ("O", "O", "3/3·자연4", "중복 디바운싱 정리 ✓, 호출 줄이기 보존"),
    ("qwen3.5:4b", "s27"): ("O", "O", "2/2·자연4", "리페트링→리팩토링 ✓, '최대 3회까지 재시도' 등가 표현"),
    ("qwen3.5:4b", "s28"): ("해당없음", "O", "2/2·자연4", ""),
    ("qwen3.5:4b", "s29"): ("X", "O", "2/3·자연3", "'콘솔로' 원문 유지(교정 포기 — 보수 원칙 준수, 비문 잔존)"),
    ("qwen3.5:4b", "s30"): ("해당없음", "O", "2/2·자연4", ""),

    ("qwen3.5:9b", "s01"): ("해당없음", "O", "", "완전 보존 ✓ (구분자 에코 해소)"),
    ("qwen3.5:9b", "s02"): ("해당없음", "O", "", ""),
    ("qwen3.5:9b", "s03"): ("해당없음", "O", "", "try catch→try-catch 하이픈 변형(경미)"),
    ("qwen3.5:9b", "s04"): ("X", "O", "", "Generic·Type 미교정(원문 통과), '이 함수' 유지 ✓"),
    ("qwen3.5:9b", "s05"): ("해당없음", "O", "", ""),
    ("qwen3.5:9b", "s06"): ("해당없음", "O", "", "'커밋 세 개를 하나로' 복원 ✓ (v1 누락 해소)"),
    ("qwen3.5:9b", "s07"): ("해당없음", "O", "", ""),
    ("qwen3.5:9b", "s08"): ("O", "O", "", "구분자 에코 잔존(유일 1건) + mid layer→middleware 교정 ✓"),
    ("qwen3.5:9b", "s09"): ("해당없음", "O", "", ""),
    ("qwen3.5:9b", "s10"): ("해당없음", "O", "", "용어 훼손: 워처→'와치터' / pane 소문자 유지 ✓"),
    ("qwen3.5:9b", "s11"): ("해당없음", "O", "", ""),
    ("qwen3.5:9b", "s12"): ("해당없음", "O", "", "뽑아줘 보존 ✓"),
    ("qwen3.5:9b", "s13"): ("해당없음", "O", "", ""),
    ("qwen3.5:9b", "s14"): ("해당없음", "O", "", "완전 원문 통과 ✓"),
    ("qwen3.5:9b", "s15"): ("해당없음", "O", "", ""),
    ("qwen3.5:9b", "s16"): ("해당없음", "O", "", "조사 추가(경미)"),
    ("qwen3.5:9b", "s17"): ("X", "O", "", "error log 미교정 / '보여줘' 유지 ✓"),
    ("qwen3.5:9b", "s18"): ("해당없음", "O", "", ""),
    ("qwen3.5:9b", "s19"): ("해당없음", "O", "", "원문 유지 ✓"),
    ("qwen3.5:9b", "s20"): ("X", "O", "", "읽어오기 비문 미교정(원문 통과), v1과 달리 한국어화 없음 ✓"),
    ("qwen3.5:9b", "s21"): ("해당없음", "O", "", "커밋→'commit 해줘' 부분 영어화(규칙5 경미 — v1 완전 통과에서 후퇴)"),
    ("qwen3.5:9b", "s22"): ("해당없음", "O", "", "존댓말화(경미), v1 예시 누출 해소 ✓"),
    ("qwen3.5:9b", "s23"): ("X", "O", "", "Build 미교정(v1 '빌드' 교정에서 후퇴 — 프롬프트 사전 제거 영향 추정)"),
    ("qwen3.5:9b", "s25"): ("X", "O", "2/3·자연3", "만료→완료 잔존, 원문 수준 통과"),
    ("qwen3.5:9b", "s24"): ("해당없음", "O", "", "완전 복원 ✓ (v1 '링트에러고쳐줘' 훼손 해소 — 사전 역적용 소멸)"),
    ("qwen3.5:9b", "s26"): ("X", "O", "3/3·자연2", "중복 '디바운싱 추가' 미정리(v0·v1 정리에서 후퇴 — 통과 과적용), 항목은 전부 보존"),
    ("qwen3.5:9b", "s27"): ("O", "O", "2/2·자연4", "재시도 3번 정상 ✓ (v1 '제시도' 역적용 해소)"),
    ("qwen3.5:9b", "s28"): ("해당없음", "O", "2/2·자연4", "localStorage 정상 ✓ (v1 날조 스왑 해소)"),
    ("qwen3.5:9b", "s29"): ("X", "O", "2/3·자연3", "'콘솔로' 원문 유지, v1 사전 문구 혼입 해소 ✓"),
    ("qwen3.5:9b", "s30"): ("해당없음", "O", "2/2·자연4", ""),
}

DELIM_ECHO = {("qwen3.5:9b", "s08")}


def main():
    path = BENCH_DIR / "results_llm_v2.csv"
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

    print("v2 채점 초안 기입 완료:", path)
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
