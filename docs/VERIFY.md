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

## [2.8] 사전 편집 UI — 테이블 CRUD + 주입 자기창 가드

메뉴바 "사전 편집…" → 일반 창(SwiftUI Table, 2열: 들리는 대로→원하는 표기). 변경은 0.5s 디바운스 자동 저장(TDD §3.6 "변경 즉시 파일 저장 + 메모리 반영"), 파일엔 편집 순서·메모리엔 최장매칭 정렬. 미완성 행(한쪽 빈 칸)은 저장 제외. 반영은 기존 설계 덕에 자동 — apply/whisperInitialPrompt가 세션마다 entries를 읽음(LLM 프롬프트엔 사전 미주입이라 KV 캐시 무효화 불요).

- [x] CRUD: 33개 항목 파일 순서 표시, 행 추가/삭제(⌫)/수정, 창 재열기 후 유지 (2026-07-17, 사용자 확인)
- [x] 편집 → 다음 발화부터 치환·whisper 프라이밍 반영 (사용자 확인)
- [x] **자기창 가드**: 편집 창이 활성인 채 발화 → 창에 주입되지 않고 "⚠ 주입 실패" 카드 5s + 사전 미오염 (사용자 확인)
- [x] 회귀: 창 닫은 후 일반 터미널 주입 정상 (사용자 확인)
- 리뷰 2회(1차 W3/N3, 델타 W1/N4) 전건 반영: 디바운스, 파일 순서 보존, NSAlert 지연·1회 제한, typed error(InjectionError.selfIsFrontmost)

### 설계 변경 — 주입 자기창 가드 (spec-guardian 판정, 사용자 승인 2026-07-17)
2.8이 앱 최초의 key window 가능 창을 도입 → "주입 시점에 자기 앱은 frontmost가 아니다" 전제(HUD non-activating만으로 보장)가 깨짐. TDD 3곳 갱신: §2 `injecting --failed--> idle` 추가(⌘V 무반응 실패에도 원래 필요했던 공백), §3.7 대상 검증을 로깅→강제 가드로 격상(코디네이터 선행 검사 한 곳 — 향후 설정 창·주입기 추가 자동 커버), §5 실패 원인 확장. 가드·⌘V 실패 공통으로 **injectFailed 카드 5s가 결과 텍스트를 유지** — 원칙 3(발화 증발 금지)의 §5 최소 이행.

### 수용 엣지·후속
- 가드는 check-then-act — 검사~⌘V 착지 사이 수 ms 창의 포커스 전환은 못 막음(축소이지 절대 보장 아님, 주석 명시).
- 편집 창 닫기는 onDisappear 미보장이나 디바운스(0.5s)가 저장을 완결 — 실손실은 "타이핑 후 0.5s 내 앱 종료" 엣지뿐.
- 주입 실패는 아직 지표 미집계(recordCompleted는 성공만) — 실패율 관찰 필요해지면 MetricsStore 카운터 추가(TDD §6 확인 후).
- §5 "복사" 버튼은 후속(HUD 확장 몫) — injectFailed 카드는 표시만.

## [3.1] 온보딩 플로우 — 권한 2종, 자동 진행

환영→마이크→손쉬운 사용→완료 4화면 (TDD §4 갱신판: 권한 2종). 각 단계 "한 문장 이유 + 허용 버튼/딥링크 + 0.7s 폴링 자동 진행". 시작 시 무맥락 requestAccess 제거 — 요청은 온보딩 단계 버튼에서. 온보딩 표시 조건 = 권한 미충족(시작 시마다 재검사, 완료 플래그 저장 없음 — 멱등).

