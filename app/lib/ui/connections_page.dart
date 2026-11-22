// Zugänge für Web-APIs: API-Schlüssel, Token, Benutzer/Passwort, OAuth/SSO (Google, Microsoft, eigener Anbieter).

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/connections.dart';
import 'theme.dart';

class ConnectionsPage extends StatelessWidget {
  const ConnectionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final items = app.connections.items;
    return Scaffold(
      appBar: AppBar(title: const Text('Zugänge'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: () => editConnection(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Neuer Zugang'),
          ),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 48), children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const PageHeader(
                icon: Icons.key_outlined,
                title: 'Zugänge',
                subtitle: 'Anmeldedaten für Web-APIs in Prozessen. Schlüssel und Tokens liegen im Tresor – der Agent sieht sie nie.',
              ),
              if (items.isEmpty)
                Panel(
                  child: EmptyHint(
                    icon: Icons.key_outlined,
                    title: 'Noch keine Zugänge',
                    text: 'Lege z. B. einen API-Schlüssel oder eine Google-Anmeldung an und wähle ihn im Baustein „Web-API“.',
                    action: FilledButton.icon(
                      onPressed: () => editConnection(context),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Zugang anlegen'),
                    ),
                  ),
                ),
              for (final x in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Panel(
                    onTap: () => editConnection(context, existing: x),
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    child: Row(children: [
                      Icon(x.isOAuth ? Icons.verified_user_outlined : Icons.key_outlined, color: c.mint),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(x.name, style: Theme.of(context).textTheme.titleSmall),
                          MonoText([x.kind.label, if (x.baseUrl.isNotEmpty) x.baseUrl, if (x.signedInAs.isNotEmpty) x.signedInAs].join(' · ')),
                        ]),
                      ),
                      const Icon(Icons.chevron_right),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Zugang anlegen oder bearbeiten. Gibt die ID zurück (null = abgebrochen bzw. gelöscht).
Future<String?> editConnection(BuildContext context, {ApiConnection? existing}) async {
  final app = AppScope.read(context);
  final conn = existing ?? app.connections.create('Neuer Zugang');
  final ctrl = <String, TextEditingController>{
    'name': TextEditingController(text: existing?.name ?? ''),
    'base': TextEditingController(text: conn.baseUrl),
    'header': TextEditingController(text: conn.headerName == 'Authorization' && conn.kind != AuthKind.apiKey ? 'X-API-Key' : conn.headerName),
    'user': TextEditingController(text: conn.username),
    'secret': TextEditingController(),
    'issuer': TextEditingController(text: conn.issuer),
    'auth': TextEditingController(text: conn.authUrl),
    'token': TextEditingController(text: conn.tokenUrl),
    'client': TextEditingController(text: conn.clientId),
    'csecret': TextEditingController(),
    'scopes': TextEditingController(text: conn.scopes),
  };
  var kind = conn.kind;
  var inQuery = conn.keyInQuery;
  var preset = conn.preset;
  var extra = Map<String, String>.of(conn.extra);
  final hasSecret = existing == null ? false : await app.connections.hasSecret(conn);
  var signedIn = existing == null ? false : await app.connections.signedIn(conn);
  String? status;
  var busy = false;
  if (!context.mounted) return null;

  void applyTo(ApiConnection x) {
    x
      ..name = ctrl['name']!.text.trim().isEmpty ? (preset.isEmpty ? 'Zugang' : OAuthPreset.all.firstWhere((p) => p.id == preset).name) : ctrl['name']!.text.trim()
      ..kind = kind
      ..baseUrl = ctrl['base']!.text.trim()
      ..headerName = kind == AuthKind.apiKey ? (ctrl['header']!.text.trim().isEmpty ? 'X-API-Key' : ctrl['header']!.text.trim()) : 'Authorization'
      ..keyInQuery = inQuery
      ..username = ctrl['user']!.text.trim()
      ..preset = preset
      ..issuer = ctrl['issuer']!.text.trim()
      ..authUrl = ctrl['auth']!.text.trim()
      ..tokenUrl = ctrl['token']!.text.trim()
      ..clientId = ctrl['client']!.text.trim()
      ..scopes = ctrl['scopes']!.text.trim();
    x.extra
      ..clear()
      ..addAll(extra);
  }

  Future<void> persist() async {
    applyTo(conn);
    await app.connections.upsert(conn,
        secret: ctrl['secret']!.text.isEmpty ? null : ctrl['secret']!.text,
        clientSecret: ctrl['csecret']!.text.isEmpty ? null : ctrl['csecret']!.text);
  }

  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final c = AppColors.of(ctx);
      final t = Theme.of(ctx).textTheme;
      Widget field(String k, String label, {String? hint, bool secret = false, String? helper}) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: ctrl[k],
              obscureText: secret,
              autocorrect: false,
              decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3),
            ),
          );
      final p = OAuthPreset.all.where((x) => x.id == preset).firstOrNull;
      return AlertDialog(
        title: Text(existing == null ? 'Neuer Zugang' : 'Zugang bearbeiten'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              field('name', 'Name', hint: 'z. B. Google Kalender, Wetter-API'),
              DropdownButtonFormField<AuthKind>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: 'Anmeldung'),
                items: [for (final k in AuthKind.values) DropdownMenuItem(value: k, child: Text(k.label))],
                onChanged: (v) => set(() => kind = v ?? kind),
              ),
              const SizedBox(height: 12),
              field('base', 'Basis-Adresse (optional)', hint: 'https://api.beispiel.at', helper: 'Dann reichen im Baustein Pfade wie /v1/items.'),
              if (kind == AuthKind.apiKey) ...[
                field('header', 'Name des Headers bzw. Parameters', hint: 'X-API-Key'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Als Parameter in der Adresse (?key=…)'),
                  value: inQuery,
                  onChanged: (v) => set(() => inQuery = v),
                ),
                field('secret', hasSecret ? 'API-Schlüssel (gespeichert – leer lassen = behalten)' : 'API-Schlüssel', secret: true),
              ],
              if (kind == AuthKind.bearer) field('secret', hasSecret ? 'Token (gespeichert – leer lassen = behalten)' : 'Token', secret: true),
              if (kind == AuthKind.basic) ...[
                field('user', 'Benutzername'),
                field('secret', hasSecret ? 'Passwort (gespeichert – leer lassen = behalten)' : 'Passwort', secret: true),
              ],
              if (kind == AuthKind.oauth || kind == AuthKind.clientCredentials) ...[
                if (kind == AuthKind.oauth) ...[
                  Text('Vorlage', style: t.labelMedium),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final x in OAuthPreset.all)
                      ChoiceChip(
                        label: Text(x.name),
                        selected: preset == x.id,
                        onSelected: (_) => set(() {
                          preset = x.id;
                          extra = Map.of(x.extra);
                          if (x.auth.isNotEmpty) ctrl['auth']!.text = x.auth;
                          if (x.token.isNotEmpty) ctrl['token']!.text = x.token;
                          if (ctrl['scopes']!.text.trim().isEmpty) ctrl['scopes']!.text = x.scopes;
                          if (ctrl['name']!.text.trim().isEmpty) ctrl['name']!.text = x.name;
                        }),
                      ),
                  ]),
                  if (p != null && p.help.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(p.help, style: t.bodySmall),
                  ],
                  const SizedBox(height: 12),
                ],
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: field('issuer', 'Anbieter / Issuer (OpenID)', hint: 'https://sso.2442.io')),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: IconButton(
                      tooltip: 'Endpunkte suchen',
                      icon: const Icon(Icons.travel_explore),
                      onPressed: () async {
                        set(() => status = 'Suche Endpunkte …');
                        try {
                          final d = await OAuth2.discover(ctrl['issuer']!.text);
                          set(() {
                            ctrl['auth']!.text = d['auth'] ?? ctrl['auth']!.text;
                            ctrl['token']!.text = d['token'] ?? ctrl['token']!.text;
                            status = 'Endpunkte gefunden.';
                          });
                        } catch (e) {
                          set(() => status = 'Nicht gefunden: $e');
                        }
                      },
                    ),
                  ),
                ]),
                if (kind == AuthKind.oauth) field('auth', 'Anmelde-Adresse (authorization_endpoint)'),
                field('token', 'Token-Adresse (token_endpoint)'),
                field('client', 'Client-ID'),
                field('csecret', 'Client-Secret (falls nötig; gespeichert bleibt es, wenn leer)', secret: true),
                field('scopes', 'Scopes (mit Leerzeichen getrennt)'),
                if (kind == AuthKind.oauth)
                  Text('Rückleitung: http://127.0.0.1 (beliebiger Port) – beim Anbieter erlauben.', style: t.bodySmall),
                const SizedBox(height: 10),
                Row(children: [
                  Icon(signedIn ? Icons.check_circle : Icons.radio_button_unchecked, size: 18, color: signedIn ? c.mint : c.faint),
                  const SizedBox(width: 8),
                  Expanded(child: Text(signedIn ? 'Angemeldet${conn.signedInAs.isEmpty ? '' : ' als ${conn.signedInAs}'}' : 'Nicht angemeldet', style: t.bodySmall)),
                  if (signedIn)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              await app.connections.signOut(conn);
                              set(() => signedIn = false);
                            },
                      child: const Text('Abmelden'),
                    ),
                  FilledButton.tonal(
                    onPressed: busy
                        ? null
                        : () async {
                            set(() {
                              busy = true;
                              status = kind == AuthKind.oauth ? 'Browser geöffnet – bitte dort anmelden …' : 'Hole Token …';
                            });
                            await persist();
                            final err = await app.connections.signIn(conn);
                            final ok = await app.connections.signedIn(conn);
                            set(() {
                              busy = false;
                              signedIn = ok;
                              status = err ?? 'Angemeldet.';
                            });
                          },
                    child: Text(signedIn ? 'Neu anmelden' : 'Anmelden'),
                  ),
                ]),
              ],
              if (status != null) ...[
                const SizedBox(height: 8),
                Text(status!, style: t.bodySmall?.copyWith(color: status!.startsWith('Nicht') || status!.contains('abgelehnt') ? c.red : c.mint)),
              ],
            ]),
          ),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () async {
                await app.connections.remove(conn);
                if (ctx.mounted) Navigator.pop(ctx, '__deleted__');
              },
              child: Text('Löschen', style: TextStyle(color: AppColors.of(ctx).red)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () async {
              await persist();
              if (ctx.mounted) Navigator.pop(ctx, conn.id);
            },
            child: const Text('Speichern'),
          ),
        ],
      );
    }),
  );
  // Controller erst nach der Schließ-Animation freigeben
  Future<void>.delayed(const Duration(milliseconds: 600), () {
    for (final c in ctrl.values) {
      c.dispose();
    }
  });
  return result == '__deleted__' ? null : result;
}
