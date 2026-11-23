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


NOTIFY_ICONS = {
    'aktion': 'M9,11.24V7.5C9,6.12 10.12,5 11.5,5S14,6.12 14,7.5v3.74c1.21,-0.81 2,-2.18 2,-3.74C16,5.01 13.99,3 11.5,3S7,5.01 7,7.5C7,9.06 7.79,10.43 9,11.24zM18.84,15.87l-4.54,-2.26c-0.17,-0.07 -0.35,-0.11 -0.54,-0.11H13v-6C13,6.67 12.33,6 11.5,6S10,6.67 10,7.5v10.74c-3.6,-0.76 -3.54,-0.75 -3.67,-0.75c-0.31,0 -0.59,0.13 -0.79,0.33l-0.79,0.8l4.94,4.94C9.96,23.83 10.34,24 10.75,24h6.79c0.75,0 1.33,-0.55 1.44,-1.28l0.75,-5.27c0.01,-0.07 0.02,-0.14 0.02,-0.2C19.75,16.63 19.37,16.09 18.84,15.87z',
    'warnung': 'M1,21h22L12,2 1,21zM13,18h-2v-2h2v2zM13,14h-2v-4h2v4z',
    'erinnerung': 'M22,5.72l-4.6,-3.86 -1.29,1.53 4.6,3.86L22,5.72zM7.88,3.39L6.6,1.86 2,5.71l1.29,1.53 4.59,-3.85zM12.5,8H11v6l4.75,2.85 0.75,-1.23 -4,-2.37V8zM12,4c-4.97,0 -9,4.03 -9,9s4.02,9 9,9c4.97,0 9,-4.03 9,-9s-4.03,-9 -9,-9zM12,20c-3.87,0 -7,-3.13 -7,-7s3.13,-7 7,-7 7,3.13 7,7 -3.13,7 -7,7z',
    'ergebnis': 'M12,2C6.48,2 2,6.48 2,12s4.48,10 10,10 10,-4.48 10,-10S17.52,2 12,2zM10,17l-5,-5 1.41,-1.41L10,14.17l7.59,-7.59L19,8l-9,9z',
    'info': 'M12,2C6.48,2 2,6.48 2,12s4.48,10 10,10 10,-4.48 10,-10S17.52,2 12,2zM13,17h-2v-6h2v6zM13,9h-2L11,7h2v2z',
    'ruhig': 'M12,4V1L8,5l4,4V6c3.31,0 6,2.69 6,6 0,1.01 -0.25,1.97 -0.7,2.8l1.46,1.46C19.54,15.03 20,13.57 20,12c0,-4.42 -3.58,-8 -8,-8zM12,18c-3.31,0 -6,-2.69 -6,-6 0,-1.01 0.25,-1.97 0.7,-2.8L5.24,7.74C4.46,8.97 4,10.43 4,12c0,4.42 3.58,8 8,8v3l4,-4 -4,-4v3z',
}

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

