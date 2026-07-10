# 입코딩 — 작업 기록 (WORKLOG)

> 페이즈 진행 중 "무엇을, 왜 만들었고, 결과가 어땠는지"를 남기는 일지.
> 정식 산출물과 구분된다: Phase 0의 공식 판정은 `ipcoding-bench/REPORT.md`(태스크 0.7)에, 명세는 `docs/BENCH.md`에 있다.

---

## 2026-07-10 — Phase 2 착수: 2.1 LlamaBridge 스파이크

### 무엇을 했나
Qwen3.5-9B(q4)를 llama.cpp로 통합하기 전, CLI로 로드·품질·속도·씽킹 처리를 검증. Phase 2 최대 리스크(Qwen3.5 mmproj)를 해소하고 통합 경로를 확정.

### 발견 (리스크 지형 반전)
- **mmproj는 blocker 아님** — Qwen3.5는 텍스트/비전 gguf가 별도 배포. 텍스트 gguf만 받으면 mmproj 없이 순수 텍스트 로드·생성. 차순위 모델 전환 불필요 (PRD §10-4 리스크 해소).
- **Ollama 블롭은 mainline llama.cpp와 비호환** — `qwen35.rope.dimension_sections` 스키마 불일치(Ollama 포크 3 vs mainline 4)로 로드 실패. → unsloth/Qwen3.5-9B-GGUF Q4_K_M(5.3GB, Phase 0과 동일 양자화)을 `~/Library/Application Support/IpCoding/models/`에 다운로드해 사용. mainline llama.cpp(brew b9910)에서 로드 성공.
- **진짜 리스크는 ggml 심볼 충돌** — whisper.cpp·llama.cpp를 각자 ggml 정적 포함 xcframework로 함께 링크하면 중복 심볼 수백 개(다수 이슈 실재). 2.2 통합 시 "동일 ggml 공유 빌드" 방식 필요.

### 스파이크 결과 (bench-analyst)
- **씽킹 모드 끄기 확정**: assistant 프리픽스에 빈 `<think>\n\n</think>` 시드 → 즉시 답 생성 (RefineEngine의 ChatML 수동 조립에 적합, jinja 불필요). 방어용 `</think>` 파싱 제거 유지.
- **품질**: 전사문 5개 의도 보존 5/5, 무번역, 오인식 교정 작동. **Ollama 9b+v2 레퍼런스보다 깨끗** (구분자 에코 없음, s21 "커밋해줘" 무번역 유지).
- **속도**: TTFT ~1.3s (Ollama 1.58s보다 약간 빠름), 생성 ~37 tok/s, temp 0.2 안정.
- **프롬프트 캐시 발견(성능 지렛대)**: v2 프롬프트 ~530토큰이 TTFT의 92%인데 매번 동일한 고정 프리픽스. 프롬프트 캐시로 프리필 1326ms→0ms, 총 1506ms→211ms. 고정 프리픽스 KV를 로드 시 1회 디코드·상주시키고 raw_text 델타(5~30토큰)만 처리 → Phase 0가 걱정한 L2 지연 예산 여유 확보.

### 다음
- TDD §3.4에 스파이크 발견 반영 (프롬프트 캐시, 씽킹 시드, 정지 토큰) — spec-guardian 판정 후 승인
- 2.2 RefineEngine 구현 (actor 격리 whisper 패턴 재사용) + ggml 공유 xcframework 통합

---

## 2026-07-07 ~ 07-08 — Phase 0 착수: 환경 구축 · 벤치 하네스 · 실험 A

### 1. 무엇을 했나

#### 환경 구축
| 항목 | 내용 |
|---|---|
| Ollama 0.31.1 | 공식 install.sh로 설치 (`/Applications/Ollama.app` + CLI 심링크), 서버 구동 확인 |
| whisper.cpp | Homebrew `whisper-cpp` → `whisper-cli` |
| Python 3.11 venv | `ipcoding-bench/.venv` — jiwer(CER 계산), sounddevice/soundfile(녹음), requests(Ollama API) |
| whisper 모델 | `ggml-large-v3-turbo-q5_0.bin`(547MB), `ggml-medium-q5_0.bin`(514MB) → `ipcoding-bench/models/` |

