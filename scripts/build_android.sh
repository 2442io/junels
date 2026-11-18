#!/usr/bin/env bash
# Baut die Android-APK (arm64) zum direkten Installieren (Sideload).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"
VER="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
flutter build apk --release --target-platform android-arm64
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/OfflineAgent-$VER-android-arm64.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$OUT"
echo
echo "APK: $OUT"
echo "Installieren:  adb install -r \"$OUT\"   oder Datei aufs Gerät kopieren und öffnen."
