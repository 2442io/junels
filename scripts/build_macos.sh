#!/usr/bin/env bash
# Baut die macOS-App und verpackt sie als .dmg.
# Optional: DEVELOPER_ID="Developer ID Application: Name (TEAMID)" für Signatur,
#           NOTARY_PROFILE=<notarytool-Profil> für Notarisierung.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"
VER="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
[ -d "$ROOT/packages/agent_engine/macos/Frameworks/AgentEngine.xcframework" ] || bash "$ROOT/scripts/build_apple_framework.sh"

flutter build macos --release
APP="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "App nicht gefunden"; exit 1; }

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> Signiere mit $DEVELOPER_ID"
  codesign --force --deep --options runtime --timestamp \
    --entitlements macos/Runner/Release.entitlements -s "$DEVELOPER_ID" "$APP"
fi

if [ -z "${DEVELOPER_ID:-}" ] && [ -n "${MAC_SIGN_IDENTITY:-}" ]; then
  # eigenes (selbst signiertes) Zertifikat: gleiche Signatur bei jedem Build,
  # damit macOS den App-Container (Modelle, Chats) der neuen Version zuordnet
  echo "==> Signiere mit $MAC_SIGN_IDENTITY"
  find "$APP/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) | while read -r f; do
    codesign --force --sign "$MAC_SIGN_IDENTITY" "$f"
  done
  codesign --force --sign "$MAC_SIGN_IDENTITY" --entitlements macos/Runner/Release.entitlements "$APP"
  codesign --verify --verbose "$APP" || echo "Warnung: Signaturprüfung meldet Probleme"
  codesign -d -r- "$APP" 2>&1 | tail -1
fi

mkdir -p "$ROOT/dist"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
DMG="$ROOT/dist/OfflineAgent-$VER-macos.dmg"
rm -f "$DMG"
hdiutil create -volname "Offline Agent" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarisiere"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo
echo "DMG: $DMG"
if [ -z "${DEVELOPER_ID:-}" ]; then
  echo "Hinweis: ohne Developer-ID ad-hoc signiert. Auf einem anderen Mac beim ersten Start"
  echo "Rechtsklick → Öffnen bzw. Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen."
fi
