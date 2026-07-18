# 입코딩 — 구현계획서 v0.1

> 상위 문서: PRD v0.2, 기술설계서 v0.1. 페이즈별 태스크는 AI 코딩 에이전트에게 그대로 지시 가능한 단위로 분해한다.
> 각 페이즈는 명시된 **완료 기준(Exit Criteria)**을 전부 만족해야 다음 페이즈로 넘어간다.

## 전체 타임라인

| 페이즈 | 목표 | 기간(감) | 산출물 |
|---|---|---|---|
| Phase 0 | 엔진·모델 데이터 기반 확정 | 1–2주 | 벤치마크 리포트, 확정 스택, 시드 사전 v0, 시스템 프롬프트 v2 |
| Phase 1 | L0 코어: 말하면 터미널에 원문이 꽂힌다 | 3–4주 | 자가 사용 가능한 .app |
| Phase 2 | 지능: 실시간 교정·정돈 HUD | 2–3주 | MVP 기능 완성 |
| Phase 3 | 제품화: 온보딩·배포 | 2주 | v1.0 공개 (dmg + Homebrew) |

병행 원칙: Phase 1 완료 시점부터 **입코딩으로 입코딩을 개발**하는 도그푸딩을 시작한다. 이후 모든 페이즈의 품질 판단은 자가 사용 데이터가 근거다.

---

## Phase 0 — 벤치마크 (상세는 벤치마크 명세 문서 참조)

| # | 태스크 | 산출물 |
|---|---|---|
| 0.1 | 테스트 대본 30문장 확정 + 정답 텍스트 작성 | `sentences.json` |
| 0.2 | 에어팟으로 30문장 녹음 (실사용 조건) | `audio/*.wav` |
| 0.3 | STT 벤치: whisper.cpp turbo/medium + Apple 기준선, CER·용어 적중률·RTF 측정 | `results_stt.csv` |
| 0.4 | 오인식 패턴 추출 → 시드 사전 v0 | `dictionary_seed.json` |
| 0.5 | LLM 벤치: Ollama로 후보 2종(qwen3.5 4b/9b — 벤치 명세 §4의 확정 근거 참조), 교정 성공률·의도 보존·정돈 품질·TTFT/총지연 | `results_llm.csv` |
| 0.6 | 시스템 프롬프트 개선 반복 (실패 사례 기반) | 프롬프트 v2 (v0→v1→v2 2사이클) |
| 0.7 | 결과 리포트 + 스택 확정 (PRD §10 4·5·6번 해소) | `REPORT.md` |

**완료 기준**: STT 후보의 기술용어 적중률 ≥ 90%(사전 치환 후 기준), 선정 LLM의 의도 보존 실패 0건/30문장, 예상 파이프라인 총지연이 PRD 예산 내. 미달 시 → 전략 수정 회의(모델 교체, 정돈 기능 범위 축소 등)를 거쳐 재실험.

## Phase 1 — L0 코어

목표: `⌘+Fn 홀드 → 말하기 → 릴리즈 → cmux에 원문 텍스트가 꽂힌다`. LLM 없음, HUD는 최소(녹음/처리 표시만).

| # | 태스크 | 의존 | 비고 |
|---|---|---|---|
| 1.1 | Xcode 프로젝트 스캐폴딩: 메뉴바 앱, 번들 ID, 프로젝트 구조(TDD §1) | — | LSUIElement=YES (Dock 숨김) |
| 1.2 | HotkeyManager: 이벤트 탭, ⌘+Fn down/up 감지, 재활성화 처리 | 1.1 | 콘솔 로그로 검증 |
| 1.3 | AudioCapture: 탭 설치, 16kHz mono 변환, 세션 버퍼, 60s 상한 | 1.1 | wav 덤프로 검증 |
| 1.4 | ModelManager 최소 구현: 수동 배치한 모델 파일 로드 경로 | 1.1 | 다운로드는 Phase 3 |
| 1.5 | TranscribeEngine: whisper.cpp SwiftPM 통합, 로드·워밍업·전사 | 1.4 | Phase 0 확정 파라미터 |
| 1.6 | UserDictionary: json 로드 + 치환 적용 (UI 없이 파일 직접 편집) | — | Phase 0 시드 사전 사용 |
| 1.7 | PasteboardInjector: 백업→set→⌘V→복원 | 1.1 | TDD §3.7 순서 엄수 |
| 1.8 | SessionCoordinator: idle→recording→transcribing→injecting 축소판 상태 머신 | 1.2–1.7 | refining 상태는 Phase 2. hotkeyCancelled(디바운스 취소) 전이 포함 (TDD §2). **완료 기준: IpCodingApp의 임시 wav 덤프(dumpCaptureForVerification)·전사 텍스트 덤프(dumpTranscriptForVerification)와 각 #if DEBUG 호출부 제거. 세션 이벤트(캡처·전사·주입)를 코디네이터가 직렬 소비 — 겹친 주입의 클립보드 레이스 방지(현 임시 배선은 sessionGeneration 가드로 대체 중)** |
| 1.9 | 최소 HUD: recording 파형 + processing 스피너 | 1.8 | non-activating 검증 필수 |
| 1.10 | 수동 테스트 매트릭스 1차 (터미널 4종 × 문장 3종) | 1.8 | TDD §7 |

