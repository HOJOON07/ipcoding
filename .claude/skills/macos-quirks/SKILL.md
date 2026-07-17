---
name: macos-quirks
description: 입코딩이 쓰는 macOS 저수준 API들의 알려진 함정과 검증된 대응 패턴. CGEventTap, NSPanel HUD, NSPasteboard 복원, CGEvent 유니코드 주입, TCC 권한, 블루투스 HFP 관련 코드를 작성·리뷰·디버깅할 때 참조.
---

# macOS 함정 모음 (입코딩)

각 항목은 "증상 → 원인 → 대응"으로 읽는다. 여기 없는 API 의문은 macos-api-researcher에게 조사시킬 것.

## CGEventTap
- **탭이 어느 순간 조용히 죽음** → 콜백이 느리면 시스템이 `kCGEventTapDisabledByTimeout`으로 비활성화 → 콜백에서 해당 이벤트 타입을 감지해 `CGEvent.tapEnable` 즉시 재호출. 콜백 안에서 무거운 작업 금지(이벤트만 코디네이터로 던지고 리턴).
- **⌘+Fn 감지**: 둘 다 modifier라 `keyDown`이 아닌 `flagsChanged`로 온다. `flags.contains(.maskCommand) && flags.contains(.maskSecondaryFn)`의 상승/하강 엣지를 직접 추적해야 함.
- **Tab/Esc 소비**: 콜백에서 `nil`을 반환하면 이벤트가 소비된다. 반드시 "HUD 표시 중" 조건으로 한정 — 조건 실수 시 시스템 전체의 Tab/Esc가 죽는 사고가 난다. 개발 중엔 소비 대신 로그만 찍는 플래그를 두고 마지막에 켤 것.
- 소비형(.defaultTap) 탭의 키 이벤트 수신·CGEvent post는 손쉬운 사용(Accessibility)으로 게이트 (입력 모니터링은 listen-only 탭 전용이며 수동 토글 시 앱 재시작 요구 — TDD §4 각주, 2026-07 조사). 권한 판정은 `AXIsProcessTrusted()` 기준 — `CGEvent.tapCreate` nil은 빈 마스크의 결과라 부분 실패 가능성이 있어 판정 신호로 쓰지 않는다.

## NSPanel (HUD)
- non-activating이어야 함: `styleMask`에 `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded = true`, **어디서도 `makeKey*` 호출 금지**. HUD가 포커스를 얻는 순간 frontmost가 바뀌어 주입 대상이 사라진다.
- 전체화면 앱 위에 띄우려면 `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `level = .statusBar`.
- 멀티모니터: `NSScreen.main`은 key window 기준이라 부적합 — 마우스 위치(`NSEvent.mouseLocation`)가 속한 스크린을 찾을 것.

## NSPasteboard (클립보드 주입)
- 백업은 문자열만이 아니라 아이템 단위로: 이미지·파일 복사 상태를 문자열 복원으로 덮으면 사용자 데이터 손실.
- `changeCount`를 set 직전에 기록하고, 복원 시점에 changeCount가 예상값+1이 아니면(그 사이 사용자가 복사함) 복원을 포기한다.
- ⌘V 이벤트 post 후 대상 앱이 읽을 시간이 필요 — 복원까지 250ms 안팎 지연. 너무 짧으면 빈 붙여넣기, 너무 길면 사용자 복사와 충돌.
- 터미널의 bracketed paste 모드에서는 붙여넣기가 특수 시퀀스로 감싸진다 — 개행 포함 텍스트가 즉시 실행되지 않는 것이 정상이며 오히려 안전.

## CGEvent 유니코드 주입
- `CGEventKeyboardSetUnicodeString`은 이벤트당 실을 수 있는 길이가 짧다(UTF-16 20단위 안팎이 안전선) → 청크 분할 + 청크 간 1ms 대기.
- 완성형 한글 문자열은 IME 조합을 거치지 않고 들어간다 — 조합 중 상태(한글 IME 활성 + 미완성 글자)가 대상 앱에 있으면 결과가 오염될 수 있으니, 주입 전 짧은 지연으로 조합 마감 여유를 줄 것.

## TCC (권한)
- 개발 중 서명 identity가 바뀌면(재빌드 포함) 손쉬운 사용 권한이 풀린 것처럼 보일 수 있다. 디버깅용 리셋: `tccutil reset Accessibility <bundle-id>` / `tccutil reset Microphone <bundle-id>`.
- 권한 상태 확인: 손쉬운 사용은 `AXIsProcessTrusted()`. 다이얼로그 유도는 `AXIsProcessTrustedWithOptions`에 prompt 옵션.
- 권한은 앱이 켜진 동안 부여돼도 이벤트 탭 재생성 전까지 반영 안 될 수 있음 → 온보딩에서 부여 감지 시 탭 재생성.

## 오디오 / 블루투스
- 마이크 사용 시작 시 BT 헤드셋이 A2DP→HFP로 전환되어 재생 음질이 떨어지는 것은 정상 동작. 입코딩은 PTT라 발화 중에만 발생 — 버그로 오인하지 말 것.
- HFP의 16kHz는 Whisper 입력 규격과 일치. "고음질 마이크로 바꿔야 인식이 좋아진다"는 가정으로 시간 쓰지 말 것.
- AVAudioEngine 입력 탭은 장치 네이티브 포맷으로 받고 AVAudioConverter로 16kHz mono Float32 변환. 장치가 세션 중 바뀌면(BT 연결 해제) 엔진이 멈출 수 있음 — configuration change 노티 구독.

## 기타
- 메뉴바 전용 앱: Info.plist `LSUIElement = YES` (Dock/⌘Tab에서 숨김).
- 이벤트 탭·글로벌 주입은 Mac App Store 샌드박스와 양립 불가 — 샌드박스 활성화하지 말 것 (배포는 Developer ID + 공증).