#### 벤치 하네스 (`ipcoding-bench/`, 스크립트 570줄)
| 파일 | 기능 | 의도 |
|---|---|---|
| `sentences.json` | 대본 30문장 정답지: 정답 텍스트 + 채점용 핵심 용어(`terms`). 유형 E(25~30)는 축어 정답 대신 의도 체크리스트 | 유형별(기술용어 밀집/일반 지시/영어 비중/짧은 커맨드/두서없는 발화) 약점을 분리 측정 |
| `record.py` | 문장별 녹음 보조 (16kHz mono, 재녹음·재생 지원) | 실사용 조건(에어팟) 그대로의 테스트 데이터 확보 |
| `bench_stt.py` | 실험 A: whisper 후보 × 30문장 → CER·용어 적중률·RTF → `results_stt.csv` | STT 모델·initial_prompt 효과를 실측으로 판정 |
| `apply_dict.py` | 시드 사전 치환 후 지표 재계산 → `results_stt_postdict.csv` | Phase 0 완료 기준(치환 후 적중률 ≥90%) 판정 |
| `bench_llm.py` | 실험 B: Ollama 후보 × 실전사문 → TTFT·총시간 자동 측정 + 수동 채점 컬럼 → `results_llm.csv` | 교정 LLM 선정 (아직 미실행) |
| `prompts/refine_v0.txt` | 교정 LLM 시스템 프롬프트 v0 (TDD §3.5) | 실험 B 고정 조건. 실패 사례 수집 후 v1 개선 예정 |

측정 규칙(정규화, 워밍업 제외, 씽킹 모드 off 등)은 `docs/BENCH.md`와 `bench-protocol` 스킬을 따랐다.

### 2. 실험 A 결과 (태스크 0.3 · 0.4 완료)

**선정: `whisper large-v3-turbo (q5)` + initial_prompt(용어 힌트). Phase 0 STT 기준 충족.**

| 모델 / 조건 | 평균 CER (A~D) | 용어 적중률 | 사전 치환 후 적중률 |
|---|---|---|---|
| **turbo + 힌트** | **0.179 → 0.089(치환 후)** | **61.5%** | **100%** ✅ (기준 ≥90%) |
| turbo (힌트 없음) | 0.228 | 34.6% | 50% |
| medium (힌트 없음) | 0.267 | 7.7% | — |

판정 근거 (BENCH.md §3 우선순위: 용어 → CER → RTF):
- 용어 적중률에서 압도적 1위라 부차 기준 불필요. medium은 영어 용어를 거의 전부 한글 음차로 출력(useState→"유즈 스테이트")해 탈락.
- **initial_prompt 효과 정량화: 적중률 +26.9%p, CER −4.9%p.** 같은 사전을 힌트 없는 전사에 적용하면 50%에 그침 → **initial_prompt는 파이프라인의 전제 조건**.
- RTF는 3조건 동률(0.128)로 변별력 없음 — CLI 호출마다 모델 로드가 포함돼 짧은 오디오에선 로드 시간이 지배하는 측정 한계. 앱은 모델 상주(TDD §3.3)라 실제 지연은 이보다 낮다. 10초 발화 기준 전사 ~1.3초 → Phase 1 목표(T_inject p90 ≤1.5s)와 정합.

#### 시드 사전 v0 (`dictionary_seed.json`, 17항목)
오류가 두 부류로 갈렸다:
1. **대문자화 오류 (6건)** — initial_prompt의 부작용. 문장 첫 용어를 대문자로 출력 (Cleanup→cleanup, Async→async, StaleTime→staleTime 등)
2. **한글 음차/오인식** — 스쿼시→squash, 파이 테스트→pytest, Docker 파일→Dockerfile, 페인→pane, 거미 태조→커밋해줘 등

### 3. 발견 사항 · 보완 중인 것

