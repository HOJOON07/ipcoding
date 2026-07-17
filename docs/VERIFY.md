# 입코딩 — 수동 검증 절차 (VERIFY)

> 각 태스크 완료 시 수동 검증 절차를 여기에 누적한다 (구현계획서 공통 규칙 1).
> 자동화 불가 항목은 사용자 확인 후에만 완료로 표기한다.

## [1.1] 프로젝트 스캐폴딩 — 메뉴바 앱

빌드: `xcodebuild -project IpCoding/IpCoding.xcodeproj -scheme IpCoding -configuration Debug build`

자동 검증 (빌드 후):
- [x] `Info.plist`에 `LSUIElement = 1` (`plutil -p .../IpCoding.app/Contents/Info.plist`)
- [x] `CFBundleIdentifier = com.hojoon.ipcoding`
- [x] arm64 바이너리, 로컬 서명(adhoc) 정상 (`codesign -dv`)

수동 검증 (사용자 확인 필요):
- [x] 앱 실행 시 메뉴바 오른쪽에 마이크 아이콘이 나타난다 (2026-07-09 확인)
- [x] Dock과 ⌘Tab 앱 전환기에 IpCoding이 나타나지 **않는다** (LSUIElement) (2026-07-09 확인)
- [x] 아이콘 클릭 → 메뉴에 "입코딩 v0.1 (Phase 1)"(비활성)과 "종료"가 보인다 (2026-07-09 확인)
- [x] "종료" 클릭 시 앱이 종료되고 아이콘이 사라진다 (2026-07-09 확인)

## [1.2] HotkeyManager — 이벤트 탭, ⌘+Fn 감지

준비: 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 IpCoding 켜기 → 앱 재시작 (권한은 탭 재생성 후 반영).
로그 관찰: `/usr/bin/log stream --level debug --predicate 'subsystem == "com.hojoon.ipcoding"' --style compact`

- [x] 권한 부여 후 시작 로그에 "이벤트 탭 시작" (2026-07-09 확인)
- [x] ⌘+Fn 1초+ 홀드 → DOWN, 릴리즈 → UP(홀드 시간 포함) 로그 (2026-07-09, 0.38s/4.53s/6.79s/4.50s 4회 확인)
- [x] 200ms 미만 스침 → CANCELLED 로그 (2026-07-09, 96ms/92ms 2회 확인)
- [x] ⌘ 단독·Fn 단독 입력 시 무반응 (2026-07-09 확인)
- [ ] (자동화 불가·기회 시 확인) 탭 타임아웃 재활성화 — 로그에 "이벤트 탭 비활성화 감지 — 재활성화"가 뜨는 경우 정상 복구되는지

## [1.3] AudioCapture — 마이크 캡처, 16kHz mono 변환

전제: Hardened Runtime + `com.apple.security.device.audio-input` 엔타이틀먼트 (없으면 다이얼로그 없이 무음). 서명 반영 확인: `codesign -d --entitlements - <app>` → audio-input 키.
검증 스크립트: `python3`로 wav 피크/RMS/유의미 샘플 분석, `afplay`로 재생.
디버그 덤프 경로: `$(getconf DARWIN_USER_TEMP_DIR)ipcoding-capture.wav` (DEBUG 전용, 고정 파일명 덮어쓰기, 1.8에서 제거).

- [x] 앱 시작 시 마이크 권한 다이얼로그 → 허용 후 시스템 설정 > 마이크 목록에 IpCoding 등록 (2026-07-09 확인)
- [x] ⌘+Fn 홀드 발화 → wav 덤프, 포맷 16kHz mono Int16 (2026-07-09 확인)
- [x] wav에 실제 음성 존재 (피크 9.5%·RMS 318·유의미 샘플 31%, 무음 아님) + 재생 시 발화 내용 일치 (2026-07-09 확인)
- 검증 후: 덤프 wav는 임시 파일이라 재부팅/temp 정리 시 삭제됨. 수동 삭제 원하면 위 경로 rm.

## [1.4] ModelManager — 모델 경로 해석 (Phase 1 최소)

