// Skills: eigene Fähigkeiten entwerfen, Basis-Skills anpassen, im Agent-Skills-Standard (SKILL.md) importieren und teilen.

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/native_files.dart';
import '../state/skill_import.dart';
import '../state/skills.dart';
import 'quick_nav.dart';
import 'theme.dart';

const skillIcons = <String, IconData>{
  'auto_awesome': Icons.auto_awesome,
  'slideshow': Icons.slideshow,
  'description': Icons.description_outlined,
  'alarm': Icons.alarm,
  'wb_sunny': Icons.wb_sunny_outlined,
  'travel_explore': Icons.travel_explore,
  'explore': Icons.explore_outlined,
  'checklist': Icons.checklist,
  'music_note': Icons.music_note_outlined,
  'mail': Icons.mail_outline,
  'receipt': Icons.receipt_long_outlined,
  'flight': Icons.flight_takeoff,
  'shopping': Icons.shopping_bag_outlined,
  'school': Icons.school_outlined,
  'work': Icons.work_outline,
  'favorite': Icons.favorite_border,
  'code': Icons.code,
  'chart': Icons.insert_chart_outlined,
};

IconData skillIcon(String name) => skillIcons[name] ?? Icons.auto_awesome;

class SkillsPage extends StatelessWidget {
  const SkillsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final lib = app.skills;
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);

    Widget tile(Skill s) => Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: s.builtin ? c.raised : c.amberSoft, borderRadius: BorderRadius.circular(10)),
              child: Icon(skillIcon(s.icon), color: s.builtin ? c.muted : c.amber),
            ),
            title: Row(children: [
              Flexible(child: Text(s.name, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              MonoText('/${s.command}', color: c.muted),
              if (s.edited) ...[const SizedBox(width: 6), StatusChip('angepasst', color: c.amber, dense: true)],
            ]),
            subtitle: Text(
                [
                  s.when.isEmpty ? '${s.tools.length} Werkzeuge' : s.when,
                  if (s.internet == 'allow') '🌐 Internet erlaubt',
                  if (s.internet == 'block') 'offline',
                  if (s.model.isNotEmpty) Skill.modelLabels[s.model]!,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            trailing: Switch(value: s.enabled, onChanged: (v) => lib.setEnabled(s, v)),
            onTap: () => openSkillEditor(context, s),
          ),
        );

    return Scaffold(
      appBar: JAppBar(title: const Text('Skills'), actions: [
        IconButton(tooltip: 'Skills importieren', icon: const Icon(Icons.download_outlined), onPressed: () => showSkillImport(context)),
        IconButton(
          tooltip: 'Eigene Skills exportieren (ZIP)',
          icon: const Icon(Icons.ios_share),
          onPressed: () async {
            final list = [...lib.own, ...lib.basis.where((b) => b.edited)];
            if (list.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Noch keine eigenen oder angepassten Skills')));
              return;
            }
            await shareSkillZip(list, 'junels-skills');
          },
        ),
        IconButton(tooltip: 'Neuer Skill', icon: const Icon(Icons.add), onPressed: () => openSkillEditor(context, null)),
      ]),
      body: ListenableBuilder(
        listenable: lib,
        builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 32), children: [
          Text(
              'Ein Skill ist eine Anleitung plus die Werkzeuge, die Junels dafür nutzen darf. Aufrufen mit /befehl im Chat – '
              'eigene Skills erkennt Junels auch automatisch. Gespeichert im offenen Agent-Skills-Standard (SKILL.md): '
              'Skills aus Claude, Codex oder Cursor laufen hier, Junels-Skills dort. '
              'Tipp: „Bau mir einen Skill, der …“ oder unter einer guten Antwort „Als Skill speichern“.',
              style: t.bodySmall?.copyWith(color: c.muted)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Skill entwerfen'),
                onPressed: () => openSkillEditor(context, null),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.download_outlined),
                label: const Text('Importieren'),
                onPressed: () => showSkillImport(context),
              ),
            ),
          ]),
          SectionLabel('Eigene Skills (${lib.own.length})', padding: const EdgeInsets.fromLTRB(4, 18, 4, 6)),
          if (lib.own.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Noch keine eigenen Skills.', style: t.bodySmall?.copyWith(color: c.muted)),
            ),
          for (final s in lib.own) tile(s),
          const SectionLabel('Basis-Skills (aus den Werkzeugen)', padding: EdgeInsets.fromLTRB(4, 18, 4, 6)),
          for (final s in lib.basis) tile(s),
        ]),
      ),
    );
  }
}