- [x] **클린 상태 실증** (tccutil reset Accessibility+Microphone+ListenEvent 후, 2026-07-17 사용자 확인): 시작 시 온보딩 표시 → 마이크 허용(다이얼로그) 자동 진행 → 손쉬운 사용 허용 자동 진행 → 완료
- [x] **손쉬운 사용 부여 감지 → 탭 재생성**: 앱 재시작 없이 ⌘+Fn 전체 파이프라인 즉시 동작
- [x] **입력 모니터링 불필요 실증**: ListenEvent 리셋 상태(목록 부재/꺼짐)에서 핫키·Esc/Tab 소비·⌘V 주입 3종 정상 — TDD §4 2권한 매트릭스(2026-07-17 개정)의 실기 근거
- [x] 메뉴바 "권한 설정…" 재진입 — 권한 충족 시 완료 화면 직행
- 마이크 미부여 발화 시 "마이크 권한이 필요해요 — 메뉴바 > 권한 설정" 에러 배지 2.5s (리뷰 W1 — 코드 검증, 미부여 상태 재현 테스트는 생략)
- 리뷰 W2: 온보딩 창은 비재사용 — windowWillClose에서 참조 해제 → 뷰 .task 폴링 확정 종료 (사전 편집 창의 재사용 구조와 의도적으로 다름: 사전 창은 디바운스 저장 완결을 위해 유지)
- 수용: 단계 점(4개 고정)이 권한 일부 기부여 시 점프(코스메틱, 리뷰 N2)

### 회귀 주의 — 권한 매트릭스 (2026-07-17 개정)
소비형(.defaultTap) 이벤트 탭과 CGEvent post는 **손쉬운 사용 하나로 게이트**된다. 입력 모니터링은 listen-only 탭 전용 — 온보딩에 추가하지 말 것(수동 토글 시 앱 재시작 요구). 권한 판정 정본은 AXIsProcessTrusted() (tapCreate nil은 부분 실패 가능). 부여 감지 후엔 반드시 탭 stop()/start() 재생성.

## [3.2] ModelManager 완성 — 다운로드·이어받기·sha256

ModelDownloader: dataTask 델리게이트 청크 쓰기 + `.partial` Range 이어받기(TDD §3.9 개정 2026-07-17). 불변식: **최종 파일명 존재 = sha256 검증 통과본** — 검증 통과 시에만 rename 승격. 온보딩에 "AI 모델 다운로드" 단계(순차 whisper→qwen, 진행 바+바이트, 실패 유형별 문구+재시도). 메타 해시는 로컬 검증 파일 채취 + 업스트림 바이트 크기 일치 확인(whisper 574,041,195 / qwen 5,680,522,464).

- [x] **실다운로드 + 강제 중단 + 이어받기 실증** (2026-07-17): whisper 574MB 다운로드 중 258.9MB 지점에서 앱 강제 종료 → 재실행 시 partial 261.8MB 보존 → 그 지점부터 재개 → 완료
- [x] **무결성**: 두 조각을 이은 최종 파일 sha256 = 스펙 해시 정확 일치, partial 소멸(rename)
- [x] **다운로드 직후 엔진 자동 로드**: 앱 재시작 없이 발화→전사→교정→주입 정상 (사용자 확인)
- [x] 완료 화면 자동 전환, 기설치 모델(qwen) "완료" 표시·스킵 (사용자 확인)
- 리뷰 CRITICAL 0 / WARN 4 / NIT 4 전건 반영·처리: 416 무한 루프 차단(성공 마감→검증 위임), 취소 레이스 lock 봉합(attach/cancel), 강제 언래핑 제거(urlString+guard), short-read partial 보존, 디스크 오류 문구 분기, 엔진 로드 실패 시 플래그 리셋
- 수용/후속: 진행률 콜백 Task 홉 순서 비보장(0.25s 스로틀이라 실害 미미), redownload 호출원 배선은 3.3 설정 화면 몫(PLAN 명시), If-Range 미사용(업스트림 파일 교체 시 혼합 바이트는 sha256이 백스톱)

### 회귀 주의 — 다운로드 검증 불변식
`.partial`이 아닌 최종 파일명은 항상 검증 통과본이다. 이 불변식을 깨는 변경(검증 전 rename, partial에 직접 최종명 사용) 금지. 모델 교체(릴리스 단위)는 spec의 url/sha256/sizeBytes 3종을 함께 갱신하고 골든 테스트 재검증 필수 (PLAN 3.2 방침).

## [3.3] 설정 화면 — 핫키·입력 장치·N·타임아웃·모델 관리