- [x] `~/Library/Application Support/IpCoding/models/`에서 whisper 모델 인식 (2026-07-09, 로그 "배치됨")
- 개발용 배치: `ipcoding-bench/models/`의 모델을 위 경로에 심볼릭 링크 (547MB 중복 회피). 프로덕션 다운로드는 태스크 3.2.

## [1.5] TranscribeEngine — whisper.cpp 통합, 전사

통합: xcframework 사전 빌드(build-xcframework.sh, macOS arm64, GGML_METAL_EMBED_LIBRARY=ON) → IpCoding/Vendor/whisper.xcframework(gitignore, 재생성 가능) → pbxproj 링크 + Embed&Sign(dynamic framework). 모듈명 `whisper`, `import whisper`.
재빌드 절차: scratchpad에서 whisper.cpp 클론 → macOS 슬라이스 빌드 → Vendor/로 복사(dSYMs 포함 — Info.plist가 DebugSymbolsPath 참조).

- [x] 앱 시작 시 whisper 컨텍스트 로드 + 0.5초 무음 워밍업 (2026-07-09, 로그 확인)
- [x] ⌘+Fn 발화 → 실제 전사 성공 (2026-07-09: "이 컴포넌트 유즈 스테이트 바이오 유즈 리디세로 리팩토링 해줘")
- [x] 성능: 5.82s 발화 → 0.55s 전사 (RTF ≈ 0.09, Metal 가속) — Phase 1 지연 목표 충족
- [x] 기술용어 오인식은 예상대로 (사전·initial_prompt 미적용 상태) → 태스크 1.6에서 교정
- 검증 덤프: `$(getconf DARWIN_USER_TEMP_DIR)ipcoding-transcript.txt` (DEBUG 전용, 1.8에서 제거).

## [1.6] UserDictionary — 시드 사전 치환 + initial_prompt

배치: `ipcoding-bench/dictionary_seed.json`을 `~/Library/Application Support/IpCoding/dictionary.json`으로 복사 (심링크 아닌 복사 — 편집이 벤치 원본 오염 방지). Phase 1은 파일 직접 편집(UI는 2.8).

- [x] 앱 시작 시 사전 로드 (2026-07-10, 로그 "17개 항목")
- [x] initial_prompt 효과 실측 — 같은 발화 비교:
  - 1.5 (힌트 없음): "유즈 스테이트 바이오 유즈 리디세로"
  - 1.6 (힌트+사전): "useState 말고 useReducer로" — 기술용어 3개 정확 전사
- [x] 성능 유지: 7.15s 발화 → 0.65s (initial_prompt 추가에도 지연 미미)
- 잔존 오인식(예: "컴포먼트")은 사전 확장 또는 LLM 교정(Phase 2) 몫 — 3겹 방어 설계대로.

## [1.7] PasteboardInjector — 클립보드 경유 주입

순서 (TDD §3.7): 백업(아이템 단위) → set → ⌘V post → 250ms 후 복원(changeCount 불일치 시 포기).
전제: 손쉬운 사용 권한(CGEvent post). HUD non-activating(1.9 전까지 HUD 없음).

- [x] 전사문이 활성 앱에 주입됨 — cmux·Chrome·카카오톡 등 다중 앱 (2026-07-10)
- [x] 한글+영어 혼용 무결 — 48자 긴 문장 깨짐 없이 주입 (Phase 1 완료 기준)
- [x] 클립보드 복원 — 주입 후 원래 복사 내용 유지 (사용자 확인)
- [x] 성능: 발화 → 전사 0.55s → 주입 완료 매끄러움
- 참고: whisper 원문 주입 단계(오인식 교정은 사전 확장·Phase 2 LLM 몫). bracketed paste로 즉시 실행 안 됨(터미널 안전).

## [1.8] SessionCoordinator — 상태 머신 (축소판)

