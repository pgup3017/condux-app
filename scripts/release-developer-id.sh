#!/bin/sh
# Condux 를 Developer ID 로 서명·공증해 앱스토어 밖에서 배포할 수 있는 zip 을 만듭니다.
#
# 준비물 (한 번만):
#   1. Apple Developer Program 가입 (유료). Xcode ▸ Settings ▸ Accounts 에서 로그인.
#   2. Xcode 에서 "Developer ID Application" 인증서 발급 (Accounts ▸ Manage Certificates ▸ +).
#   3. App Store Connect ▸ Users and Access ▸ Keys 에서 App Store Connect API 키 또는
#      https://appleid.apple.com 에서 앱 암호(app-specific password) 를 만들고 아래 명령으로 키체인에 저장:
#        xcrun notarytool store-credentials Condux --apple-id <Apple ID 이메일> --team-id <TEAM_ID>
#      (프로필 이름 Condux. 비밀번호는 이 스크립트에 넣지 않습니다.)
#
# 사용법:  scripts/release-developer-id.sh [버전]   예) scripts/release-developer-id.sh 0.1.0
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
TEAM_ID="${CONDUX_TEAM_ID:?Set CONDUX_TEAM_ID}"
PROFILE="${CONDUX_NOTARY_PROFILE:-Condux}"
OUT="dist/$VERSION"
ARCHIVE="$OUT/Condux.xcarchive"
EXPORT="$OUT/export"
ZIP="$OUT/Condux-$VERSION.zip"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [ -z "$IDENTITY" ]; then
  echo "Developer ID Application 인증서가 없습니다. Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates 에서 발급하세요." >&2
  exit 1
fi
echo "서명 인증서: $IDENTITY"

rm -rf "$OUT"
mkdir -p "$OUT"

# 1) Release 아카이브. 테스트 명령과 달리 여기서는 sandbox 우회 플래그를 쓰지 않습니다.
xcodebuild -project Condux.xcodeproj -scheme Condux -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" PROVISIONING_PROFILE_SPECIFIER= \
  archive

# 2) Developer ID 로 내보내기
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OUT/ExportOptions.plist"

# 3) 공증 (Apple 서버에 업로드해 악성코드 검사) 후 스테이플
ditto -c -k --keepParent "$EXPORT/Condux.app" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$EXPORT/Condux.app"
rm -f "$ZIP"
ditto -c -k --keepParent "$EXPORT/Condux.app" "$ZIP"

# 4) 최종 검사: Gatekeeper 가 받아들이는지
spctl --assess --type execute --verbose=2 "$EXPORT/Condux.app"
echo "완료: $ZIP"