메뉴바 "설정…"(⌘,) + Launchpad/Spotlight 재실행(applicationShouldHandleReopen — 도그푸딩 피드백: 메뉴바 만석 시 아이콘 실종 대응). 저장 정본은 UserDefaults(@AppStorage), 런타임 반영은 onChange 클로저 + 시작 시 applyStoredSettings(목록 외 값 정규화 포함). 주입 방식 항목은 3.4로 이관.

- [x] 설정 창 5섹션 표시 + Spotlight 재실행 → 설정 창 (2026-07-17, 사용자 확인)
- [x] **핫키 프리셋**: ⌥+Fn 전환 즉시 적용·⌘+Fn 무반응, 복귀 정상 (TDD §3.1 개정 실증)
- [x] **입력 장치**: CoreAudio 열거 목록 표시, 장치 선택 후 발화 인식 정상 (UID 저장·세션 시작 시 해석·부재 시 시스템 기본 폴백 — TDD §3.2 개정)
- [x] **메뉴-설정 동기화**: 자동 주입 N 변경 시 메뉴 체크마크 추종 (UserDefaults 단일 정본 + menuNeedsUpdate 재계산)
- [x] 회귀: 발화→주입 정상 (RefineProgress 타임아웃 파라미터화 무영향)
- 모델 재다운로드·삭제·전역 배타(activeDownloadId)는 코드 검증 (리뷰 W1 반영 — 실다운로드 생략, 3.2에서 다운로드 경로 자체는 실증됨). 타임아웃 변경 실효도 코드 검증 (인위 재현 곤란).
- 리뷰 CRITICAL 0 / WARN 1 / NIT 4 전건 처리: 다운로드 전역 배타(ModelManager로 격상, 창 닫힘=백그라운드 지속 정책 명문화), 삭제 시 .partial 정리, 타임아웃 정규화, TDD §3.2 API 표면 정밀화
- 잔존 엣지 (리뷰 N3, Phase 2부터 존재): 콤보 수정자를 쥔 채 Esc → 인터셉트 통과 게이트에 걸려 취소 불가 + 대상 앱 누출 — 콤보 선택지 확대로 노출 여지 증가, 실사용 재현 시 처리 검토

## [3.4] UnicodeEventInjector — 옵션 주입 방식 (클립보드 무접촉)

CGEventKeyboardSetUnicodeString 청크 주입(UTF-16 20단위, 서러게이트 경계 보호, 청크 간 1ms, 주입 전 50ms IME 마감 여유). 합성 이벤트 flags 비움(하드웨어 수정자 상속 차단 — 리뷰 W1). **개행→공백 치환** (사용자 결정 2026-07-18): bracketed paste 보호가 없는 키 입력 방식에서 터미널 조기 실행 차단 (TDD §3.7 명기). 방식 선택은 설정 "주입 방식"(InjectorRouter — 코디네이터는 Injecting 하나만, 단방향 유지).

- [x] 유니코드 모드: 한/영 혼용 발화 → 깨짐 없이 정확 주입 (2026-07-18, 사용자 확인)
- [x] **클립보드 무접촉 실증**: 감시 텍스트(sentinel)를 심은 뒤 유니코드 주입 → ⌘V에 sentinel 그대로 — 클립보드 완전 무변화
- [x] 기본(클립보드) 복귀 후 회귀 정상
- 체감 속도: 2줄(~150자)은 ~20ms로 순간 완료 — "타이핑 효과"는 수백 자급에서만 관찰 (기대 동작)
- 리뷰 CRITICAL 0 / WARN 2 / NIT 3 전건 처리: flags 비움, 개행 정책(승인), keyUp 문자열 미러링, frontmost 로깅 .private 정렬(양 주입기)
- 수용 한계 (리뷰 N2): injecting 중 인터셉트는 .none이라 유니코드 주입(긴 텍스트 수백 ms) 도중 실제 키 입력이 청크 사이에 끼어들 수 있음 — 설계 수용, 실사용 문제 시 재검토

## [3.5] 앱 아이콘·영문명 확정