def _widget_resources(res: Path):
    """Startbildschirm-Widget: Layout, Hintergrund, Beschreibung."""
    for d in ("layout", "drawable", "xml"):
        (res / d).mkdir(parents=True, exist_ok=True)
    # Symbole der Benachrichtigungs-Arten (Aktion, Warnung, Erinnerung, Ergebnis, Info, Ruhig)
    for kind, path_data in NOTIFY_ICONS.items():
        (res / f"drawable/junels_n_{kind}.xml").write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="24dp" android:height="24dp" '
            'android:viewportWidth="24" android:viewportHeight="24">'
            f'<path android:fillColor="#FFFFFFFF" android:pathData="{path_data}"/></vector>\n')
    (res / "raw").mkdir(parents=True, exist_ok=True)
    (res / "raw/junels_keep.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="@drawable/junels_n_*" />\n')
    (res / "drawable/junels_widget_bg.xml").write_text('''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="#F21C2024" />
    <corners android:radius="28dp" />
</shape>
''')
    (res / "drawable/junels_widget_mic_bg.xml").write_text('''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="oval">
    <solid android:color="#FF7FD1A8" />
</shape>
''')
    (res / "layout/junels_widget.xml").write_text('''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="horizontal"
    android:gravity="center_vertical"
    android:padding="6dp"
    android:background="@drawable/junels_widget_bg">
    <TextView
        android:id="@+id/junels_widget_ask"
        android:layout_width="0dp"
        android:layout_height="match_parent"
        android:layout_weight="1"
        android:gravity="center_vertical"
        android:paddingStart="16dp"
        android:paddingEnd="8dp"
        android:text="Frag Junels …"
        android:textColor="#CCFFFFFF"
        android:textSize="16sp" />
    <ImageView
        android:id="@+id/junels_widget_mic"
        android:layout_width="44dp"
        android:layout_height="44dp"
        android:padding="10dp"
        android:background="@drawable/junels_widget_mic_bg"
        android:contentDescription="Gespräch starten"
        android:src="@android:drawable/ic_btn_speak_now" />
</LinearLayout>
''')
    (res / "xml/junels_widget_info.xml").write_text('''<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="250dp"
    android:minHeight="40dp"
    android:targetCellWidth="4"
    android:targetCellHeight="1"
    android:resizeMode="horizontal"
    android:widgetCategory="home_screen"
    android:updatePeriodMillis="0"
    android:initialLayout="@layout/junels_widget"
    android:description="@string/junels_widget_desc" />
''')
    values = res / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "junels_strings.xml").write_text('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="junels_widget_desc">Neuen Chat öffnen oder per Mikrofon ein Gespräch starten</string>
</resources>
''')


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
            ("android.permission.ACCESS_NETWORK_STATE", "Erkennen, ob das Gerät offline ist (ohne selbst etwas zu senden)"),
            ("android.permission.RECORD_AUDIO", "Spracheingabe mit Whisper (lokal)"),
            ("android.permission.FOREGROUND_SERVICE", "Agent arbeitet im Hintergrund weiter"),
            ("android.permission.FOREGROUND_SERVICE_DATA_SYNC", "Agent/Downloads im Hintergrund"),
            ("android.permission.WAKE_LOCK", "CPU wach halten, solange der Agent rechnet"),
            ("android.permission.POST_NOTIFICATIONS", "Hinweis, dass der Agent im Hintergrund arbeitet"),
            ("android.permission.USE_EXACT_ALARM", "Geplante Prompts pünktlich starten"),
            ("android.permission.RECEIVE_BOOT_COMPLETED", "Geplante Prompts nach Neustart wieder einplanen"),
            ("android.permission.REQUEST_INSTALL_PACKAGES", "Updates direkt in der App installieren"),
            ("android.permission.READ_CALENDAR", "Termine vorlesen (nur auf Nachfrage)"),
            ("android.permission.READ_CONTACTS", "Empfänger für E-Mail, WhatsApp und Anrufe finden"),
        ]
        for name, why in perms:
            if f'android:name="{name}"' not in s:
                s = re.sub(r"(<manifest[^>]*>)",
                           rf'\1\n    <!-- {why} -->\n    <uses-permission android:name="{name}" />', s, count=1)
        s = re.sub(r'android:label="[^"]*"', f'android:label="{DISPLAY_NAME}"', s, count=1)
        if "usesCleartextTraffic" not in s:
            # MCP-Server im eigenen Netz laufen oft über http://
            s = s.replace("<application", '<application\n        android:usesCleartextTraffic="true"', 1)
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
        if "android.intent.action.SEND" not in s:
            # Teilen an Junels: Text, Links, Fotos, PDFs aus anderen Apps
            share = ('''
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="text/*" />
                <data android:mimeType="image/*" />
                <data android:mimeType="application/pdf" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="image/*" />
                <data android:mimeType="application/pdf" />
            </intent-filter>''')
            m = re.search(r'(<activity[^>]*android:name="\.MainActivity".*?</intent-filter>)', s, re.S)
            if m:
                s = s[:m.end()] + share + s[m.end():]
        if 'android:scheme="junels"' not in s:
            # App-Links junels://… (z. B. Rücksprung nach der SSO-Anmeldung) → MainActivity
            link = ('\n            <intent-filter>\n'
                    '                <action android:name="android.intent.action.VIEW" />\n'
                    '                <category android:name="android.intent.category.DEFAULT" />\n'
                    '                <category android:name="android.intent.category.BROWSABLE" />\n'
                    '                <data android:scheme="junels" />\n'
                    '            </intent-filter>')
            m = re.search(r'(<activity[^>]*android:name="\.MainActivity".*?</intent-filter>)', s, re.S)
            if m:
                s = s[:m.end()] + link + s[m.end():]
        if "junels-queries" not in s:
            # Apps finden und öffnen (Freigabeliste „Apps steuern“), Links in Apps öffnen.
            # Flutter legt selbst schon <queries> (PROCESS_TEXT) an – darum hineinschreiben statt nur neu anlegen.
            ours = ('        <!-- junels-queries -->\n'
                    '        <intent><action android:name="android.intent.action.MAIN" /><category android:name="android.intent.category.LAUNCHER" /></intent>\n'
                    '        <intent><action android:name="android.intent.action.VIEW" /><data android:scheme="https" /></intent>\n'
                    '        <intent><action android:name="android.intent.action.VIEW" /><data android:scheme="spotify" /></intent>\n'
                    '        <package android:name="com.spotify.music" />\n')
            if "<queries>" in s:
                s = s.replace("<queries>", "<queries>\n" + ours, 1)
            else:
                s = s.replace("<application", "<queries>\n" + ours + "    </queries>\n    <application", 1)
        if ".JunelsWidget" not in s:
            s = s.replace("</application>",
                          '    <receiver android:name=".JunelsWidget" android:exported="false" android:label="Frag Junels">\n'
                          '            <intent-filter>\n'
                          '                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />\n'
                          '            </intent-filter>\n'
                          '            <meta-data android:name="android.appwidget.provider" android:resource="@xml/junels_widget_info" />\n'
                          '        </receiver>\n    </application>', 1)
        if ".AgentService" not in s:
            s = s.replace("</application>",
                          '    <service android:name=".AgentService" android:exported="false"\n'
                          '            android:foregroundServiceType="dataSync" />\n    </application>', 1)
        return s

    edit(android / "app/src/main/AndroidManifest.xml", manifest)

    res = android / "app/src/main/res/xml"
    _widget_resources(android / "app/src/main/res")
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
        for name in ("MainActivity.kt", "AgentService.kt", "JunelsNative.kt", "AlarmReceiver.kt", "JunelsDevice.kt", "JunelsWidget.kt"):
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

    # Lint der Plugins beim Release-Build abschalten (stürzt bei webview_flutter_android ab)
    def root_kts(s):
        if "lintVital" not in s:
            s += '''
// Release-Lint der Plugins überspringen (Lint-Absturz in generiertem Plugin-Code)
subprojects {
    tasks.matching { it.name.startsWith("lintVital") }.configureEach { enabled = false }
}
'''
        return s

    def root_groovy(s):
        if "lintVital" not in s:
            s += '''
// Release-Lint der Plugins überspringen (Lint-Absturz in generiertem Plugin-Code)
subprojects {
    tasks.matching { it.name.startsWith("lintVital") }.configureEach { enabled = false }
}
'''
        return s

    edit(android / "build.gradle.kts", root_kts)
    edit(android / "build.gradle", root_groovy)

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
        if "applicationDockMenu" not in s:
            i = s.rfind("}")
            s = s[:i] + '''
  // Dock-Menü: Gespräch starten, neuer Chat, gespeicherte Prompts
  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    return JunelsDevice.dockMenu()
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
    // Dateien aufs Dock-Symbol ziehen / „Öffnen mit“ → an den Agenten übergeben
    NotificationCenter.default.addObserver(
      forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: nil
    ) { _ in
      NSAppleEventManager.shared().setEventHandler(
        DockTarget.shared, andSelector: #selector(DockTarget.openDocuments(_:withReplyEvent:)),
        forEventClass: AEEventClass(0x6165_7674), andEventID: AEEventID(0x6F64_6F63))  // 'aevt' / 'odoc'
      // junels://frage?text=… (Kurzbefehle-App, Links)
      NSAppleEventManager.shared().setEventHandler(
        JunelsServices.shared, andSelector: #selector(JunelsServices.handleURL(_:withReplyEvent:)),
        forEventClass: AEEventClass(0x4755_524C), andEventID: AEEventID(0x4755_524C))  // 'GURL' / 'GURL'
      // Dienste-Menü: markierten Text oder Links an Junels senden
      NSApp.servicesProvider = JunelsServices.shared
      NSUpdateDynamicServices()
    }
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
                   r"\1\n    JunelsFiles.register(flutterViewController)\n    JunelsDevice.register(flutterViewController)"
                   r"\n    self.isReleasedWhenClosed = false", s, count=1)
        s = s.replace("import PDFKit", "import PDFKit\nimport UserNotifications\nimport EventKit\nimport Contacts\nimport Security\nimport Network", 1)
        return (s + (ROOT / "scripts/macos/JunelsFiles.swift").read_text()
                + (ROOT / "scripts/macos/JunelsDevice.swift").read_text())

    edit(mac / "Runner/MainFlutterWindow.swift", main_window)
    def common(d):
        d["com.apple.security.app-sandbox"] = True
        d["com.apple.security.files.user-selected.read-write"] = True
        # ausgehende Verbindungen: Modell-Downloads und Websuche, nur nach Freigabe in der App
        d["com.apple.security.network.client"] = True
        d["com.apple.security.device.audio-input"] = True
        # eingehende Verbindungen: Abgleich mit dem Handy im WLAN (nur wenn in der App eingeschaltet)
        d["com.apple.security.network.server"] = True
        # Kalender und Kontakte (nur auf Nachfrage), freigegebene Ordner merken
        d["com.apple.security.personal-information.calendars"] = True
        d["com.apple.security.personal-information.addressbook"] = True
        d["com.apple.security.files.bookmarks.app-scope"] = True
        # Apps steuern (nur Musik-Apps aus der Freigabeliste, z. B. Wiedergabe/Pause bei Spotify)
        d["com.apple.security.automation.apple-events"] = True
        d["com.apple.security.temporary-exception.apple-events"] = [
            "com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.apple.TV",
        ]

    def release(d):
        common(d)

    edit_plist(mac / "Runner/Release.entitlements", release)
    edit_plist(mac / "Runner/DebugProfile.entitlements", common)  # network.server bleibt für Hot Reload

    def mac_info(d):
        d["NSMicrophoneUsageDescription"] = "Für die Spracheingabe. Die Erkennung läuft lokal auf dem Mac."
        d["NSLocalNetworkUsageDescription"] = "Für den Abgleich von Chats und Gedächtnis mit deinem Handy im WLAN."
        d["NSCalendarsUsageDescription"] = "Damit der Agent dir sagen kann, welche Termine du hast."
        d["NSAppleEventsUsageDescription"] = "Damit Junels freigegebene Apps wie Spotify steuern kann (Wiedergabe, Pause, nächster Titel) – nur Apps, die du erlaubt hast."
        d["NSCalendarsFullAccessUsageDescription"] = "Damit der Agent dir sagen kann, welche Termine du hast."
        d["NSContactsUsageDescription"] = "Damit der Agent Empfänger für E-Mails, WhatsApp und Anrufe findet."
        # Dateien aufs Dock-Symbol ziehen
        d["CFBundleDocumentTypes"] = [{
            "CFBundleTypeName": "Dokumente für Junels",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["com.adobe.pdf", "public.image", "public.plain-text", "net.daringfireball.markdown"],
        }]
        # Links junels://frage?text=… (Kurzbefehle-App, Raycast, Alfred …)
        d["CFBundleURLTypes"] = [{"CFBundleURLName": "io.junels.link", "CFBundleURLSchemes": ["junels"]}]
        # Dienste-Menü: markierten Text/Links aus jeder App an Junels senden
        d["NSServices"] = [{
            "NSMenuItem": {"default": "An Junels senden"},
            "NSMessage": "sendToJunels",
            "NSPortName": DISPLAY_NAME,
            "NSSendTypes": ["public.utf8-plain-text", "public.plain-text", "public.url", "public.file-url", "NSStringPboardType"],
            "NSRequiredContext": {},
        }]

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


def write_version():
    """lib/version.dart aus pubspec.yaml erzeugen (Anzeige im Menü)."""
    import re
    m = re.search(r"^version:\s*([^\s#]+)", (APP / "pubspec.yaml").read_text(), re.M)
    if not m:
        return
    name, _, build = m.group(1).partition("+")
    (APP / "lib/version.dart").write_text(
        "// Automatisch aus pubspec.yaml erzeugt (scripts/patch_platforms.py).\n"
        f"const appVersion = '{name}';\nconst appBuild = '{build}';\n")
    log(f"lib/version.dart: {name} ({build})")


if __name__ == "__main__":
    print(f"Patche {APP}")
    write_version()
    patch_android()
    patch_ios()
    patch_macos()
    widget_test = APP / "test/widget_test.dart"
    if widget_test.exists() and "MyApp" in widget_test.read_text():
        widget_test.unlink()
        log("test/widget_test.dart (Vorlage) entfernt")
    print("Fertig.")
