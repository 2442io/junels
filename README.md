# Offline Agent – v1.1

KI-Agent für **Mac, Android und iPad**, der komplett auf dem Gerät läuft: Sprachmodell (llama.cpp),
Spracheingabe (Whisper large-v3-turbo) und Vorlesen (Piper). Kein KI-API, kein App Store.
Internet nur, wenn du es erlaubst: für Modell-Downloads oder wenn der Agent im Web suchen will.

---

## Weg A – GitHub baut die App für dich (empfohlen, nichts auf dem Mac installieren)

1. Auf github.com ein neues **privates** Repository anlegen, z. B. `offline-agent`.
2. Den Inhalt dieses Ordners hochladen. Am einfachsten mit GitHub Desktop, oder im Browser:
   „Add file → Upload files“, alle Dateien und Ordner hineinziehen, „Commit changes“.
   Wichtig: Der versteckte Ordner `.github` muss mit hoch. Ihn zeigt der Finder erst nach `⌘ ⇧ .` an.
3. Reiter **Actions** öffnen. Der Lauf „Build“ startet automatisch und dauert etwa 30–60 Minuten.
4. Wenn er grün ist, den Lauf anklicken und unten unter **Artifacts** herunterladen:
   - `OfflineAgent-android` → enthält die `.apk`
   - `OfflineAgent-macos` → enthält die `.dmg`

Bei jeder Änderung baut GitHub neu. Mit einem Tag (`v1.1.0`) landen die Dateien zusätzlich als Release auf der
Repo-Seite.

## Weg B – Lokal auf dem Mac bauen

Einmalig (ca. 1 Stunde, rund 30 GB):

```bash
# 1. Xcode aus dem App Store installieren, einmal öffnen, dann:
sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch
# 2. Homebrew (https://brew.sh) installieren, dann:
brew install --cask flutter android-studio
brew install cmake cocoapods
# 3. Android Studio öffnen → Assistent durchklicken → Settings → Android SDK → SDK Tools:
#    "NDK (Side by side)", "CMake" und "Command-line Tools" anhaken → Apply
flutter doctor --android-licenses      # alles mit y bestätigen
flutter doctor                         # Android, Xcode: grüner Haken
```

Dann im entpackten Ordner:

```bash
cd ~/Downloads/offline_agent
scripts/setup.sh            # einmalig, 10–20 Minuten
scripts/build_macos.sh      # → dist/OfflineAgent-1.1.0-macos.dmg
scripts/build_android.sh    # → dist/OfflineAgent-1.1.0-android-arm64.apk
```

iPad: `scripts/build_ipad.sh run` mit per USB verbundenem iPad. Vorher in Xcode einmal das Team wählen.

---

## App installieren

**Mac:** .dmg öffnen und „Offline Agent“ in „Programme“ ziehen. Beim ersten Start: Rechtsklick → Öffnen
(die App ist nicht von Apple notarisiert).

**Android:** .apk aufs Handy oder Tablet bringen (USB, Google Drive, Mail) und antippen. Einmal
„Installation aus unbekannten Quellen“ erlauben.

## Erster Start: Systemcheck

Beim ersten Start öffnet sich der **Systemcheck**:

- Er zeigt RAM, freien Speicher, Prozessor und GPU und ordnet das Gerät einer Klasse zu (S, M oder L).
- Für jede Kategorie ist das passende Modell als **Empfohlen** markiert. Zu große Modelle sind ausgegraut.
- Ein Tipp lädt das Modell herunter. Ein abgebrochener Download wird beim nächsten Tipp fortgesetzt.

| Gerät | Sprachmodell | Spracherkennung | Stimme |
| --- | --- | --- | --- |
| S – bis 4 GB RAM | Qwen 2.5 1.5B (1,1 GB) | Whisper base (57 MB) | Piper Thorsten |
| M – 6–8 GB | Qwen3 4B Instruct 2507 (2,5 GB) | Whisper large-v3-turbo q5_0 (547 MB) | Piper Thorsten |
| L – ab 12 GB / Mac | Qwen 2.5 7B (4,7 GB) | Whisper large-v3-turbo voll (1,5 GB) | Piper Thorsten |

Der Systemcheck ist später über das Tacho-Symbol oben rechts erreichbar. Eigene .gguf-Dateien lassen sich
weiterhin importieren.

## Sprache

- **Mikrofon-Taste** neben dem Eingabefeld: tippen, sprechen, nochmal tippen. Whisper erkennt den Text
  lokal; danach wird automatisch gesendet (abschaltbar).
- **Lautsprecher-Taste** unter jeder Antwort liest sie mit Piper vor. In der Sidebar unter „Sprache“
  lässt sich automatisches Vorlesen einschalten.

## Internet mit Freigabe

Websuche und Webseiten-Abruf sind eigene Tools. Bevor der Agent sie nutzt, fragt die App:

- **Nur diese Frage:** Freigabe gilt nur für die aktuelle Anfrage.
- **Für diesen Chat:** Freigabe gilt für den ganzen Chat. Ein oranges Weltkugel-Symbol oben zeigt das an;
  ein Tipp darauf widerruft die Freigabe.
- **Ablehnen:** Der Agent antwortet ohne Internet.

Das Sprachmodell läuft immer lokal. Ins Netz gehen nur die Suchanfrage bzw. der Seitenabruf und die
Modell-Downloads.

---

## Für Entwickler

```
app/                     Flutter-App (UI, Zustand, Sprache)
packages/agent_engine/   Kern: llama.cpp + whisper.cpp über FFI, Agenten-Schleife, Tools,
                         Katalog, Downloader (reines Dart, 122 Tests)
scripts/                 setup, Builds, Tests, Plattform-Anpassung
.github/workflows/       automatischer Build
third_party/             llama.cpp b12522 + whisper.cpp (per scripts/fetch_llama.sh)
```

Tests: `scripts/test_engine.sh [modell.gguf]`

Bekannte Grenzen: Anhänge nur als Text (kein PDF). Android rechnet auf der CPU. Whisper large-v3-turbo braucht
auf Android-Geräten der Klasse M für 10 s Sprache einige Sekunden.
