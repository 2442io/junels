#!/usr/bin/env python3
"""Passt die von `flutter create` erzeugten Plattform-Ordner an die SRS an.

Idempotent: kann beliebig oft laufen.
  python3 scripts/patch_platforms.py app/
"""
import os
import plistlib
import re
import shutil
import sys
from pathlib import Path

APP = Path(sys.argv[1] if len(sys.argv) > 1 else "app").resolve()
ROOT = APP.parent
DISPLAY_NAME = "Offline Agent"
IOS_MIN = "16.0"
MAC_MIN = "12.0"


def log(msg):
    print(f"  · {msg}")


def edit(path: Path, fn):
    if not path.exists():
        log(f"übersprungen (fehlt): {path.relative_to(APP)}")
        return
    old = path.read_text()
    new = fn(old)
    if new != old:
        path.write_text(new)
        log(f"angepasst: {path.relative_to(APP)}")


def edit_plist(path: Path, fn):
    if not path.exists():
        log(f"übersprungen (fehlt): {path.relative_to(APP)}")
        return
    with path.open("rb") as f:
        data = plistlib.load(f)
    fn(data)
    with path.open("wb") as f:
        plistlib.dump(data, f)
    log(f"angepasst: {path.relative_to(APP)}")


# --------------------------------------------------------------------- Android

