# 입코딩 (IpCoding)

> 말로 코딩 지시를 내리는 macOS 로컬 음성 입력 — 터미널 AI 에이전트(Claude Code 등)를 위해 만들었습니다.

`⌘+Fn`을 누른 채 말하고, 떼면 **전사 → AI 교정 → 터미널 자동 주입**까지 한 번에 끝납니다.
음성도, 텍스트도, 모델도 전부 기기 안에서만 돕니다 — **네트워크로 나가는 것이 없습니다.**

```
"이 컴포넌트 유즈스테이트 말고 유즈리듀서로 리팩토링해줘"
        │ whisper.cpp (한국어 전사 + 용어 사전)
        ▼
"이 컴포넌트 useState 말고 useReducer로 리팩토링 해줘"
        │ Qwen3.5 9B (군말 제거·용어 교정·문장 정돈)
        ▼
  터미널에 자동 입력 (⌘V 또는 유니코드 직접 입력)
```

## 왜 입코딩인가

- **완전 로컬** — 클라우드 STT/LLM API를 쓰지 않습니다. 발화 원문·교정 결과는 디스크에 저장되지 않고 세션 종료 시 폐기됩니다.
- **교정·정돈 파이프라인** — 받아쓰기가 아니라 *지시문 다듬기*가 목적입니다. "유즈스테이트"→`useState` 같은 기술 용어 교정, "어… 그러니까" 군말 제거를 로컬 LLM이 수행하고, 실패하면 항상 원문으로 폴백합니다(말이 증발하는 일은 없습니다).
- **블루투스 퍼스트** — 에어팟·헤드셋의 16kHz 마이크를 1급 시민으로 취급합니다. 자세 잡고 책상 마이크에 대고 말할 필요가 없습니다.
- **키보드 없는 검토** — 주입 전 원문/교정 비교 HUD, `Tab`(원문 사용)·`Esc`(취소), 주입 후 5초 비교 카드.

## 요구 사항

- Apple Silicon Mac (M1 이상), **메모리 16GB 이상** (교정 LLM 상주 ~6.8GB)
- macOS 14 (Sonoma) 이상

## 설치

### Homebrew (권장)

```sh
brew tap hojoon07/ipcoding
brew trust hojoon07/ipcoding
brew install --cask ipcoding
xattr -dr com.apple.quarantine "/Applications/IpCoding.app"
```

마지막 줄은 Gatekeeper 격리 해제입니다 — 입코딩은 공증되지 않은 오픈소스 앱(ad-hoc 서명)이라, 해제하지 않으면 첫 실행이 차단된 뒤 **시스템 설정 > 개인정보 보호 및 보안 > "그래도 열기"**로 실행해야 합니다.

업데이트는 `brew upgrade --cask ipcoding`.

### 수동 설치

[Releases](https://github.com/HOJOON07/ipcoding/releases)에서 zip을 받아 `/Applications`에 옮긴 뒤, 위와 동일하게 격리 해제(또는 "그래도 열기")가 필요합니다.

## 첫 실행

온보딩이 순서대로 안내합니다:

1. **마이크 권한** — 전사에 필요
2. **손쉬운 사용 권한** — `⌘+Fn` 핫키 감지와 텍스트 주입(⌘V)에 필요
3. **AI 모델 다운로드 (약 6GB)** — Whisper large-v3-turbo + Qwen3.5 9B. 중단해도 이어받고, sha256 검증을 통과한 파일만 사용됩니다.

## 사용법

| 조작 | 동작 |
|---|---|
| `⌘+Fn` 누른 채 말하기 | 녹음 (화면 우상단 오브가 목소리에 반응) |
| 키에서 손 떼기 | 전사 → 교정 → 0.5초 후 자동 주입 |
| `Tab` (완성 카드 중) | 교정 대신 **원문** 주입 |
| `Esc` | 취소 |

- **사전 편집** (메뉴바 → 사전 편집…): "들리는 대로 → 원하는 표기" 치환 쌍 관리. 오인식을 발견하면 그 자리에서 등록 — 다음 발화부터 바로 반영됩니다.
- **설정** (메뉴바 → 설정…, 또는 Spotlight에서 IpCoding 재실행): 핫키(⌘/⌥/⌃+Fn), 입력 장치 고정, 자동 주입 대기, 교정 타임아웃, 주입 방식(클립보드/유니코드 직접 입력), 모델 관리.

## 프라이버시

- 음성 버퍼는 메모리에만 존재하고 세션 종료 시 폐기됩니다. 전사·교정 텍스트도 디스크에 기록하지 않습니다.
- 네트워크 사용은 **최초 모델 다운로드(Hugging Face)가 유일**합니다.
- 클립보드 주입 시 기존 클립보드를 백업·복원합니다. 클립보드를 아예 건드리기 싫다면 설정에서 "유니코드 직접 입력"을 선택하세요.

## 아키텍처

Swift 메뉴바 앱 + [whisper.cpp](https://github.com/ggerganov/whisper.cpp)(STT) + [llama.cpp](https://github.com/ggml-org/llama.cpp)(교정 LLM, 공유 ggml 단일 링크). 설계 문서는 [`docs/`](docs/)에 있습니다 — [PRD](docs/PRD.md) · [기술설계서](docs/TDD.md) · [구현계획](docs/PLAN.md) · [검증 기록](docs/VERIFY.md).

모델 선정과 교정 프롬프트는 자체 벤치마크([`ipcoding-bench/`](ipcoding-bench/))로 확정했고, 파이프라인 회귀는 골든 테스트(30문장 스냅샷)로 잠급니다.

## 소스 빌드

```sh
git clone https://github.com/HOJOON07/ipcoding.git
# Xcode 26+로 IpCoding/IpCoding.xcodeproj 빌드
# 엔진 xcframework 재생성: scripts/build-engine.sh · 릴리스 패키징: scripts/release.sh
```

주의: 프로젝트를 iCloud Drive 동기화 폴더(데스크탑·문서)에 두면 서명 단계가 실패할 수 있습니다 — 릴리스 패키징은 `scripts/release.sh`가 비동기화 경로에서 수행합니다.

## 상태

**v0.1.x 베타.** 자동 업데이트(Sparkle)와 공증은 v1.0에서 재검토 예정 — 그 전까지 업데이트는 `brew upgrade`입니다. 개발 하네스(Claude Code 에이전트 구성)는 [`docs/HARNESS.md`](docs/HARNESS.md) 참조.

## 라이선스

[MIT](LICENSE)
