# Junels Agent-API

Speicher für die Junels-App (Abgleich zwischen Geräten) hinter der Weiche 1.4.x – mit SSO-Anmeldung,
eigenem Bereich je Person und Datenschutz-Stufen in der App. Alles, was gespeichert wird, verschlüsselt
die App vorher auf dem Gerät (Sync-Passwort); Server und SSO sehen nur unlesbare Blöcke.

Nur Klar-URLs, keine Parameter in Adressen:

| Adresse | Zweck |
|---|---|
| `GET /` | Info (JSON): Version, SSO an/aus – im Browser eine Startseite mit Link zum Konto |
| `GET /_junels/health` | Gesundheits-Check (Monitoring, Weiche) |
| `GET /login` | Anmelde-Seite im Browser (zeigt den SSO-Status) |
| `GET /login/app/<prüfwert>` | App-Anmeldung: SSO → zurück in die App per `junels://sso/<code>` |
| `POST /token` | Einmal-Code + geheimer Prüfwert → Zugangs-Token (JSON: `code`, `verifier`) |
| `GET /login/<port>` | Ältere Apps: SSO → `http://127.0.0.1:<port>/sso/<token>` |
| `POST /sync` | Abgleich (JSON: `token`, `account`, `since`, `items`) |
| `POST /whoami` | Name und E-Mail zum Token |
| `POST /logout` | Token ungültig machen |
| `POST /wipe` | Zurücksetzen anfordern: schickt einen Bestätigungslink per E-Mail (ab v5) |
| `GET/POST /admin/bestaetigen/<code>` | Link aus der E-Mail: mit SSO derselben Person öffnen, dann „Jetzt zurücksetzen“ |
| `POST /status` | Konto-Übersicht für die App (JSON): Geräte, Daten je Kategorie, Anmeldungen |
| `GET /admin` | Konto-Übersicht im Browser (SSO): Geräte, Daten, Anmeldungen, Abmelden, alles löschen |
| `POST /admin/…` | Aktionen der Konto-Seite (mit Formular-Schutz): `loeschen`, `abmelden/<id>`, `geraet-entfernen/<id>` |

Daten liegen im Kanal-Speicher (`shared/<kanal>/storage/junels/`), nie im Versionsordner.

## Neu in v8
- **Admin-Bereich** im neuen Junels-Design: Übersicht, **Analytics** (Nutzung, Themen, Funktionen, Tokens, Nutzungszeit,
  geschätzte Ersparnis an Arbeitsstunden), Geräte, Daten, Sicherheit. Die Zahlen berechnet die App (ab Junels 1.74) und
  schickt sie per `POST /api/stats` – keine Inhalte, keine Chat-Titel.
- E-Mail: liest `MAIL_*` auch direkt aus `.env` / `env/<kanal>.env`, zeigt bei Fehlern den Grund (ohne Passwort);
  „Test-E-Mail an mich senden“ unter Admin → Sicherheit.

## Neu in v7
- Webseite auf Deutsch (`/`) und Englisch (`/en`), mit echten App-Bildern (`app/img`, ausgeliefert unter `/img/…`)
- Webseite im hellen, freundlichen Junels-Design mit Animationen (Handy-Vorschau, Lauftext, bewegte Bilder, Fragen & Antworten)
- E-Mail per SMTP aus der env (`MAIL_HOST`, `MAIL_PORT`, `MAIL_USER`, `MAIL_PASS`, `MAIL_FROM`, `MAIL_FROM_NAME`, `MAIL_ENCRYPTION`)

## Neu in v6
- **Webseite** unter `/`: im Browser eine richtige Seite mit allen Funktionen von Junels (Download, Mein Konto) –
  Apps bekommen dort weiterhin JSON.
- **API unter `/api`** (z. B. `/api/sync`, `/api/login/app/…`); `/api` im Browser zeigt eine Übersicht der Schnittstelle.
  Die bisherigen Adressen ohne `/api` funktionieren weiter. Konto-Seite: `/admin`.

## Neu in v5
- **Sync-Passwort zurücksetzen mit zwei Faktoren:** angemeldet per SSO **und** Bestätigungslink per E-Mail
  (30 Minuten, einmal gültig, nur für dieselbe Person, höchstens 3 Anfragen pro Stunde). Erst nach Klick auf
  „Jetzt zurücksetzen“ werden die Serverdaten gelöscht und das Passwort freigegeben – auch `POST /wipe` aus der App
  verschickt nur noch die E-Mail.
- E-Mail wie in den anderen Projekten per SMTP aus der env (`env/prod.env`):
  `MAIL_HOST`, `MAIL_PORT` (465 = SSL, 587 = STARTTLS), `MAIL_USER`, `MAIL_PASS`, `MAIL_FROM`, `MAIL_FROM_NAME`, `MAIL_ENCRYPTION`.
  Ohne `MAIL_HOST` wird PHP `mail()` verwendet. Fehler stehen im Log („E-Mail fehlgeschlagen: …“, ohne Passwort).
- Der Abgleich liefert `epoch` (Kennung des Datenbestands): nach einem Zurücksetzen lädt die App alles neu hoch.

## Neu in v4
- `agent.2442.io` im Browser zeigt eine Startseite mit „Mein Konto: Geräte & Daten“ (die App bekommt weiter JSON).

## Neu in v3
- **Konto-Übersicht** unter `/admin` (Anmeldung per SSO): welche Geräte abgleichen (Name, System, App-Version,
  letzter Abgleich), welche Daten gespeichert sind (Anzahl und Größe je Kategorie – Inhalte bleiben verschlüsselt),
  angemeldete Apps (einzeln abmelden), „Alle Daten auf dem Server löschen“ (z. B. bei anderem Sync-Passwort).
- `POST /status` liefert dieselbe Übersicht als JSON für die App.
- Die App meldet beim Abgleich ihr Gerät (Kennung, Name, System, Version) – nur Metadaten.

## Neu in v2
- Anmeldung springt per App-Link (`junels://sso/<code>`) direkt zurück in die App – kein Hängen mehr,
  wenn das Handy die App im Hintergrund pausiert. Der Code ist 10 Minuten und nur einmal gültig und
  funktioniert nur zusammen mit dem geheimen Prüfwert der App (wie PKCE).
- `/login/<port>` bleibt für ältere App-Versionen.

## Neu in v1
- Erste Version hinter der Weiche: SSO-Anmeldung über `/sso.php` der Domain, eigener Speicher je Person,
  Klar-URLs für alle Aufrufe, Health für Abnahme und Monitoring.
