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
| `GET /login/<port>` | App-Anmeldung: SSO → zurück an `http://127.0.0.1:<port>/sso/<token>` |
| `POST /sync` | Abgleich (JSON: `token`, `account`, `since`, `items`) |
| `POST /whoami` | Name und E-Mail zum Token |
| `POST /logout` | Token ungültig machen |
| `POST /wipe` | Alle Daten dieser Person/dieses Kontos löschen |

Daten liegen im Kanal-Speicher (`shared/<kanal>/storage/junels/`), nie im Versionsordner.

## Neu in v1
- Erste Version hinter der Weiche: SSO-Anmeldung über `/sso.php` der Domain, eigener Speicher je Person,
  Klar-URLs für alle Aufrufe, Health für Abnahme und Monitoring.