**완료 기준**: cmux에서 10초 발화 기준 T_inject p90 ≤ 1.5s. 한글+영어 혼용 문장이 깨짐 없이 주입. 클립보드 복원 정상. 도그푸딩 시작 가능.

**리스크**: 이벤트 탭 권한/타임아웃 이슈(1.2에서 조기 검증), whisper.cpp Swift 통합 빌드 문제(1.5를 별도 스파이크로 먼저 수행 권장).

## Phase 2 — 지능 (교정·정돈 파이프라인)

목표: PRD §4의 HUD 5단계 흐름 완성.

| # | 태스크 | 의존 | 비고 |
|---|---|---|---|
| 2.1 | LlamaBridge 스파이크: 확정 모델 gguf 로드 + 스트리밍 생성 CLI 검증 | — | ✅ 완료. mmproj는 blocker 아님(텍스트 gguf 별도). gguf=unsloth/Qwen3.5-9B-GGUF Q4_K_M (Ollama 블롭은 mainline llama.cpp와 rope 스키마 비호환이라 배제). 리스크: whisper+llama 각자 ggml 정적 포함 xcframework 링크 시 중복 심볼 — 공유 ggml 단일 링크를 2.2에서 확정 |
| 2.2 | RefineEngine: 로드 상주, 샘플링 파라미터, 토큰 콜백, 타임아웃, 취소, 프롬프트 캐시 | 2.1 | TDD §3.4. **통합 방식 확정: whisper·llama가 ggml을 공유하는 단일 링크(중복 심볼 회피)**. actor 격리(whisper 패턴 재사용) |
| 2.3 | PromptBuilder: 시스템 프롬프트 v2 조립 + initial_prompt용 사전 용어 생성. LLM 프롬프트에 사전 미주입({dictionary_pairs}="(없음)" 고정, TDD §3.6) | 1.6 | Phase 0 산출물 |
| 2.4 | 상태 머신 확장: refining / awaitingInjection, 폴백 경로 | 2.2 | TDD §2 전이표 전수 구현. sttFailed→idle 시 error HUD "인식하지 못했어요" 1.5s 표시 후 소멸 (TDD §2·§5). Phase 1의 무표시 idle을 대체 |
| 2.5 | HUD 확장: raw 표시 → 스트리밍 렌더 → ready + 힌트 바 → error(1.5s) | 2.4 | 4줄 제한, 화면 위치 |
| 2.5b | HUD 리디자인: 우상단 앵커, 오브↔카드 스프링 모핑, Siri풍 비주얼(그라데이션 글로우·머티리얼), 메뉴바 아이콘 상태 연동 | 2.5 | TDD §3.8 개정판(2026-07-12) 기준. non-activating·key window 금지·클릭 통과 불변 재검증 필수. 완료 기준: 모핑 중에도 대상 앱 포커스 유지 확인 |
| 2.6 | Tab/Esc 인터셉트 (HUD 표시 중에만 소비) | 1.2, 2.4 | 다른 앱 키 입력 오염 금지 검증. **소비 게이트는 세션 상태(refining/awaitingInjection) 기준** — injected 유지 카드(5s, idle)는 HUD가 보여도 소비 금지. Tab(원문 주입) 시 injected 카드 라벨 구분(2.5b 리뷰 N4) |
| 2.7 | 자동 주입 타이머 N (메뉴 조절: 즉시/0.5/1.0/1.5/2.0s, UserDefaults 지속) | 2.4 | ✅ 완료. N=0.5s 확정 (도그푸딩) → PRD §10-3 해소 |
| 2.8 | 사전 편집 UI (설정 창 내 테이블 CRUD) | 1.6 | ✅ 완료. 메뉴바 "사전 편집…" 창, 디바운스 자동 저장. 부산물: 주입 자기창 가드 + injectFailed 카드 (TDD §2/§3.7/§5 갱신 — 상세 VERIFY [2.8]) |
| 2.9 | 타이밍 계측 + 디버그 메뉴 (최근 20세션 p50/p90) | 2.4 | ✅ 완료. TDD §6. Esc 취소율 측정 시작 (상세 VERIFY [2.9]) |
| 2.10 | 골든 테스트: Phase 0 오디오 30개 파이프라인 자동 회귀 | 2.4 | ✅ 완료. `ipcoding-bench/golden_test.py` + `golden/` 스냅샷 30개. 적중률 96.2%·결정성 diff 0·규칙 위반 0. 부산물: 사전 시드 17→33 확장 (음차·변종 쌍 — 상세 VERIFY [2.10]) |

**완료 기준**: T_ready p90 ≤ 3.5s. LLM 강제 실패 주입 시 원문 폴백 정상. Esc가 스트리밍 중 즉시 취소. Tab이 원문 주입. 도그푸딩에서 "Esc 취소율" 측정 시작.