/// Bytes als UTF-8 lesen (String.fromCharCodes liefert Latin-1).
String utf8Fix(String s) {
  try {
    return utf8.decode(s.codeUnits);
  } catch (_) {
    return s;
  }
}

/// Skills als Standard-Paket (ZIP mit <name>/SKILL.md + Dateien) teilen
Future<void> shareSkillZip(List<Skill> skills, String fileName) async {
  final f = File('${Directory.systemTemp.path}/$fileName.zip');
  await f.writeAsBytes(SkillImport.toZip(skills));
  await NativeFiles.share(f.path);
}

void openSkillEditor(BuildContext context, Skill? skill, {Skill? draft}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SkillEditor(skill: skill, draft: draft)));

/// Skills importieren: Datei(en), Link oder Text. Ein Skill → Editor zum Prüfen; mehrere → Auswahl.
Future<void> showSkillImport(BuildContext context) async {
  final app = AppScope.read(context);
  final m = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  final linkCtrl = TextEditingController();
  final textCtrl = TextEditingController();
  final tools = app.activeTools;
  final result = await showSheet<List<Skill>>(
    context: context,
    isScrollControlled: true,
    title: 'Skills importieren',
    builder: (ctx) {
      var busy = false;
      String? err;
      return StatefulBuilder(builder: (ctx, set) {
        final t = Theme.of(ctx).textTheme;
        Future<void> run(Future<List<Skill>> Function() f) async {
          set(() {
            busy = true;
            err = null;
          });
          try {
            final list = await f();
            if (list.isEmpty) throw Exception('Keine gültige SKILL.md gefunden');
            if (ctx.mounted) Navigator.pop(ctx, list);
          } catch (e) {
            set(() {
              busy = false;
              err = '$e'.replaceFirst('Exception: ', '');
            });
          }
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Text('SKILL.md nach dem Agent-Skills-Standard (Claude, Codex, Cursor, Gemini CLI …), auch als ZIP/.skill mit '
                  'mehreren Skills. Werkzeugnamen werden übersetzt; references/ & Co. bleiben als Dateien erhalten. '
                  'Skripte werden nur als Text übernommen und nie ausgeführt.',
                  style: t.bodySmall),
              const SizedBox(height: 14),
              FilledButton.icon(
                icon: const Icon(Icons.folder_open),
                label: const Text('Datei(en) wählen – .md, .zip, .skill'),
                onPressed: busy
                    ? null
                    : () => run(() async {
                          final pick = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any, withData: true);
                          if (pick == null) return const <Skill>[];
                          final out = <Skill>[];
                          for (final f in pick.files) {
                            final bytes = f.bytes ?? await File(f.path!).readAsBytes();
                            out.addAll(SkillImport.fromFile(f.name, bytes, available: tools));
                          }
                          return out;
                        }),
              ),
              const SizedBox(height: 18),
              Text('Von einem Link', style: t.titleSmall),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: linkCtrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(isDense: true, hintText: 'github.com/…/SKILL.md, Ordner oder .zip'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: busy ? null : () => run(() => SkillImport.fromLink(linkCtrl.text, available: tools)),
                  child: const Text('Laden'),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Lädt nur diese eine Adresse aus dem Internet.', style: t.bodySmall),
              ),
              const SizedBox(height: 18),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Text einfügen'),
                children: [
                  TextField(
                    controller: textCtrl,
                    minLines: 4,
                    maxLines: 10,
                    decoration: const InputDecoration(hintText: '---\nname: …\ndescription: …\n---\nAnleitung …', alignLabelWithHint: true),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: busy
                          ? null
                          : () => run(() async => [
                                if (SkillImport.fromText(textCtrl.text, available: tools) case final s?) s,
                              ]),
                      child: const Text('Übernehmen'),
                    ),
                  ),
                ],
              ),
              if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              if (err != null)
                Padding(padding: const EdgeInsets.only(top: 12), child: Text(err!, style: t.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.error))),
            ]),
          ),
        );
      });
    },
  );
  linkCtrl.dispose();
  textCtrl.dispose();
  if (result == null || result.isEmpty) return;
  // Befehle eindeutig machen
  for (final s in result) {
    final base = s.command;
    for (var i = 2; app.skills.all.any((o) => o.command == s.command) || result.any((o) => o != s && o.command == s.command && result.indexOf(o) < result.indexOf(s)); i++) {
      s.slug = '$base-$i';
    }
  }
  if (result.length == 1) {
    // einzeln: im Editor prüfen (Werkzeuge, Internet, Modell) und dann speichern
    await nav.push(MaterialPageRoute(builder: (_) => SkillEditor(draft: result.first)));
    return;
  }
  for (final s in result) {
    app.skills.upsert(s);
  }
  m.showSnackBar(SnackBar(content: Text('${result.length} Skills importiert – Werkzeuge bitte kurz prüfen')));
}