전이 (TDD §2 Phase 1): idle→recording→transcribing→injecting→idle + hotkeyCancelled/sttFailed→idle, maxDuration 강제 마감.
- [x] 정상 세션: 캡처→전사+치환→주입→idle 복귀 (2026-07-10, cmux 주입 확인)
- [x] 빈 입력 단락: 짧은 눌림 → 캡처 0 샘플 → 전사·주입 없이 idle (2026-07-10 로그 확인)
- [x] 연속 세션: 매 세션 깨끗이 idle 복귀 후 재시작 (레이스 없음)
- [x] 임시 배선·DEBUG 덤프 완전 제거 (PLAN 1.8 완료 기준), IpCodingApp은 이벤트 얇은 전달만
- WARN 1 해소: 엔진 start를 탭 콜백에서 Task로 미룸(콜백 블로킹 방지) + 세대 토큰으로 pending start 무효화(레이스 차단). BT 스톨 off-main은 실측 후 과제(TDD §3.2).

## [1.9] HUD — 최소 상태 표시 (recording 레벨미터 / processing 스피너)

핵심: NSPanel non-activating — key window가 되면 주입 대상이 사라짐(makeKey 금지, orderFrontRegardless).
- [x] 녹음 중 하단 중앙에 HUD + 마이크 레벨 미터가 목소리에 반응 (2026-07-10)
- [x] 손 뗀 후 "처리 중…" 스피너로 전환
- [x] 처리 완료 후 HUD 자동 소멸
- [x] **non-activating 무결 — HUD 표시 중에도 주입 대상이 앞 앱(cmux·Chrome)으로 정확히 잡힘** (로그 교차 확인, key window화 안 됨)
- RMS 레벨: AudioCapture.currentLevel(lock 보호) → HUDViewModel 30fps 폴링(상승 즉시·하강 완만).

## [1.10] 수동 테스트 매트릭스 — 다중 앱 주입 (Phase 1 완료 확인)

도그푸딩 중 자연 검증 (2026-07-10, 사용자 확인). 터미널 4종 + 일반 앱:
- [x] cmux (com.cmuxterm.app) — 주 타깃
- [x] 맥 기본 Terminal.app
- [x] Warp
- [x] VS Code 터미널
- [x] (덤) Chrome/브라우저, 카카오톡 — 일반 앱에도 주입 (터미널 전용 아님 확인)
- 한글+영어 혼용 무결, 클립보드 복원, non-activating(주입 대상 앞 앱 유지) 전 앱 공통.

**Phase 1 완료 기준 점검**: 한영 무결 ✅ / 클립보드 복원 ✅ / 터미널 4종 ✅ / T_inject 관측상 ≤1.5s(전사 ~0.5s+주입 ~0.25s, 여유 큼 — p90 정식 계측은 2.9) ✅ / 도그푸딩 시작 가능 ✅.

## [2.2] RefineEngine — llama.cpp 통합, 프롬프트 캐시

빌드: whisper.cpp+llama.cpp 공유 ggml 결합 `IpCodingEngine.xcframework` (재현: `scripts/build-engine.sh`). import IpCodingEngine 한 줄로 양쪽 C API.
전제: `Qwen3.5-9B-Q4_K_M.gguf` (unsloth, mainline 호환) 배치.

- [x] 결합 xcframework 중복 심볼 0 — whisper_full·llama_decode·ggml_init 각 1개 (nm 확인)
- [x] whisper 전사 회귀 없음 (결합 프레임워크로 교체 후)
- [x] llama 로드 + 2-시퀀스 프롬프트 캐시 준비 (프리픽스 518토큰, seq 0 상주)
- [x] 교정 정확 — 실기기 자가 테스트 (제거됨): "useState 말고 useReducer" 문장 불변(의도 보존), "커밋해줘"→"커밋해줘"(규칙4 준수). 2.1 CLI 스파이크 품질 재현.
- [x] 프롬프트 캐시 속도: 첫 호출 0.69s, 캐시 경로 **0.24s** (2.1 스파이크 211ms 재현)
- [x] 한글 UTF-8 스트리밍 무결 (바이트 누적, 다토큰 글자 안 깨짐)

### 디버깅 기록 (회귀 주의)
- **n_seq_max 기본 1** → seq 1(캐시용) 디코드 실패. 컨텍스트에 `n_seq_max=2` 필수.
- **seq_rm 부분 제거 실패**(removed=false) → 프리픽스만 남기는 방식 불가. 2-시퀀스 복사(seq 0→1)로 우회.
- **batch_get_one 자동 위치 추적**은 seq 조작 후 어긋남 → 명시적 pos batch 사용.
- llama.h가 ggml-opt.h 전이 include, C++ 래퍼 llama-cpp.h는 모듈맵 제외 (build-engine.sh 반영).

