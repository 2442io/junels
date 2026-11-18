#!/usr/bin/env bash
# Einmalige Einrichtung auf dem Mac (oder Linux nur für Android):
#   1. llama.cpp holen   2. Plattform-Ordner erzeugen und anpassen
#   3. Apple-Framework bauen (nur macOS)   4. Abhängigkeiten holen
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v flutter >/dev/null || { echo "Flutter fehlt: https://docs.flutter.dev/get-started/install"; exit 1; }
command -v cmake >/dev/null || echo "Hinweis: CMake fehlt (brew install cmake) – nötig für das Apple-Framework."

bash "$ROOT/scripts/fetch_llama.sh"

cd "$ROOT/app"
PLATFORMS="android"
[ "$(uname)" = "Darwin" ] && PLATFORMS="android,ios,macos"
echo "==> flutter create ($PLATFORMS)"
flutter create --platforms="$PLATFORMS" --org io.t24 --project-name offline_agent --no-pub . > /dev/null

python3 "$ROOT/scripts/patch_platforms.py" "$ROOT/app"
flutter pub get
if [ "$(uname)" = "Darwin" ]; then
  # Podfiles entstehen erst mit pub get → zweiter Durchlauf setzt die Mindestversionen
  python3 "$ROOT/scripts/patch_platforms.py" "$ROOT/app" > /dev/null
  bash "$ROOT/scripts/build_apple_framework.sh"
fi

echo
echo "Einrichtung abgeschlossen. Nächste Schritte:"
echo "  Mac:      scripts/build_macos.sh      → dist/OfflineAgent-*-macos.dmg"
echo "  Android:  scripts/build_android.sh    → dist/OfflineAgent-*-android-arm64.apk"
echo "  iPad:     scripts/build_ipad.sh run   (iPad per USB, Team in Xcode wählen)"