def patch_android():
    android = APP / "android"
    if not android.exists():
        return
    print("Android")

    def manifest(s):
        if "xmlns:tools" not in s:
            s = s.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
        # v1.0 hatte INTERNET entfernt – ab v1.1 nur nach Nutzerfreigabe erlaubt
        s = re.sub(r'\s*<!-- 100 % offline[^>]*-->', "", s)
        s = re.sub(r'\s*<uses-permission android:name="android.permission.INTERNET" tools:node="remove" />', "", s)
        perms = [
            ("android.permission.INTERNET", "Modell-Downloads und Websuche (nur nach Freigabe)"),
            ("android.permission.RECORD_AUDIO", "Spracheingabe mit Whisper (lokal)"),
            ("android.permission.FOREGROUND_SERVICE", "Agent arbeitet im Hintergrund weiter"),
            ("android.permission.FOREGROUND_SERVICE_DATA_SYNC", "Agent/Downloads im Hintergrund"),
            ("android.permission.WAKE_LOCK", "CPU wach halten, solange der Agent rechnet"),
            ("android.permission.POST_NOTIFICATIONS", "Hinweis, dass der Agent im Hintergrund arbeitet"),
            ("android.permission.USE_EXACT_ALARM", "Geplante Prompts pünktlich starten"),
            ("android.permission.RECEIVE_BOOT_COMPLETED", "Geplante Prompts nach Neustart wieder einplanen"),
        ]
        for name, why in perms:
            if f'android:name="{name}"' not in s:
                s = re.sub(r"(<manifest[^>]*>)",
                           rf'\1\n    <!-- {why} -->\n    <uses-permission android:name="{name}" />', s, count=1)
        s = re.sub(r'android:label="[^"]*"', f'android:label="{DISPLAY_NAME}"', s, count=1)
        if "android:largeHeap" not in s:
            s = s.replace("<application", '<application\n        android:largeHeap="true"', 1)
        if "androidx.core.content.FileProvider" not in s:
            s = s.replace("</application>",
                          '    <provider android:name="androidx.core.content.FileProvider"\n'
                          '            android:authorities="${applicationId}.files" android:exported="false"\n'
                          '            android:grantUriPermissions="true">\n'
                          '            <meta-data android:name="android.support.FILE_PROVIDER_PATHS"\n'
                          '                android:resource="@xml/junels_file_paths" />\n'
                          '        </provider>\n    </application>', 1)
        if "SCHEDULE_EXACT_ALARM" not in s:
            s = re.sub(r"(<manifest[^>]*>)", r'\1\n    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32" />', s, count=1)
        if ".AlarmReceiver" not in s:
            s = s.replace("</application>",
                          '    <receiver android:name=".AlarmReceiver" android:exported="true">\n'
                          '            <intent-filter>\n'
                          '                <action android:name="android.intent.action.BOOT_COMPLETED" />\n'
                          '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />\n'
                          '            </intent-filter>\n'
                          '        </receiver>\n    </application>', 1)
        if ".AgentService" not in s:
            s = s.replace("</application>",
                          '    <service android:name=".AgentService" android:exported="false"\n'
                          '            android:foregroundServiceType="dataSync" />\n    </application>', 1)
        return s

    edit(android / "app/src/main/AndroidManifest.xml", manifest)

    res = android / "app/src/main/res/xml"
    res.mkdir(parents=True, exist_ok=True)
    (res / "junels_file_paths.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<paths>\n    <cache-path name="shared" path="shared/" />\n</paths>\n')
    # optionale JPEG2000-Klassen von PDFBox fehlen absichtlich
    (android / "app/proguard-rules.pro").write_text(
        "-dontwarn com.gemalto.jp2.**\n-keep class com.tom_roush.pdfbox.** { *; }\n-keep class com.tom_roush.fontbox.** { *; }\n")

    # Hintergrunddienst: MainActivity (MethodChannel) + AgentService ersetzen die Vorlage
    src = ROOT / "scripts/android"
    for kt in sorted(android.glob("app/src/main/kotlin/**/MainActivity.kt")):
        pkg = re.search(r"^package\s+([\w.]+)", kt.read_text(), re.M).group(1)
        for name in ("MainActivity.kt", "AgentService.kt", "JunelsNative.kt", "AlarmReceiver.kt"):
            (kt.parent / name).write_text((src / name).read_text().replace("__PACKAGE__", pkg))
        log(f"Hintergrunddienst eingesetzt ({pkg})")

    def gradle_kts(s):
        s = s.replace('abiFilters += listOf("arm64-v8a", "x86_64")', 'abiFilters += listOf("arm64-v8a")')
        if "abiFilters" not in s:
            s = re.sub(r"(defaultConfig\s*\{)",
                       r'\1\n        ndk { abiFilters += listOf("arm64-v8a") }', s, count=1)
        if "JUNELS_KEYSTORE" not in s:
            # fester Release-Schlüssel aus dem CI (Secret), sonst wie bisher der Debug-Schlüssel
            s = s.replace("    buildTypes {", '''    signingConfigs {
        create("release") {
            val ks = System.getenv("JUNELS_KEYSTORE")
            if (ks != null && file(ks).exists()) {
                storeFile = file(ks)
                storePassword = System.getenv("JUNELS_KEY_PASSWORD")
                keyAlias = "junels"
                keyPassword = System.getenv("JUNELS_KEY_PASSWORD")
            }
        }
    }

    buildTypes {''', 1)
            s = s.replace('signingConfig = signingConfigs.getByName("debug")',
                          'signingConfig = if (System.getenv("JUNELS_KEYSTORE") != null) '
                          'signingConfigs.getByName("release") else signingConfigs.getByName("debug")', 1)
        if "pdfbox-android" not in s:
            s += '''
// PDF-Text lesen (Apache PDFBox) und Dateien teilen (FileProvider)
dependencies {
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    implementation("androidx.core:core:1.13.1")
}
'''
        return s

    edit(android / "app/build.gradle.kts", gradle_kts)

    def gradle_groovy(s):
        if "abiFilters" not in s:
            s = re.sub(r"(defaultConfig\s*\{)", r'\1\n        ndk { abiFilters "arm64-v8a" }', s, count=1)
        return s

    edit(android / "app/build.gradle", gradle_groovy)

    # AGP-Version des Plugins an die App angleichen
    agp = None
    for name in ("settings.gradle.kts", "settings.gradle"):
        f = android / name
        if f.exists():
            m = re.search(r'com\.android\.application["\')]*\s*version\s*["\']([\d.]+)', f.read_text())
            if m:
                agp = m.group(1)
    if agp:
        plugin = ROOT / "packages/agent_engine/android/build.gradle"
        edit(plugin, lambda s: re.sub(r'com\.android\.tools\.build:gradle:[\d.]+',
                                      f"com.android.tools.build:gradle:{agp}", s))
        log(f"AGP-Version {agp}")


# ------------------------------------------------------------------------- iOS

def patch_ios():
    ios = APP / "ios"
    if not ios.exists():
        return
    print("iPadOS")

    def info(d):
        d["CFBundleDisplayName"] = DISPLAY_NAME
        # Modelle über Finder/Dateien-App in den App-Ordner legen können
        d["UIFileSharingEnabled"] = True
        d["LSSupportsOpeningDocumentsInPlace"] = True
        d["NSMicrophoneUsageDescription"] = "Für die Spracheingabe. Die Erkennung läuft lokal auf dem Gerät."
        d.pop("NSAppTransportSecurity", None)

    edit_plist(ios / "Runner/Info.plist", info)

    ent = ios / "Runner/Runner.entitlements"
    data = {}
    if ent.exists():
        with ent.open("rb") as f:
            data = plistlib.load(f)
    # Ohne diese Berechtigung beendet iPadOS die App bei 3B-Modellen
    data["com.apple.developer.kernel.increased-memory-limit"] = True
    with ent.open("wb") as f:
        plistlib.dump(data, f)
    log("Runner.entitlements: increased-memory-limit")

    def pbx(s):
        s = re.sub(r'TARGETED_DEVICE_FAMILY = "?[\d,]+"?;', "TARGETED_DEVICE_FAMILY = 2;", s)  # nur iPad
        s = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;", f"IPHONEOS_DEPLOYMENT_TARGET = {IOS_MIN};", s)
        if "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;" not in s:
            s = s.replace("INFOPLIST_FILE = Runner/Info.plist;",
                          "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\n\t\t\t\tINFOPLIST_FILE = Runner/Info.plist;")
        return s

    edit(ios / "Runner.xcodeproj/project.pbxproj", pbx)
    patch_podfile(ios / "Podfile", "ios", IOS_MIN)


# ----------------------------------------------------------------------- macOS

def patch_macos():
    mac = APP / "macos"
    if not mac.exists():
        return
    print("macOS")

    def app_delegate(s):
        # Fenster schließen beendet die App nicht (geplante Prompts laufen weiter);
        # Klick aufs Dock-Symbol öffnet das Fenster wieder
        if "applicationShouldHandleReopen" not in s:
            s = re.sub(r"(applicationShouldTerminateAfterLastWindowClosed\(_ sender: NSApplication\) -> Bool \{\s*return )true",
                       r"\1false", s, count=1)
            i = s.rfind("}")
            s = s[:i] + '''
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { mainFlutterWindow?.makeKeyAndOrderFront(nil) }
    return true
  }
''' + s[i:]
        if "_exit(0)" in s:
            return s
        hook = '''
  // Beim Beenden räumen llama.cpp/Metal in statischen Destruktoren auf und können dabei
  // abstürzen ("App wurde unerwartet beendet"). Alles ist bereits gespeichert →
  // Prozess direkt beenden, ohne diese Aufräumphase.
  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { _ in Darwin._exit(0) }
  }
'''
        i = s.rfind("}")
        return s[:i] + hook + s[i:]

    edit(mac / "Runner/AppDelegate.swift", app_delegate)

    def main_window(s):
        if "JunelsFiles" in s:
            return s
        s = s.replace("import FlutterMacOS", "import FlutterMacOS\nimport PDFKit", 1)
        s = re.sub(r"(RegisterGeneratedPlugins\(registry: flutterViewController\))",
                   r"\1\n    JunelsFiles.register(flutterViewController)\n    self.isReleasedWhenClosed = false", s, count=1)
        s = s.replace("import PDFKit", "import PDFKit\nimport UserNotifications", 1)
        return s + (ROOT / "scripts/macos/JunelsFiles.swift").read_text()

    edit(mac / "Runner/MainFlutterWindow.swift", main_window)
    def common(d):
        d["com.apple.security.app-sandbox"] = True
        d["com.apple.security.files.user-selected.read-write"] = True
        # ausgehende Verbindungen: Modell-Downloads und Websuche, nur nach Freigabe in der App
        d["com.apple.security.network.client"] = True
        d["com.apple.security.device.audio-input"] = True

    def release(d):
        common(d)
        d.pop("com.apple.security.network.server", None)

    edit_plist(mac / "Runner/Release.entitlements", release)
    edit_plist(mac / "Runner/DebugProfile.entitlements", common)  # network.server bleibt für Hot Reload

    def mac_info(d):
        d["NSMicrophoneUsageDescription"] = "Für die Spracheingabe. Die Erkennung läuft lokal auf dem Mac."

    edit_plist(mac / "Runner/Info.plist", mac_info)
    edit(mac / "Runner/Configs/AppInfo.xcconfig",
         lambda s: re.sub(r"PRODUCT_NAME = .*", f"PRODUCT_NAME = {DISPLAY_NAME}", s))
    edit(mac / "Runner.xcodeproj/project.pbxproj",
         lambda s: re.sub(r"MACOSX_DEPLOYMENT_TARGET = [\d.]+;", f"MACOSX_DEPLOYMENT_TARGET = {MAC_MIN};", s))
    patch_podfile(mac / "Podfile", "osx", MAC_MIN)


def patch_podfile(path: Path, plat: str, version: str):
    def fn(s):
        line = f"platform :{plat}, '{version}'"
        s2 = re.sub(rf"^#?\s*platform :{plat}, '[\d.]+'", line, s, flags=re.M)
        if line not in s2:
            s2 = line + "\n" + s2
        return s2

    if not path.exists():
        # Podfile aus der Flutter-Vorlage anlegen, damit die Mindestversion vor dem ersten Build stimmt
        tpl = flutter_template(f"cocoapods/Podfile-{'ios' if plat == 'ios' else 'macos'}")
        if tpl:
            shutil.copy(tpl, path)
            log(f"{path.relative_to(APP)} aus Flutter-Vorlage angelegt")
    if path.exists():
        edit(path, fn)
    else:
        log(f"{path.relative_to(APP)} fehlt – nach dem ersten Build Skript erneut ausführen")


def flutter_template(rel: str):
    root = os.environ.get("FLUTTER_ROOT")
    if not root:
        exe = shutil.which("flutter")
        if exe:
            root = str(Path(os.path.realpath(exe)).parent.parent)
    if not root:
        return None
    p = Path(root) / "packages/flutter_tools/templates" / rel
    return p if p.exists() else None


if __name__ == "__main__":
    print(f"Patche {APP}")
    patch_android()
    patch_ios()
    patch_macos()
    widget_test = APP / "test/widget_test.dart"
    if widget_test.exists() and "MyApp" in widget_test.read_text():
        widget_test.unlink()
        log("test/widget_test.dart (Vorlage) entfernt")
    print("Fertig.")