## [2.3] PromptBuilder — 프롬프트 조립 정식화

구조: 번들 리소스 refine_v2.txt(벤치 정본과 diff 0) → PromptBuilder가 {dictionary_pairs}="(없음)" 고정 + ChatML 조립(씽킹 시드) + whisper initial_prompt 생성. 임시 Application Support 파일 로드 제거.

- [x] refine_v2.txt가 앱 번들 Resources에 자동 포함 (폴더 동기화 그룹) (2026-07-10)
- [x] 조립 무결성: 프리픽스 캐시 518토큰 — 2.2 인라인 조립과 동일 (v2 프롬프트 무변형 증거)
- [x] 실기기 회귀: "유즈스테이트/유즈리듀서" 발화 → useState/useReducer 정확 주입 (initial_prompt가 PromptBuilder 경로로 정상, 사용자 확인)
- 설계 갭 해소: TDD §3.3(initial_prompt 생성 주체)·§3.5(ChatML 조립 주체) 명세와 코드 일치. UserDictionary는 치환 데이터·적용만 담당.
- 이월 항목 (2.3 리뷰 NIT): ① PromptBuilder 골든 테스트는 태스크 2.10에 편입 ② 사전이 자라면 whisper initial_prompt 토큰 한도(절삭 동작)를 macos-api-researcher로 조사 후 상한 정책 결정.

## [2.4] 상태 머신 확장 — TDD §2 전이표 전수, LLM 파이프라인 배선

전이: refining/awaitingInjection 추가, 전이표 14건 전수 구현 (리뷰 대조 확인). Esc/Tab 메서드는 존재하되 키 인터셉트 배선은 2.6.

- [x] **MVP 파이프라인**: 발화("어 그러니까 … 음 …") → 군말 제거·교정("어"/"음" 제거, useState/useReducer 정확) → 1s 대기 → 주입 (2026-07-10)
- [x] 성능: T_ready(전사+교정) ≈ 1.2s — TDD §6 예산(≤3.5s) 여유 충족 (프롬프트 캐시 효과. 전사 0.5s + 교정 0.64s + N 1.0s + 주입 0.27s ≈ 총 2.4s)
- [x] sttFailed → error HUD "인식하지 못했어요" 1.5s 표시 후 소멸 (Phase 1 무표시 대체, 2회 확인)
- [x] 짧은 커맨드("커밋해줘") — LLM이 응답하지 않고 그대로 주입 (규칙 4)
- [x] "그러니까" 잔존은 v2의 문서화된 보수 성향 (Phase 0: 의도 보존 우선) — 정상
- 타임아웃(첫 토큰 3s/전체 8s→llmTimeout→원문 폴백)·llmError 폴백은 코드 리뷰로 검증 (인위 재현 불가) — 원칙 3 경로 4건 전수 확인

### 무음 환각 방어 (2겹 — 실기기 캘리브레이션)
whisper는 무음에서 빈 결과 대신 환각을 지어낸다 (실기기: "스포츠", ".", "감사합니다").
- 1차 no_speech 필터(문턱 0.6): 확신형 환각("감사합니다")은 못 잡음 — 실기기 확인
- **2차 에너지 게이트(RMS 0.002)**: 무음 0.0004~0.0005 차단 / 발화 0.0104 통과 — 양쪽 4~5배 마진 (실측 캘리브레이션 완료)

## [2.5b] HUD 리디자인 — 모핑 오브, 우상단, Siri풍 (TDD §3.8 개정판)

