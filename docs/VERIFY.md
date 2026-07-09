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

## 회귀 주의 — 마이크 무음 3증상
다이얼로그 안 뜸 + 시스템 설정 마이크 목록 부재 + 캡처 전부 0값 → 원인은 **audio-input 엔타이틀먼트 누락**(Hardened Runtime 하 TCC 즉시 거부). `AVCaptureDevice.requestAccess` 명시 호출은 부차. 서명에 엔타이틀먼트 없으면 tccutil reset·requestAccess 다 무효.
