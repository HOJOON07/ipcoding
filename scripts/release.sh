#!/bin/zsh
# 입코딩 무공증 릴리스 패키징 (태스크 3.8, PLAN — 배포 경로 확정 2026-07-18).
#
# Release 빌드 → ad-hoc 서명(엔타이틀먼트 유지 — 마이크 TCC 필수) → zip + sha256.
# ADP 미가입 경로: 공증 없음. 사용자는 Homebrew tap(--no-quarantine) 또는
# 수동 설치 시 시스템 설정 "그래도 열기"로 실행한다 (README 안내와 일치 유지).
#
# 사용: scripts/release.sh <버전>   예) scripts/release.sh 0.1.0
set -euo pipefail

VERSION="${1:?사용법: release.sh <버전 예:0.1.0>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/IpCoding/IpCoding.xcodeproj"
ENTITLEMENTS="$ROOT/IpCoding/IpCoding.entitlements"
# 빌드·산출물은 리포 밖(iCloud 비동기화 경로)에 둔다 — ~/Desktop은 iCloud Drive 동기화
# 대상이라 파일 프로바이더가 .app에 FinderInfo xattr을 붙여 codesign이 "detritus"로
# 거부한다 (2026-07-18 실측).
BUILD_DIR="$HOME/Library/Caches/ipcoding-release/build"
OUT_DIR="$HOME/Library/Caches/ipcoding-release/dist"
APP="$BUILD_DIR/Build/Products/Release/IpCoding.app"
ZIP="$OUT_DIR/IpCoding-v$VERSION.zip"

echo "▸ Release 빌드 (ad-hoc 서명)"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme IpCoding \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DEVELOPMENT_TEAM="" \
  build | tail -3

echo "▸ 확장 속성 정리 (iCloud FinderInfo 등 — codesign detritus 방어)"
xattr -cr "$APP"

echo "▸ ad-hoc 재서명 (내포 프레임워크 → 앱 순서, 엔타이틀먼트 유지)"
# 내포 xcframework 슬라이스부터 서명해야 앱 서명이 유효하다.
find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -o -name "*.dylib" 2>/dev/null | while read -r nested; do
  codesign --force --sign - --options runtime "$nested"
done
codesign --force --sign - --options runtime \
  --entitlements "$ENTITLEMENTS" "$APP"

echo "▸ 서명 검증"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -q "audio-input" \
  || { echo "✗ 마이크 엔타이틀먼트 소실 — 중단"; exit 1; }
# 배포본에 디버그 엔타이틀먼트 금지 (디버거 부착 허용 — 빌드 러너 발견 2026-07-18).
if codesign -d --entitlements - "$APP" 2>&1 | grep -q "get-task-allow"; then
  echo "✗ get-task-allow 잔존 — 배포 부적합, 중단"; exit 1
fi

echo "▸ zip 패키징 (ditto — 리소스포크·심링크 보존)"
mkdir -p "$OUT_DIR"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo ""
echo "완료:"
echo "  zip:    $ZIP"
echo "  sha256: $SHA   (Homebrew cask에 사용)"
echo "  크기:   $(stat -f %z "$ZIP") bytes"
