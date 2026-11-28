# Junels Agent-API hinter der Weiche 1.4.1

Speicher und SSO-Anmeldung für die Junels-App (Abgleich, Datenschutz-Stufen) – mit Kanälen Prod/Q/T,
Verwaltung unter /control, Abnahme-Tests und Rollback. Nur Klar-URLs, keine Parameter in Adressen.

## Ersteinrichtung
1. Diesen Ordner auf den Webspace laden (z. B. `agent.2442.io` → Ordner `junels-agent-api/`), SSL an.
   Optional `q.`/`t.`-Subdomains auf denselben Ordner (sonst `/q/`, `/t/`).
2. `data/app.php` ist schon das Junels-Profil (Präfix JUNELS, Health `/_junels/health`).
   Sollte es fehlen: `weiche/app.junels.php` nach `data/app.php` kopieren.
3. Optional `env/prod.env` aus `env/beispiel-junels/prod.env.example` anlegen (nur für SSO per Zugangsdaten).
4. `https://<domain>/control` öffnen → Ersteinrichtung mit dem Schlüssel aus `data/install-key.txt`.
5. /control → Domain zuordnen → **Neue Version hochladen**: `junels-api_v8.zip` → Prod zuweisen.
6. SSO koppeln: `https://<domain>/login` öffnen → „Mit SSO verbinden“ → in sso.2442.io bestätigen.
7. In Junels: Einstellungen → Konto, Daten & Abgleich → Adresse `https://<domain>` → „Mit SSO anmelden“.
8. Optional Cron (räumt alte Anmeldungen auf): `php /pfad/junels-agent-api/cron.php prod` täglich.

## Adressen der API
`GET /` Info · `GET /_junels/health` · `GET /login` · `GET /login/<port>` (App-Anmeldung, Rücksprung an
`http://127.0.0.1:<port>/sso/<token>`) · `POST /sync` · `POST /whoami` · `POST /logout` · `POST /wipe` · `POST /status` · `GET /admin` (Konto-Übersicht im Browser, Sync-Passwort zurücksetzen mit E-Mail-Bestätigung)

Daten: `shared/<kanal>/storage/junels/` (je Person ein Ordner, Inhalte Ende-zu-Ende verschlüsselt).

## Update auf eine neue Version (z. B. v2)
/control → **Neue Version hochladen** (`junels-api_v8.zip`) → erst Q/T zum Testen oder direkt Prod zuweisen.
Daten und SSO-Kopplung bleiben erhalten (liegen im Kanal-Speicher, nicht im Versionsordner).
