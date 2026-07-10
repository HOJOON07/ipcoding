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

## 회귀 주의 — 마이크 무음 3증상
다이얼로그 안 뜸 + 시스템 설정 마이크 목록 부재 + 캡처 전부 0값 → 원인은 **audio-input 엔타이틀먼트 누락**(Hardened Runtime 하 TCC 즉시 거부). `AVCaptureDevice.requestAccess` 명시 호출은 부차. 서명에 엔타이틀먼트 없으면 tccutil reset·requestAccess 다 무효.
