# 입코딩 — Phase 0 벤치마크 명세 v0.1

> 목적: STT 엔진·모델과 교정용 LLM을 실측 데이터로 확정한다. PRD §10의 4·5·6번 미결정 사항을 해소한다.
> 환경: 본인의 Apple Silicon 맥 + 실사용 마이크(에어팟). Python 3.11+, Ollama, whisper.cpp.

## 1. 리포 구조

```
ipcoding-bench/
├── sentences.json        # 대본 30문장 (id, 정답 텍스트, 핵심 용어 목록, 유형)
├── audio/                # s01.wav ~ s30.wav (16kHz mono 권장, 변환 스크립트 포함)
├── record.py             # 대본을 한 문장씩 띄우고 녹음을 보조
├── bench_stt.py          # 실험 A: 후보 STT × 30문장 → results_stt.csv
├── bench_llm.py          # 실험 B: Ollama 후보 × (실험 A의 실제 오인식 전사) → results_llm.csv
├── prompts/
│   └── refine_v0.txt     # 시스템 프롬프트 (기술설계서 §3.5)
├── dictionary_seed.json  # 실험 A 산출물: 오인식 → 표기 치환 쌍
├── results_stt.csv
├── results_llm.csv
└── REPORT.md             # 최종 판정
```

## 2. 대본 30문장 (초안 — 본인 말버릇에 맞게 수정 후 확정)

유형 A: 기술용어 밀집 한영 혼용 (10)
1. 이 컴포넌트 useState 말고 useReducer로 리팩토링해줘
2. useEffect에 cleanup 함수 리턴하는 거 빠졌으니까 추가해줘
3. async await로 바꾸고 try catch로 에러 핸들링 해줘
4. 이 함수 TypeScript 제네릭으로 타입 잡아줘
5. React Query로 캐싱하게 바꾸고 staleTime 5분으로 설정해줘
6. git rebase로 커밋 세 개를 하나로 squash 해줘
7. Dockerfile에서 멀티스테이지 빌드로 이미지 사이즈 줄여줘
8. 이 API 엔드포인트에 rate limiting 미들웨어 붙여줘
9. Tailwind로 다크모드 대응하는 클래스 추가해줘
10. cmux에서 새 pane 열어서 테스트 워처 돌려줘

유형 B: 일반 한국어 지시 (6)
11. 방금 수정한 부분 다시 원래대로 되돌려줘
12. 이 파일에서 중복되는 로직 찾아서 함수로 뽑아줘
13. 변수 이름들 좀 더 명확하게 바꿔줘
14. 주석 달아줘 근데 너무 길게는 말고
15. 이거 왜 안 되는지 원인부터 찾아줘
16. 성능 문제 있는 부분 프로파일링해서 알려줘

유형 C: 영어 비중 높음 (4)
17. npm run dev 하고 에러 로그 보여줘
18. pytest로 유닛 테스트 돌리고 실패한 것만 정리해줘
19. main 브랜치에 rebase 하고 force push 해줘
20. environment variable에서 API key 읽어오게 바꿔줘

유형 D: 짧은 커맨드형 (4)
21. 커밋해줘
22. 테스트 돌려
23. 빌드 다시 해봐
24. 린트 에러 고쳐줘

유형 E: 길고 두서없는 발화 (6) — 정돈 기능 평가용, 대본을 "의도"만 정하고 즉흥으로 말해서 녹음
25. (의도: 로그인 세션 만료 리다이렉트 수정 + 테스트 작성)
26. (의도: 검색 기능이 느린데 디바운스 추가하고 API 호출 줄이기)
27. (의도: 결제 모듈 에러 핸들링 보강, 실패 시 재시도 3번)
28. (의도: 다크모드 토글이 새로고침하면 풀리는 버그, localStorage에 저장)
29. (의도: PR 올리기 전에 콘솔 로그 지우고 커밋 메시지 정리)
30. (의도: 이 컴포넌트 모바일에서 깨지는 거 반응형으로 수정)

유형 E의 "정답"은 축어 텍스트가 아니라 **의도 체크리스트**다 (예: 25번 = [세션 만료 언급, 리다이렉트 수정, 테스트 작성] 3항목). 정돈 결과가 항목을 모두 담고 새 항목을 추가하지 않으면 통과.