**리스크**: 소형 LLM의 규칙 위반(구분자 에코·지시문 누출 — 프롬프트 v2에서도 에코 1/60건 잔존) — 2.2(RefineEngine)의 출력 정제로 방어(TDD §3.4 확정 규칙). 빈도 높으면 프롬프트 v3.

## Phase 3 — 제품화

| # | 태스크 | 비고 |
|---|---|---|
| 3.1 | 온보딩 플로우: 권한 2종(마이크·손쉬운 사용) 안내 + 상태 감지 + 딥링크 (TDD §4) | ✅ 완료. 클린 TCC 상태 실증 포함 — 입력 모니터링 불필요 실기 확인 (상세 VERIFY [3.1]) |
| 3.2 | ModelManager 완성: 다운로드·진행률·sha256·이어받기·재다운로드 | ✅ 완료 (재다운로드 UI 배선만 3.3으로). 강제 중단·이어받기·해시 일치 실증 — 상세 VERIFY [3.2]. 모델 업그레이드는 앱 릴리스에 태운다(버전별 모델 스펙 고정 → Sparkle 업데이트 → 새 모델 다운로드·검증·구 모델 삭제). 원격 카탈로그(앱 업데이트 없는 모델 교체)는 도입하지 않음 — 모델 교체는 프롬프트·파라미터 벤치 재검증(Phase 0식)이 필수라 릴리스 단위가 정본 (2026-07-13 결정) |
| 3.3 | 설정 화면: 핫키 변경(프리셋 3종), 입력 장치, 타임아웃, N, 모델 관리 | ✅ 완료. Launchpad/Spotlight 재실행→설정 창(메뉴바 만석 대응) 포함 — 상세 VERIFY [3.3]. 주입 방식 항목은 3.4로 이관 |
| 3.4 | UnicodeEventInjector (옵션 주입 방식) | ✅ 완료. 설정 "주입 방식" 포함, 개행→공백 치환(조기 실행 차단), 클립보드 무접촉 실증 — 상세 VERIFY [3.4] |
| 3.5 | 앱 아이콘·메뉴바 아이콘·이름 표기 확정 (PRD §10-2 해소) | ✅ 완료. IpCoding 확정, 오브+웨이브폼 아이콘(사용자 선택 C안), 메뉴바는 SF Symbol 유지 — 상세 VERIFY [3.5] |
| 3.6 | ~~Developer ID 서명 + 공증 파이프라인~~ → **v1.0+ 이관** | **배포 경로 확정 (2026-07-18, 사용자 결정): ADP 미가입 — GitHub + Homebrew tap 무공증 배포.** 공증은 공개 v1.0 시점에 사용자 반응 데이터를 보고 재결정 |
| 3.7 | ~~Sparkle 자동 업데이트~~ → **v1.0+ 이관 (3.6과 연동)** | 무공증에선 업데이트 산출물에 격리가 붙어 매번 Gatekeeper에 걸림 — 업데이트는 `brew upgrade`가 정책. Sparkle은 공증 도입 시 함께 |
| 3.8 | 무공증 배포: 빌드·ad-hoc 서명 스크립트 + GitHub Releases(zip) + 커스텀 Homebrew tap(cask) | ✅ 완료. v0.1.0 프리릴리스 공개 + hojoon07/homebrew-ipcoding tap. Homebrew 6 대응(trust 필수·--no-quarantine 제거→설치 후 xattr 안내). 무공증 3함정(iCloud xattr·adhoc+runtime·brew 6)은 VERIFY [3.8] |
| 3.9 | README / 랜딩 문서 (Mac Whisper 대비 차별점: 완전 로컬, BT 퍼스트, 정돈 파이프라인) | 설치 문서에 brew tap 경로가 1순위. 시스템 요구사항 16GB+ 명시 (§10-6) |
| 3.10 | 베타: 지인 개발자 3–5명 온보딩 관찰 | 권한 플로우 이탈 관찰이 목적. 배포는 3.8의 tap 경로 사용 |

**완료 기준**: 클린 맥(권한·모델 없음)에서 `brew install`→온보딩→첫 주입까지 5분 내(모델 다운로드 시간 제외). 무공증 경로의 Gatekeeper 안내가 README와 일치. ~~공증 통과. 자동 업데이트 동작.~~ (v1.0+ 기준으로 이관)

## 페이즈 공통 규칙

1. 모든 태스크는 완료 시 수동 검증 절차를 남긴다 (다음 회귀의 기준).
2. PRD·TDD와 구현이 어긋나면 코드가 아니라 문서를 먼저 고친다 (문서가 항상 현행).
3. 미결정 사항(PRD §10)은 해소 시점이 이 계획에 배치되어 있다: §10-3→태스크 2.7, §10-4·5·6→Phase 0, §10-2→태스크 3.5. §10-1(수익 모델)만 일정 무관 — Phase 3 시작 전까지 결정 필요(리포 공개 여부가 3.8–3.9에 영향).
