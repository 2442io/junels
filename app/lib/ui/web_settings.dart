// „Meine Daten“ (zum Ausfüllen von Formularen) und „Websites & Freigaben“ (wie frei Junels im Web handeln darf).

import 'package:agent_engine/agent_engine.dart' show SitePolicy, myDataFields, sensitiveField;
import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import 'quick_nav.dart';
import 'theme.dart';

Future<void> openMyData(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyDataPage()));

Future<void> openSitePolicy(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SitePolicyPage()));

class MyDataPage extends StatefulWidget {
  const MyDataPage({super.key});

  @override
  State<MyDataPage> createState() => _MyDataPageState();
}

class _MyDataPageState extends State<MyDataPage> {
  late final Map<String, String> data = {...AppScope.read(context).settings.myData};
  final _custName = TextEditingController();
  final _custNr = TextEditingController();

  Future<void> _save() async {
    final app = AppScope.read(context);
    app.settings.myData = {for (final e in data.entries) if (e.value.trim().isNotEmpty) e.key: e.value.trim()};
    await app.storage.saveSettings(app.settings);
    app.refreshUi();
  }

  @override
  void dispose() {
    _custName.dispose();
    _custNr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final customers = data.keys.where((k) => k.startsWith('kunde:')).toList();
    return Scaffold(
      appBar: JAppBar(title: const Text('Meine Daten')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 60), children: [
        Panel(
          color: c.mintSoft,
          child: Text(
              'Junels füllt Formulare damit aus (Browser-Aktion „autofill“, Skill „Formular-Ausfüller“). '
              'Die Werte trägt Junels direkt ins Formular ein – das KI-Modell sieht sie nicht, nur welche Felder gefüllt wurden. '
              'Absenden tust du selbst. Sozialversicherungsnummer, IBAN, Ausweis, Passwörter gehören nicht hierher – '
              'solche Felder trägst du immer selbst ein.',
              style: t.bodySmall),
        ),
        const SizedBox(height: 16),
        for (final f in myDataFields)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextFormField(
              initialValue: data[f.$1] ?? '',
              keyboardType: f.$1 == 'email'
                  ? TextInputType.emailAddress
                  : (f.$1 == 'telefon' ? TextInputType.phone : TextInputType.text),
              decoration: InputDecoration(labelText: f.$2, isDense: true),
              onChanged: (v) => data[f.$1] = v,
              onEditingComplete: _save,
            ),
          ),
        const SizedBox(height: 10),
        Text('Kunden- und Vertragsnummern', style: t.titleSmall),
        const SizedBox(height: 4),
        Text('z. B. Wien Energie, A1, Versicherung – werden bei „Kundennummer“-Feldern eingetragen.', style: t.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 8),
        for (final k in customers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.badge_outlined),
            title: Text(k.substring(6)),
            subtitle: Text(data[k] ?? ''),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                setState(() => data.remove(k));
                _save();
              },
            ),
          ),
        Row(children: [
          Expanded(child: TextField(controller: _custName, decoration: const InputDecoration(labelText: 'Anbieter', isDense: true))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _custNr, decoration: const InputDecoration(labelText: 'Nummer', isDense: true))),
          IconButton(
            tooltip: 'Hinzufügen',
            icon: const Icon(Icons.add),
            onPressed: () {
              final n = _custName.text.trim(), v = _custNr.text.trim();
              if (n.isEmpty || v.isEmpty) return;
              if (sensitiveField.hasMatch(n)) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Kontonummern, IBAN, Ausweis- oder SV-Nummern speichert Junels hier nicht.')));
                return;
              }
              setState(() {
                data['kunde:$n'] = v;
                _custName.clear();
                _custNr.clear();
              });
              _save();
            },
          ),
        ]),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () async {
            await _save();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Speichern'),
        ),
      ]),
    );
  }
}

class SitePolicyPage extends StatefulWidget {
  const SitePolicyPage({super.key});

  @override
  State<SitePolicyPage> createState() => _SitePolicyPageState();
}

class _SitePolicyPageState extends State<SitePolicyPage> {
  late SitePolicy pol = AppScope.read(context).sitePolicy;

  Future<void> _save() => AppScope.read(context).saveSitePolicy(pol);

  Widget _levelPicker(String value, ValueChanged<String> onChanged, {bool allowBlock = true}) => SegmentedButton<String>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: [
          const ButtonSegment(value: 'allow', label: Text('frei')),
          const ButtonSegment(value: 'ask', label: Text('fragen')),
          if (allowBlock) const ButtonSegment(value: 'block', label: Text('nie')),
        ],
        selected: {value},
        onSelectionChanged: (v) => onChanged(v.first),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final hosts = pol.sites.keys.toList()..sort();
    Widget row(String title, String sub, Widget picker) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.titleSmall),
            Text(sub, style: t.bodySmall?.copyWith(color: c.muted)),
            const SizedBox(height: 6),
            picker,
          ]),
        );
    return Scaffold(
      appBar: JAppBar(title: const Text('Websites & Freigaben')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 60), children: [
        Text('So frei darf Junels im Browser handeln. Fragt Junels nach, kannst du mit „Hier immer“ eine Website freigeben.',
            style: t.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 14),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            row('Lesen & Suchen', 'Seiten öffnen, suchen, Listen sammeln', Text('immer frei (mit deiner Internet-Freigabe)', style: t.bodyMedium)),
            row('Formulare ausfüllen', 'Felder eintragen, auswählen, ankreuzen', _levelPicker(pol.fill, (v) {
              setState(() => pol.fill = v);
              _save();
            })),
            row('Absenden', 'Formular abschicken, buchen, bestätigen, Nachricht senden', _levelPicker(pol.submit, (v) {
              setState(() => pol.submit = v);
              _save();
            })),
            row('Zahlen', 'Kaufen, bezahlen, Karte oder Konto eingeben', Text('nie – das machst immer du', style: t.bodyMedium?.copyWith(color: c.red))),
            row('Anmelden', 'Passwort, ID Austria, Passkey, CAPTCHA', Text('machst immer du – Junels wartet und macht danach weiter', style: t.bodyMedium)),
          ]),
        ),
        const SizedBox(height: 18),
        Text('Eigene Regeln je Website', style: t.titleSmall),
        const SizedBox(height: 8),
        if (hosts.isEmpty) Text('Noch keine – entstehen, wenn du bei einer Rückfrage „Hier immer“ wählst.', style: t.bodySmall?.copyWith(color: c.muted)),
        for (final h in hosts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Icon(Icons.public, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(h, style: t.titleSmall)),
                  IconButton(
                    tooltip: 'Regel entfernen',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() => pol.sites.remove(h));
                      _save();
                    },
                  ),
                ]),
                const SizedBox(height: 4),
                Text('Ausfüllen', style: t.labelMedium),
                _levelPicker(pol.sites[h]?['fill'] ?? pol.fill, (v) {
                  setState(() => pol.set(h, 'fill', v));
                  _save();
                }),
                const SizedBox(height: 6),
                Text('Absenden', style: t.labelMedium),
                _levelPicker(pol.sites[h]?['submit'] ?? pol.submit, (v) {
                  setState(() => pol.set(h, 'submit', v));
                  _save();
                }),
              ]),
            ),
          ),
      ]),
    );
  }
}
