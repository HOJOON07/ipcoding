---
name: bench-protocol
description: Phase 0 벤치마크의 측정 방법과 판정 규칙. CER, 용어 적중률, RTF, TTFT 계산, Ollama API 측정, 모델 비교 판정 작업 시 참조. 정본은 docs/BENCH.md — 이 스킬은 실행 노하우.
---

# 벤치마크 프로토콜 (입코딩 Phase 0)

## 지표 계산
- **CER**: `pip install jiwer` → `jiwer.cer(정답, 가설)`. 계산 전 정규화: 연속 공백 1개로, 앞뒤 공백 제거, 문장부호는 유지(프롬프트 품질에 영향 있으므로). 정규화 규칙을 바꾸면 모든 후보에 동일 적용.
- **용어 적중률**: sentences.json의 terms 배열 기준, 전사문에 정확 문자열 포함 여부(대소문자 구분 — useState≠usestate). 문장별 적중수/전체 → 전체 평균.
- **RTF**: 처리시간/오디오길이. 반복 10회 중앙값, 첫 회(워밍업)는 버림. `time.perf_counter()` 사용.
- **TTFT/총시간**: Ollama `/api/generate` 또는 `/api/chat`을 stream=true로 호출, 요청 직전 t0 → 첫 청크 수신 t1(TTFT) → done 청크 t2(총시간). 각 모델 로드 직후 1회 더미 호출로 워밍업 후 측정.

## Ollama 실행 규칙
- 모델 간 공정 비교: 같은 프롬프트 파일(prompts/refine_v0.txt), temperature 0.2, 씽킹 모드 off 통일. Qwen3.5 Small은 기본 off — 다른 모델도 off 확인.
- 측정 중 다른 모델 언로드: `ollama stop <model>` 또는 keep_alive=0 — 메모리 경합이 속도 지표를 오염시킨다.
- 각 모델의 실제 로드 메모리는 `ollama ps`로 기록.

## 판정 규칙 (BENCH.md 요약 — 임의 변경 금지)
- STT: 용어 적중률 → CER → RTF 순. 사전 치환 후 적중률 ≥90%가 Phase 0 완료 기준.
- LLM: ① 의도 보존 실패 0건이 필수 관문(요구사항 추가/누락/입력에 응답 = 실패) ② 교정 성공률 ③ 정돈 품질(유형 E 체크리스트) ④ TTFT ≤2s ⑤ 메모리.
- 4B vs 9B 동급이면 4B (메모리·8GB 맥 여지). 근소 차이(CER 1%p 이내 등)는 동급 처리.

## 흔한 오염원
- 워밍업 미제거 → 첫 측정이 2~10배 느리게 나옴.
- 백그라운드 부하(브라우저, 다른 모델 상주) → 측정 전 `ollama ps` 확인.
- 유형 E(두서없는 발화)를 CER로 채점하는 실수 — E는 의도 체크리스트로만 채점.
- LLM이 마크다운/따옴표를 붙인 출력 → 채점 전 스트립하되, "규칙 위반 발생"으로 별도 카운트(프롬프트 개선 재료).
