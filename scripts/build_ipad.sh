#!/usr/bin/env bash
# iPad-Build ohne App Store.
#   ./build_ipad.sh run   → baut und installiert direkt auf ein per USB verbundenes iPad
#                           (Signatur: in Xcode einmal Team = "Personal Team" wählen)
#   ./build_ipad.sh ipa   → unsignierte .ipa für SideStore/AltStore (signieren beim Installieren)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
cd "$ROOT/app"
VER="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
[ -d "$ROOT/packages/agent_engine/ios/Frameworks/AgentEngine.xcframework" ] || bash "$ROOT/scripts/build_apple_framework.sh"

case "$MODE" in
  run)
    echo "Verbundene Geräte:"
    flutter devices
    echo
    echo "Starte Release-Build auf dem iPad (Gerät ggf. mit -d <id> wählen) …"
    flutter run --release "${@:2}"
    ;;
  ipa)
    flutter build ios --release --no-codesign
    STAGE="$(mktemp -d)"
    mkdir -p "$STAGE/Payload"
    cp -R build/ios/iphoneos/Runner.app "$STAGE/Payload/"
    mkdir -p "$ROOT/dist"
    OUT="$ROOT/dist/OfflineAgent-$VER-ipad-unsigned.ipa"
    rm -f "$OUT"
    (cd "$STAGE" && zip -qry "$OUT" Payload)
    rm -rf "$STAGE"
    echo "IPA: $OUT  (mit SideStore/AltStore installieren)"
    ;;
  *)
    echo "Aufruf: $0 [run|ipa]"; exit 1;;
esac
