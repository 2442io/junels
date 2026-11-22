# Junels Agent-API

Speicher für die Junels-App (Abgleich zwischen Geräten) hinter der Weiche 1.4.x – mit SSO-Anmeldung,
eigenem Bereich je Person und Datenschutz-Stufen in der App. Alles, was gespeichert wird, verschlüsselt
die App vorher auf dem Gerät (Sync-Passwort); Server und SSO sehen nur unlesbare Blöcke.

Nur Klar-URLs, keine Parameter in Adressen:

| Adresse | Zweck |
|---|---|
| `GET /` | Info (JSON): Version, SSO an/aus |
| `GET /_junels/health` | Gesundheits-Check (Monitoring, Weiche) |
| `GET /login` | Anmelde-Seite im Browser (zeigt den SSO-Status) |
| `GET /login/app/<prüfwert>` | App-Anmeldung: SSO → zurück in die App per `junels://sso/<code>` |
| `POST /token` | Einmal-Code + geheimer Prüfwert → Zugangs-Token (JSON: `code`, `verifier`) |
| `GET /login/<port>` | Ältere Apps: SSO → `http://127.0.0.1:<port>/sso/<token>` |
| `POST /sync` | Abgleich (JSON: `token`, `account`, `since`, `items`) |
| `POST /whoami` | Name und E-Mail zum Token |
| `POST /logout` | Token ungültig machen |
| `POST /wipe` | Alle Daten dieser Person/dieses Kontos löschen |

Daten liegen im Kanal-Speicher (`shared/<kanal>/storage/junels/`), nie im Versionsordner.

## Neu in v2
- Anmeldung springt per App-Link (`junels://sso/<code>`) direkt zurück in die App – kein Hängen mehr,
  wenn das Handy die App im Hintergrund pausiert. Der Code ist 10 Minuten und nur einmal gültig und
  funktioniert nur zusammen mit dem geheimen Prüfwert der App (wie PKCE).
- `/login/<port>` bleibt für ältere App-Versionen.

## Neu in v1
- Erste Version hinter der Weiche: SSO-Anmeldung über `/sso.php` der Domain, eigener Speicher je Person,
  Klar-URLs für alle Aufrufe, Health für Abnahme und Monitoring.