class SkillEditor extends StatefulWidget {
  const SkillEditor({super.key, this.skill, this.draft});
  final Skill? skill; // bearbeiten
  final Skill? draft; // neuer Skill mit Vorbelegung (z. B. aus einem Chat)

  @override
  State<SkillEditor> createState() => _SkillEditorState();
}

class _SkillEditorState extends State<SkillEditor> {
  late Skill s;
  late final TextEditingController _name, _slug, _when, _steps, _inputs, _knowledge;
  bool _isNew = false;

  @override
  void initState() {
    super.initState();
    _isNew = widget.skill == null;
    s = (widget.skill ?? widget.draft)?.copy() ?? Skill(id: 'u-${DateTime.now().microsecondsSinceEpoch}', name: '');
    _name = TextEditingController(text: s.name);
    _slug = TextEditingController(text: s.slug);
    _when = TextEditingController(text: s.when);
    _steps = TextEditingController(text: s.instructions);
    _inputs = TextEditingController(text: s.inputs);
    _knowledge = TextEditingController(text: s.knowledge);
  }

  void _apply() {
    s
      ..name = _name.text.trim()
      ..slug = Skill.slugify(_slug.text.trim().isEmpty ? _name.text : _slug.text)
      ..when = _when.text.trim()
      ..instructions = _steps.text.trim()
      ..inputs = _inputs.text.trim()
      ..knowledge = _knowledge.text.trim();
  }