- [x] **PRD §10-2 해소**: 영문명 IpCoding 확정 (번들 ID·리포명·타깃명과 일치 — 변경 연쇄 0), 한글명 "입코딩" 병기 (2026-07-18)
- [x] 앱 아이콘: 후보 3종(마이크/터미널+웨이브/오브+웨이브) 중 **C안(오브+웨이브폼)** 사용자 선택 — HUD 오브와 정체성 일치. 인디고→퍼플 그라데이션 플레이트 + 반투명 오브 + 흰 웨이브폼 5바
- [x] Assets.xcassets/AppIcon(mac 10사이즈) + ASSETCATALOG_COMPILER_APPICON_NAME — Info.plist 키·AppIcon.icns·Assets.car 생성 확인, Finder 표시 확인 (사용자)
- 메뉴바 아이콘은 SF Symbol(mic) 템플릿 유지 — 시스템 정합(다크·라이트 자동 대응), 상태 연동은 2.5b 구현 그대로
- 원본 1024px 렌더 스크립트는 세션 스크래치패드 (icon_candidates.swift — 재생성 필요 시 리포에 편입 검토)

## [3.8] 무공증 배포 — GitHub Releases + Homebrew tap

scripts/release.sh(Release arm64 → xattr 정리 → ad-hoc 재서명 → 엔타이틀먼트·get-task-allow 게이트 → zip+sha256) + v0.1.0 프리릴리스 + hojoon07/homebrew-ipcoding tap(cask).

- [x] **설치 파이프라인 전 구간 실증** (2026-07-18, 사용자 확인): `brew tap hojoon07/ipcoding` → `brew trust` → `brew install --cask ipcoding` → `xattr -dr com.apple.quarantine` → 실행 → 온보딩(TCC 재부여) → 발화 → 터미널 주입
- [x] 릴리스 zip 압축 해제본 직접 실행 생존 검증 (whisper 로딩·Metal 초기화 도달, dyld 에러 없음) — 릴리스 절차에 편입
- [x] 최종 서명: adhoc(0x2), 엔타이틀먼트 audio-input 단일, sha256 7e3c08e9…

### 회귀 주의 — 무공증 배포 3함정 (전부 실측)
1. **iCloud 동기화 폴더에서 서명 금지**: ~/Desktop 하위 빌드 산출물에 파일 프로바이더가 FinderInfo xattr을 붙여 codesign이 "detritus"로 거부 — 릴리스 빌드는 ~/Library/Caches/ipcoding-release/에서. (같은 환경에서 소스 빌드하는 베타 테스터도 겪을 수 있음)
2. **ad-hoc + hardened runtime 조합 금지**: --options runtime이 Library Validation을 강제하는데 ad-hoc은 팀 ID가 없어 메인-프레임워크 검증 실패("different Team IDs" dyld 거부, 앱 실행 불가). 공증 도입(v1.0+) 전까지 runtime 플래그 없이 서명.
3. **Homebrew 6 변화**: --no-quarantine 플래그 제거(격리 해제는 설치 후 xattr 한 줄로 안내), 서드파티 tap은 brew trust 필수, depends_on macos 문자열 비교 문법 deprecated(:sonoma 심볼).
- 릴리스 산출물 교체 시 3곳 동기화 필수: Release zip(--clobber) + 릴리스 노트 sha256 + cask sha256.

## [3.9] README

제품 README 작성 (기존 하네스 안내는 docs/HARNESS.md로 이동). 검증 포인트: 설치 4줄이 3.8 실증 절차와 자구 일치, 요구사항(Apple Silicon·16GB+·macOS 14+)이 PRD §10-5/6과 일치, 프라이버시 서술이 CLAUDE.md 규칙과 일치, 파이프라인 예시는 골든 테스트 s01 실데이터 기반.

## [3.10] 베타 관찰 로그

- **관찰 1 (2026-07-18)**: `brew tap`에서 `Error: git is unavailable` — 테스터 컴퓨터에 Xcode CLT 부재/파손. **`brew install git`은 해결책이 아님** — brew가 설치 명령 전 자동 갱신에서 git을 먼저 요구하는 닭-달걀(같은 에러 재현 확인). 정도는 `xcode-select --install`, CLT 경로가 있는데도 실패하면 CLT 재설치. README 트러블슈팅 반영(1차 안내 정정 포함). 시사점: "brew만 있으면 된다"는 가정이 깨짐 — CLT 없는/깨진 맥이 실재.
