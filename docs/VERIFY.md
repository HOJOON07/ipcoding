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