- [x] 우상단(메뉴바 아래) 그라데이션 오브 — 웨이브폼·글로우가 목소리에 반응 (2026-07-12)
- [x] 오브 → 카드 스프링 모핑 (우상단 앵커 고정, 좌·하방 확장)
- [x] 카드: 원문·교정 라벨 병기 (주입 전 비교 — 원칙 4 강화, 사용자 요청 반영)
- [x] **주입 후 비교 카드 5s 유지** (✓ 주입 완료) — 도그푸딩 피드백 "너무 빨리 닫힘" 대응. 새 세션 시작 시 즉시 대체
- [x] **non-activating 무결 (PLAN 2.5b 완료 기준)** — 모핑·우상단 이동 후에도 주입 정상 (사용자 확인)
- [x] 메뉴바 아이콘 상태 연동 — 녹음 빨간 펄스/처리 웨이브폼/idle 마이크
- [x] 자동 주입 N: 1.0→1.5s (도그푸딩 데이터 — 2.7에서 최종 확정)

### 회귀 주의 — 투명 패널 사각 아티팩트 2종
1. 시스템 윈도우 그림자(hasShadow) — 투명 borderless 창에서 사각 윤곽. OFF 필수 (깊이는 SwiftUI 그림자).
2. **글로우 잘림** — SwiftUI shadow가 패널 경계에서 사각형으로 클리핑. 콘텐츠에 글로우 여백(glowPadding ≥ 그림자 최대 반경)을 포함시켜 해결.

## [2.6] Tab/Esc 인터셉트 — 세션 상태 게이트 소비

구조: 코디네이터가 전이 시 인터셉트 모드 지시(refining=Esc만/awaitingInjection=Esc·Tab/그 외=none) → HotkeyManager keyDown 소비(nil 반환). ⌘/⌃/⌥ 조합은 무조건 통과.

- [x] **평상시 비오염** — 앱 상주 중 에디터·브라우저에서 Tab/Esc 정상 (2026-07-12, 사용자 확인)
- [x] ⌘Tab 앱 전환 정상 (수정자 조합 통과)
- [x] Esc: 완성 카드 중 취소 → 주입 안 됨, HUD 소멸
- [x] Tab: 완성 카드 중 원문(사전 치환본) 주입 + 유지 카드 "원문" 단일 행
- [x] 주입 후 유지 카드(5s, idle) 중 Tab/Esc 비소비 — 평소처럼 동작
- TDD §3.1을 §2 정본에 정렬 (refining Esc 포함, 수정자 통과, injected 중 소비 금지 명문화)
- 리뷰 반영: 홀드 리피트 소비(델리게이트 재발행 없음), Shift+Tab 통과(역들여쓰기 보호), stop() 모드 리셋, 주석 정합
- 잔여 엣지 (2.6 리뷰 W1): Tab을 injecting 전이(~0.3s) 너머까지 홀드하면 리피트가 대상 앱에 누출될 수 있음 — 재현 시 spec-guardian 확인 후 injecting 중 소비 확장 검토. keyUp 고아 전달(N5)은 터미널 대상이라 무해로 수용.

## [2.7] 자동 주입 타이머 N — 메뉴 조절 + 확정

- [x] 메뉴바 "자동 주입 대기" 서브메뉴 (즉시/0.5/1.0/1.5/2.0s) — 선택 즉시 적용·체크마크·UserDefaults 지속 (2026-07-12, 사용자 확인)
- [x] **N=0.5s 확정 (PRD §10-3 해소)** — 도그푸딩 선택. 주입 속도 우선, 주입 후 5s 비교 카드가 검토 창 보완
- [x] "즉시" 옵션 제공 (Tab/Esc 창 없음 트레이드오프를 라벨에 고지)
- 리뷰 APPROVE: UserDefaults 0 구분·타이머 다음 세션 적용·sleep(0) 안전 확인. NIT 반영(=== 동일성, 저장값 정규화). register 순서 버그(첫 실행 체크마크) 자체 발견·수정.
- 참고: 도그푸딩 중 음성 주입이 열린 에디터의 PLAN.md에 꽂힌 흔적 발견·정리 — 주입 대상 확인 습관 필요 (실사용 교훈).

## [2.9] 타이밍 계측 + 디버그 메뉴