  bool _save() {
    _apply();
    if (s.name.isEmpty || s.instructions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name und Anleitung ausfüllen')));
      return false;
    }
    final clash = AppScope.read(context).skills.all.where((o) => o.id != s.id && o.command == s.command).firstOrNull;
    if (clash != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('/${s.command} gibt es schon („${clash.name}“) – anderen Befehl wählen')));
      return false;
    }
    AppScope.read(context).skills.upsert(s);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final tools = [for (final x in app.tools) if (x.name != 'skill_erstellen' && x.name != 'skill') x];
    final known = {for (final x in tools) x.name};
    return Scaffold(
      appBar: JAppBar(
        title: Text(_isNew ? 'Neuer Skill' : s.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              final nav = Navigator.of(context);
              final m = ScaffoldMessenger.of(context);
              switch (v) {
                case 'copy':
                  _apply();
                  await Clipboard.setData(ClipboardData(text: s.toMarkdown()));
                  m.showSnackBar(const SnackBar(content: Text('SKILL.md kopiert')));
                case 'share':
                  _apply();
                  await shareSkillZip([s], s.specName);
                case 'check':
                  _apply();
                  final probs = SkillImport.validate(s.toMarkdown());
                  m.showSnackBar(SnackBar(
                      content: Text(probs.isEmpty
                          ? 'Entspricht dem Agent-Skills-Standard (Name: ${s.specName})'
                          : 'Nicht standardkonform: ${probs.join('; ')}')));
                case 'dup':
                  _apply();
                  final d = s.copy(id: 'u-${DateTime.now().microsecondsSinceEpoch}', builtin: false)
                    ..name = '${s.name} (Kopie)'
                    ..slug = ''
                    ..edited = false;
                  nav.pushReplacement(MaterialPageRoute(builder: (_) => SkillEditor(draft: d)));
                case 'reset':
                  app.skills.reset(s);
                  nav.pop();
                case 'delete':
                  app.skills.remove(s);
                  nav.pop();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.copy), title: Text('Als SKILL.md kopieren'))),
              const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.ios_share), title: Text('Teilen (Skill-Paket .zip)'))),
              const PopupMenuItem(value: 'check', child: ListTile(leading: Icon(Icons.verified_outlined), title: Text('Standard prüfen'))),
              const PopupMenuItem(value: 'dup', child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Duplizieren'))),
              if (s.builtin && s.edited)
                const PopupMenuItem(value: 'reset', child: ListTile(leading: Icon(Icons.restart_alt), title: Text('Zurücksetzen'))),
              if (!s.builtin && !_isNew)
                const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Löschen'))),
            ],
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 120), children: [
        Row(children: [
          PopupMenuButton<String>(
            tooltip: 'Symbol',
            onSelected: (v) => setState(() => s.icon = v),
            itemBuilder: (_) => [
              for (final e in skillIcons.entries) PopupMenuItem(value: e.key, child: Icon(e.value)),
            ],
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: c.amberSoft, borderRadius: BorderRadius.circular(12)),
              child: Icon(skillIcon(s.icon), color: c.amber),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Rechnungen sammeln'),
              onChanged: (v) => setState(() {}),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        TextField(
          controller: _slug,
          decoration: InputDecoration(
            labelText: 'Befehl im Chat',
            prefixText: '/',
            hintText: Skill.slugify(_name.text),
            helperText: 'Leer = aus dem Namen · auch der Name im Standard (a-z, 0-9, -)',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _when,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
              labelText: 'Wann nutzen', hintText: 'z. B. Wenn ich meine Rechnungen vom Monat zusammenstellen will'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatisch erkennen'),
          subtitle: const Text('Junels nutzt den Skill, wenn deine Nachricht zur Beschreibung passt – sonst nur per /befehl'),
          value: s.auto,
          onChanged: (v) => setState(() => s.auto = v),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _steps,
          minLines: 5,
          maxLines: 14,
          decoration: const InputDecoration(
            labelText: 'Anleitung',
            alignLabelWithHint: true,
            hintText: '1. Suche im Postfach nach Rechnungen dieses Monats\n2. Liste Betrag, Absender, Datum\n3. Erstelle ein Dokument „Rechnungen <Monat>“',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _inputs,
          decoration: const InputDecoration(labelText: 'Angaben, nach denen gefragt wird', hintText: 'z. B. Monat, Konto'),
        ),
        const SizedBox(height: 16),
        Text('Werkzeuge', style: t.titleSmall),
        const SizedBox(height: 2),
        Text('Nur diese darf Junels mit dem Skill nutzen – weniger ist verlässlicher.', style: t.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final x in tools)
            FilterChip(
              label: Text(x.title),
              avatar: x.requiresNetwork ? Icon(Icons.public, size: 14, color: c.blue) : null,
              selected: s.tools.contains(x.name),
              onSelected: (v) => setState(() {
                if (v) {
                  s.tools.add(x.name);
                } else {
                  s.tools.remove(x.name);
                  if (s.requiredTool == x.name) s.requiredTool = '';
                }
              }),
            ),
          for (final unknown in s.tools.where((n) => !known.contains(n)))
            Chip(label: Text('$unknown (nicht verfügbar)'), backgroundColor: c.redSoft),
        ]),
        if (s.unmapped.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Aus dem Original nicht übertragbar: ${s.unmapped.join(', ')} – dafür hat Junels kein Werkzeug.',
                style: t.bodySmall?.copyWith(color: c.muted)),
          ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: s.tools.contains(s.requiredTool) ? s.requiredTool : '',
          decoration: const InputDecoration(labelText: 'Ergebnis muss entstehen mit'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Frei – Antwort im Chat')),
            for (final n in s.tools.where(known.contains))
              DropdownMenuItem(value: n, child: Text(tools.firstWhere((x) => x.name == n).title)),
          ],
          onChanged: (v) => setState(() => s.requiredTool = v ?? ''),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: s.internet,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Internet', helperText: 'Gilt nur, wenn dieser Skill läuft'),
          items: [
            for (final e in Skill.internetLabels.entries)
              DropdownMenuItem(
                value: e.key,
                child: Row(children: [
                  Icon(e.key == 'allow' ? Icons.public : (e.key == 'block' ? Icons.public_off : Icons.help_outline), size: 18),
                  const SizedBox(width: 8),
                  Flexible(child: Text(e.value, overflow: TextOverflow.ellipsis)),
                ]),
              ),
          ],
          onChanged: (v) => setState(() => s.internet = v ?? 'ask'),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: s.model,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Modell (KI-Weiche)',
            helperText: s.model == 'cloud' || s.model == 'hybrid-cloud'
                ? 'Cloud: Inhalte gehen an ${AppScope.read(context).cloudProvider?.name ?? 'den Cloud-Anbieter (noch nicht eingerichtet)'}'
                : (s.model == 'onprem' || s.model == 'hybrid-onprem')
                    ? 'Eigener Server: ${AppScope.read(context).onPremProvider?.name ?? 'noch nicht eingerichtet'}'
                    : 'Wie im Chat eingestellt oder fest für diesen Skill',
          ),
          items: [
            for (final e in Skill.modelLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => s.model = v ?? ''),
        ),
        const SizedBox(height: 14),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Wissen & Beispiele (optional)'),
          children: [
            TextField(
              controller: _knowledge,
              minLines: 3,
              maxLines: 12,
              decoration: const InputDecoration(
                hintText: 'Fakten, Formulierungen, ein Beispiel-Ergebnis – wird bei jeder Nutzung mitgegeben',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Dateien (${s.files.length})'),
          subtitle: const Text('references/, scripts/, assets/ – liest Junels nur bei Bedarf'),
          children: [
            for (final f in s.files.keys.toList()..sort())
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(f.startsWith('scripts/') ? Icons.code : Icons.article_outlined, size: 20),
                title: MonoText(f),
                subtitle: Text('${(s.files[f]!.length / 1000).ceil()} KB${f.startsWith('scripts/') ? ' · wird nie ausgeführt' : ''}'),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(f),
                    content: SizedBox(width: 560, child: SingleChildScrollView(child: SelectableText(s.files[f]!))),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen'))],
                  ),
                ),
                trailing: IconButton(
                  tooltip: 'Entfernen',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => s.files.remove(f)),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Datei hinzufügen'),
                onPressed: () async {
                  final m = ScaffoldMessenger.of(context);
                  final pick = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any, withData: true);
                  if (pick == null) return;
                  var skipped = 0;
                  for (final f in pick.files) {
                    final bytes = f.bytes ?? await File(f.path!).readAsBytes();
                    final dir = RegExp(r'\.(py|sh|bash|js|mjs|ts|rb|ps1)$').hasMatch(f.name.toLowerCase()) ? 'scripts' : 'references';
                    if (!s.addFile('$dir/${f.name}', utf8.decode(bytes, allowMalformed: true))) skipped++;
                  }
                  setState(() {});
                  if (skipped > 0) m.showSnackBar(SnackBar(content: Text('$skipped Datei(en) zu groß (max. 200 KB je Datei, 1 MB gesamt)')));
                },
              ),
            ),
          ],
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Testen'),
                onPressed: () {
                  if (!_save()) return;
                  final app = AppScope.read(context);
                  goHome(context);
                  app.newConversation();
                  app.pendingInput.value = '/${s.command} ';
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Speichern'),
                onPressed: () {
                  if (_save()) Navigator.of(context).pop();
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
