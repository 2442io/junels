// Skills: eigene Fähigkeiten aus Anleitung + Werkzeugen entwerfen, Basis-Skills anpassen, als SKILL.md teilen.

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/native_files.dart';
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
            subtitle: Text(s.when.isEmpty ? '${s.tools.length} Werkzeuge' : s.when, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Switch(value: s.enabled, onChanged: (v) => lib.setEnabled(s, v)),
            onTap: () => openSkillEditor(context, s),
          ),
        );

    return Scaffold(
      appBar: JAppBar(title: const Text('Skills'), actions: [
        IconButton(tooltip: 'SKILL.md importieren', icon: const Icon(Icons.file_download_outlined), onPressed: () => _import(context)),
        IconButton(tooltip: 'Neuer Skill', icon: const Icon(Icons.add), onPressed: () => openSkillEditor(context, null)),
      ]),
      body: ListenableBuilder(
        listenable: lib,
        builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 32), children: [
          Text(
              'Ein Skill ist eine Anleitung plus die Werkzeuge, die Junels dafür nutzen darf. Aufrufen mit /befehl im Chat – '
              'eigene Skills erkennt Junels auch automatisch. Tipp: „Bau mir einen Skill, der …“ oder unter einer guten Antwort „Als Skill speichern“.',
              style: t.bodySmall?.copyWith(color: c.muted)),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Eigenen Skill entwerfen'),
            onPressed: () => openSkillEditor(context, null),
          ),
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

  Future<void> _import(BuildContext context) async {
    final app = AppScope.read(context);
    final m = ScaffoldMessenger.of(context);
    final pick = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any, withData: true);
    if (pick == null || pick.files.isEmpty) return;
    var n = 0;
    for (final f in pick.files) {
      try {
        final text = f.bytes != null ? String.fromCharCodes(f.bytes!) : await File(f.path!).readAsString();
        final s = Skill.fromMarkdown(utf8Fix(text), id: 'u-${DateTime.now().microsecondsSinceEpoch}-$n');
        if (s == null) continue;
        app.skills.upsert(s);
        n++;
      } catch (_) {}
    }
    m.showSnackBar(SnackBar(content: Text(n == 0 ? 'Keine gültige SKILL.md gefunden' : '$n Skill(s) importiert – bitte Werkzeuge prüfen')));
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

void openSkillEditor(BuildContext context, Skill? skill) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SkillEditor(skill: skill)));

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
    final tools = [for (final x in app.tools) if (x.name != 'skill_erstellen') x];
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
                  final f = File('${Directory.systemTemp.path}/${s.command}.SKILL.md');
                  await f.writeAsString(s.toMarkdown());
                  await NativeFiles.share(f.path);
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
              const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.ios_share), title: Text('Teilen (SKILL.md)'))),
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
            helperText: 'Leer = aus dem Namen',
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