- [x] 메뉴바 "타이밍 통계": 최근 20세션 p50/p90 (T_raw/첫 토큰/T_ready/T_inject) + 폴백·Esc 취소율, 열 때마다 갱신 (2026-07-15, 사용자 확인)
- [x] 계측 교차 검증 (로그): 6세션 = 주입 4 + Esc 취소 2 — 지점별 기록 정상
- [x] Esc 취소율 측정 시작 (Phase 2 완료 기준) — 첫 실측 33% (2/6, 테스트 포함이라 참고치)
- 통계는 메모리에만 (재시작 시 초기화). T_ready p90 공식 판정은 도그푸딩 세션이 20개 쌓인 시점에.

## 회귀 주의 — 마이크 무음 3증상
다이얼로그 안 뜸 + 시스템 설정 마이크 목록 부재 + 캡처 전부 0값 → 원인은 **audio-input 엔타이틀먼트 누락**(Hardened Runtime 하 TCC 즉시 거부). `AVCaptureDevice.requestAccess` 명시 호출은 부차. 서명에 엔타이틀먼트 없으면 tccutil reset·requestAccess 다 무효.

## [2.10] 골든 테스트 — Phase 0 오디오 30개 파이프라인 자동 회귀

`ipcoding-bench/golden_test.py`: 앱 파이프라인을 CLI로 복제(whisper-cli initial_prompt → 사전 단일패스 최장매칭 → llama-server v2 ChatML+씽킹 시드, temp 0.2/seed 0/top_k·min_p 비활성/n_predict=min(1024,max(64,델타토큰×2)) → 정제 4단계) → `golden/*.json` 스냅샷 diff. 리뷰가 복제 충실도 전 항목(치환·프롬프트 조립·정제·파라미터) 일치 판정.

- [x] **결정성**: 서버 재기동 포함 재실행 스냅샷 diff 0건 — seed 0 고정 실증 (2026-07-17, 3사이클 전부)
- [x] **용어 적중률(치환 후) 96.2%** (25/26, 게이트 ≥90%) · 평균 CER(A~D) 0.0891 — Phase 0 치환 후 값과 일치. 유일 누락 s01 useReducer는 whisper "useReduce" 꼬리 잘림(LLM이 하류 복원, 최종 출력 기준 26/26)
- [x] 규칙 위반 0건 (think 누출·구분자 에코·빈 출력)
- [x] 실행 시간 전체 30문장 ≈ 1분 20초 (llama-server 기동 포함)
- exit 규약: 0=통과 / 1=회귀(스냅샷 diff·규칙 위반) / 2=적중률 게이트만 미달 / 3=환경 오류. `--only` 서브셋은 게이트 생략.

### 구조적 발견 — 사전 확장 17→33 (초기 실행 적중률 57.7%의 원인)
Phase 0 벤치는 whisper에 타깃 용어 26개 전부를 프라이밍했지만 앱은 사전 written만 주입 → useState류가 "유지 스테이트"로 전사되고 시드 사전에 음차 쌍이 없어 치환 실패. **골든 테스트가 앱을 충실히 복제했기에 드러난 갭.** 음차(유지/유즈 스테이트·리듀서·이펙트, 클린업, 타일/타입스크립트)·표기 변종(Stale Time, Git rebase, Rate Limiting, CMUX, false push, API 키)·s21 의도 파괴 방지(커밋 태조→커밋해줘) 16쌍 추가로 해소. 라이브 사전(`~/Library/Application Support/IpCoding/dictionary.json`)도 구 시드 무수정 사본 확인 후 동기화.

### 도그푸딩 관찰 항목 (사전 확장 2차 효과)
- initial_prompt에 영어 용어가 늘며 한국어 단어의 영어화 경향: s23 "빌드"→"Build", s04 "제네릭으로 타입"→"Generic으로 Type" (의미 동일, 표기만). "Build→빌드" 사전 등록 여부는 REPORT §7-④ 방침대로 사용자 결정 대기.
- 사전 치환은 단어 경계 미인식(리뷰 N9): "유지 스테이트리스"→"useState리스" 이론 위험 — 벤치 문장에선 무해, 실사용 오발동 관찰 시 UserDictionary 경계 검사 검토.
- 결정성은 동일 whisper.cpp/llama.cpp 빌드 전제 — **brew 업그레이드 후 diff 발생은 회귀가 아니라 스냅샷 재검토·갱신 신호.**