## 3. 실험 A — STT

- 후보: `whisper.cpp large-v3-turbo (q5)`, `whisper.cpp medium (q5)`, 기준선 `Apple SFSpeechRecognizer`(macOS 26이면 SpeechTranscriber도 참고).
- 조건: language=ko 고정, initial_prompt 유무 2조건으로 turbo만 추가 측정 (프롬프트 효과 정량화).
- 지표:
  - **CER** (jiwer, 공백 정규화 후) — 유형 A–D만 (E는 축어 정답 없음)
  - **용어 적중률** = 문장별 핵심 용어 중 정확 표기 개수 / 전체 (sentences.json의 terms 필드 기준)
  - **RTF** = 처리 시간 / 오디오 길이 (10회 반복 중앙값, 워밍업 1회 제외)
- 판정: 용어 적중률(사전 치환 전 기준) 우선 → CER → RTF. turbo와 medium이 비등하면 turbo(여유 마진).
- 부산물: 오인식 로그에서 반복 패턴을 뽑아 `dictionary_seed.json` 작성. 사전 치환 적용 후 적중률 재계산 → 이 값이 ≥90%이면 Phase 0 완료 기준 충족.

## 4. 실험 B — LLM 교정·정돈

- 후보: `qwen3.5:4b`, `qwen3.5:9b`, `kanana 1.5 8b`(gguf 직접 또는 Ollama 등록), `gemma4:e4b`, 참고 `EXAONE 7.8B`(출하 불가, 상한선 측정).
- 입력: 실험 A에서 **선정된 STT가 실제로 출력한 전사문 30개** (사전 치환 적용 후 상태 — 실제 파이프라인과 동일 지점).
- 프롬프트: `prompts/refine_v0.txt` 고정. 모델별 씽킹 모드는 **꺼짐**으로 통일 (지연 폭주 방지 — Qwen3.5 Small은 기본 꺼짐).
- 지표:
  - **교정 성공률**: 잔존 오인식(사전이 못 잡은 것)을 고쳤는가 — 문장별 O/X
  - **의도 보존**: 요구사항 추가/누락/응답사고(입력에 답해버림) 발생 여부 — 발생 즉시 해당 모델 감점 기록
  - **정돈 품질**: 유형 E 6문장, 의도 체크리스트 충족 + 자연스러움 1–5점
  - **TTFT / 총 생성시간**: Ollama API 스트리밍 타임스탬프로 측정
- 판정 우선순위: 의도 보존(실패 0건 필수) → 교정 성공률 → 정돈 품질 → TTFT ≤ 2s → 메모리.
- 4B와 9B가 품질 동급이면 4B 채택 (메모리·속도·8GB 맥 여지). 9B만 의도 보존을 만족하면 9B 채택 + PRD §10-6을 "8GB 미지원"으로 확정.

## 5. 리포트 양식 (REPORT.md)

1. 실행 환경 (맥 모델, 램, macOS, 마이크)
2. 실험 A 결과표 + 선정 STT와 근거
3. 시드 사전 v0 (개수, 대표 예시)
4. 실험 B 결과표 + 선정 LLM과 근거 + 프롬프트 개선 이력(v0→v1 변경점과 이유)
5. 확정 스택 요약 + 예상 파이프라인 지연 (T_raw / T_first_token / T_ready 추정)
6. PRD 반영 사항 (§10-4, 5, 6 결론)

## 6. 실행 순서 체크리스트

- [ ] 0.1 sentences.json 작성 (대본 §2를 본인 어휘로 수정)
- [ ] 0.2 record.py로 30문장 녹음 (에어팟, 조용한 방 + 카페 소음 2조건이면 더 좋음)
- [ ] 0.3 bench_stt.py 실행 → results_stt.csv
- [ ] 0.4 dictionary_seed.json 작성
- [ ] 0.5 ollama pull 후보 4종 → bench_llm.py → results_llm.csv
- [ ] 0.6 실패 사례 보고 프롬프트 v1 반영, 재실행
- [ ] 0.7 REPORT.md 작성, PRD §10 갱신