- **짧은 커맨드형 발화 취약**: "커밋해줘"(s21)가 두 조건 모두 "거미 태조"로 전사. 문맥이 없는 초단문의 구조적 약점 — 사전으로 커버했지만 실사용에서 재발 유형이 다를 수 있음. REPORT.md에 리스크로 기록 예정.
- **사전 치환 오염 위험 2건**: "페인"→pane("페인트" 오염), "제시도"→재시도(일반 단어 오염). 사용자 사전 확정 시 검토 필요 — 긴 spoken 우선 정렬(TDD §3.6)로 일부 완화되나 근본 해결은 아님.
- **1회성 오인식 7건은 사전에서 제외** (예: Type←타입 치환은 TypeScript 파괴 위험). 도그푸딩에서 반복되면 승격.
- **CER 절대값(치환 후 0.089)은 참고치**: 조사·띄어쓰기 오류가 대부분이라 AI 에이전트 이해에는 지장 적음. 제품 지표는 용어 적중률이 우선(BENCH.md §3 판정 순서의 근거).

### 4. 다음 단계 (태스크 0.5~0.7)

- [x] 후보 LLM 확보 — 사용자 결정으로 qwen3.5 4b/9b 2종으로 축소 (kanana는 Ollama 부재로 등록 비용 대비 제외, EXAONE은 출하 불가 참고용. BENCH.md §4 갱신)
- [x] 실험 B 실행 (아래 07-08 항목)
- [x] 품질 채점 + 프롬프트 v0→v1→v2 반복
- [x] REPORT.md + PRD §10-4·5·6 해소

---

## 2026-07-08 — 실험 B: 교정 LLM 선정 (프롬프트 v0→v1→v2 반복)

### 1. 무엇을 했나

qwen3.5 4b/9b × 실험 A 실전사문 30개(사전 치환 후 — 실제 파이프라인과 동일 지점)로 실험 B를 3사이클 수행. 관문 지표는 **의도 보존 실패 0건** (요구사항 추가/누락/입력에 응답 = 실패, 애매하면 실패로 보수 채점).

### 2. 사이클별 결과 — 의도 보존 실패 건수

| 프롬프트 | 4b | 9b | 주요 실패 유형과 조치 |
|---|---|---|---|
| v0 (TDD §3.5) | 11건 | 7건 | 4b: 한→영 전문 번역 5건("커밋해줘"→"Please commit the code."), 프롬프트 문구 누출. 9b: 도구 날조("테스트 돌려"→"pytest 실행") |
| v1 | 4건 | 6건 | 번역·누출 전멸(규칙5 강화+few-shot). 신규: 9b가 구분자 에코 12건, few-shot 예시 복사, **프롬프트 내 용어 사전을 역적용**(린트→링트) |
| **v2** | 2건 | **0건 ✅** | 군말 정의 축소, 구분자 에코 금지 명시, 예시 소재 교체, **프롬프트에서 사전 제거** → 9b 역적용·에코·날조 소멸 |

### 3. 판정 (사용자 확정, 2026-07-08)

**qwen3.5:9b (q4) + 프롬프트 v2 채택.** TTFT p50 1.58s(기준 ≤2s), 메모리 6.8GB → **PRD §10-6 "8GB 미지원" 확정**. 4b는 문두 맥락 삭제("useState 말고" 누락류) 2건이 3사이클에도 안 잡혀 모델 고유 성향으로 판단, 탈락.

### 4. 발견 사항 (설계 반영 필요)

- **프롬프트 내 용어 사전 주입은 역효과** — 입력에 이미 치환이 적용된 상태에선 정보 이득 없이 역적용 사고만 유발(v2 제거 실험으로 인과 검증). → TDD §3.6 수정안 제안.
- **의도 보존 ↔ 교정 적극성은 구조적 트레이드오프** — 관문을 조이자 교정 성공률이 22%까지 하락. 잔존 오인식은 프롬프트가 아니라 **사전 확장**으로 잡는 게 정직한 해법 (실험 A에서 사전 경로 유효성 입증됨).
- 구분자 에코 잔존 1건 → 앱 RefineEngine 출력 정제에 구분자 스트립 필요 (TDD §3.4 보강안).
- 채점 잔여 확인 사항: v0 경미 3건(s05/s15/s17)의 허용 여부 — 결론엔 영향 없음, REPORT 주석용.

### 5. 산출물

`results_llm.csv`(v0) / `results_llm_v1.csv` / `results_llm_v2.csv` (채점 초안 포함), `prompts/refine_v0~v2.txt`, `score_llm_*_draft.py`(채점 재현), `review_v2_9b.md`(사용자 검토용), `REPORT.md`(작성 중), PRD §10-4·5·6 갱신 완료.
