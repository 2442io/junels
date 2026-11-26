// Eigene Designs (z. B. Firmen-CI): aus einer Datei übernehmen oder von Hand anlegen,
// optional als Standard für alle Präsentationen und Dokumente.

import 'package:agent_engine/agent_engine.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import 'theme.dart';
import 'quick_nav.dart';

Future<void> openDesigns(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DesignsPage()));

Color _hex(String h) => Color(int.tryParse('FF${h.replaceAll('#', '').padLeft(6, '0').substring(0, 6)}', radix: 16) ?? 0xFF888888);

class DesignsPage extends StatelessWidget {
  const DesignsPage({super.key});

  Future<void> _fromFile(BuildContext context) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final pick = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pptx', 'potx', 'docx', 'dotx', 'xlsx', 'pdf', 'png', 'jpg', 'jpeg', 'webp'],
    );
    final path = pick?.files.single.path;
    if (path == null || !context.mounted) return;
    final base = path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
    final name = await _askName(context, base);
    if (name == null) return;
    final r = await app.designFromFile(path, name);
    if (r == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Aus dieser Datei ließ sich kein Design lesen.')));
      return;
    }
    await app.addDesign(r.$1, template: r.$2);
    messenger.showSnackBar(SnackBar(
        content: Text('„$name“ gespeichert${r.$2 != null ? ' – inklusive Folienmaster der PowerPoint' : ''}.')));
  }

  Future<String?> _askName(BuildContext context, String initial) async {
    final ctrl = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name des Designs'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'z. B. Firmen-CI'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
        ],
      ),
    );
    ctrl.dispose();
    return r == null || r.trim().isEmpty ? null : r.trim();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final list = DesignLibrary.user;
    return Scaffold(
      appBar: JAppBar(title: const Text('Eigene Designs')),
      // rechts unten sitzt der Schnellmenü-Knopf
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showSheet(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Aus Datei übernehmen'),
                subtitle: const Text('PowerPoint (mit Folienmaster), Word, Excel, PDF oder ein Bild/Logo'),
                onTap: () {
                  Navigator.pop(ctx);
                  _fromFile(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('Von Hand anlegen'),
                subtitle: const Text('Farben und Schrift selbst wählen'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DesignEditor()));
                },
              ),
            ]),
          ),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Design'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text(
            'Lege dein Firmen-CI oder einen Lieblingsstil einmal an. Als Standard nutzt der Agent es für alle Präsentationen und PDFs – '
            'außer du nennst einen anderen Stil oder hängst eine Vorlage an. Du kannst ein Design auch beim Namen nennen („im Firmen-CI“).',
            style: t.bodySmall,
          ),
          const SizedBox(height: 16),
          if (list.isEmpty)
            const Panel(child: EmptyHint(icon: Icons.palette_outlined, title: 'Noch keine eigenen Designs', text: 'Tippe auf „+ Design“.')),
          for (final u in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Panel(
                padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                child: Row(children: [
                  _Swatches(u.design),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(child: Text(u.name, style: t.titleSmall, overflow: TextOverflow.ellipsis)),
                        if (DesignLibrary.defaultId == u.id) ...[
                          const SizedBox(width: 8),
                          StatusChip('Standard', color: c.mint, soft: c.mintSoft, dense: true),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        '${u.design.heading}${u.design.heading != u.design.font ? ' / ${u.design.font}' : ''}'
                        '${u.templatePath != null ? ' · mit Folienmaster' : ''}${u.design.source != null ? ' · ${u.design.source}' : ''}',
                        style: t.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ]),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      switch (v) {
                        case 'default':
                          await app.setDefaultDesign(DesignLibrary.defaultId == u.id ? null : u.id);
                        case 'edit':
                          if (context.mounted) {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DesignEditor(existing: u)));
                          }
                        case 'delete':
                          await app.removeDesign(u.id);
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                          value: 'default',
                          child: Text(DesignLibrary.defaultId == u.id ? 'Nicht mehr als Standard' : 'Als Standard verwenden')),
                      const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                      const PopupMenuItem(value: 'delete', child: Text('Löschen')),
                    ],
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class _Swatches extends StatelessWidget {
  const _Swatches(this.d);
  final SlideDesign d;
  @override
  Widget build(BuildContext context) {
    Widget dot(String h, double s) => Container(
          width: s,
          height: s,
          decoration: BoxDecoration(color: _hex(h), shape: BoxShape.circle, border: Border.all(color: Colors.black12)),
        );
    return SizedBox(
      width: 54,
      height: 40,
      child: Stack(children: [
        Positioned(left: 0, top: 0, child: dot(d.primary, 30)),
        Positioned(left: 20, top: 8, child: dot(d.secondary, 24)),
        Positioned(left: 36, top: 22, child: dot(d.background, 16)),
      ]),
    );
  }
}

/// Design von Hand anlegen oder ändern.
class DesignEditor extends StatefulWidget {
  const DesignEditor({super.key, this.existing});
  final UserDesign? existing;
  @override
  State<DesignEditor> createState() => _DesignEditorState();
}

class _DesignEditorState extends State<DesignEditor> {
  late final SlideDesign _d = widget.existing?.design ?? designById('standard');
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _primary = TextEditingController(text: _d.primary);
  late final _secondary = TextEditingController(text: _d.secondary);
  late final _background = TextEditingController(text: _d.background);
  late final _text = TextEditingController(text: _d.text);
  late String _font = _d.font;
  late String _head = _d.heading;
  late DesignMotif _motif = _d.motif;

  static const _fonts = ['Calibri', 'Arial', 'Helvetica', 'Segoe UI', 'Trebuchet MS', 'Verdana', 'Georgia', 'Garamond', 'Times New Roman'];
  static const _presets = ['0E6B66', '1F3A60', '3A3FD1', 'B5462E', '6A3FA0', '2D2A32', 'C8102E', '00843D', 'F2A541', 'E07A2E', '18B6C4', 'FFFFFF'];

  @override
  void dispose() {
    for (final c in [_name, _primary, _secondary, _background, _text]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _valid(String h) => RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(h.trim());
  String _clean(String h) => h.trim().replaceAll('#', '').toUpperCase();

  Future<void> _save() async {
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    final name = _name.text.trim().isEmpty ? 'Eigenes Design' : _name.text.trim();
    final j = _d.toJson()
      ..['id'] = widget.existing?.id ?? DesignLibrary.idFor(name)
      ..['name'] = name
      ..['primary'] = _clean(_primary.text)
      ..['secondary'] = _clean(_secondary.text)
      ..['background'] = _clean(_background.text)
      ..['text'] = _clean(_text.text)
      ..['font'] = _font
      ..['headFont'] = _head
      ..['motif'] = _motif.name
      ..remove('light')
      ..remove('accent');
    final d = SlideDesign.fromJson(j);
    final keepTemplate = widget.existing?.templatePath;
    await app.addDesign(d);
    if (keepTemplate != null) {
      final i = DesignLibrary.user.indexWhere((u) => u.id == d.id);
      if (i >= 0) DesignLibrary.user[i] = UserDesign(design: d, templatePath: keepTemplate);
      await app.saveDesigns();
    }
    nav.pop();
  }

  Widget _color(String label, TextEditingController ctrl) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: ctrl,
            decoration: InputDecoration(
              labelText: label,
              prefixText: '#',
              suffixIcon: Padding(
                padding: const EdgeInsets.all(10),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                      color: _valid(ctrl.text) ? _hex(_clean(ctrl.text)) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.black26)),
                ),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in _presets)
              InkWell(
                onTap: () => setState(() => ctrl.text = p),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration:
                      BoxDecoration(color: _hex(p), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.black26)),
                ),
              ),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final ok = [_primary, _secondary, _background, _text].every((c) => _valid(c.text));
    return Scaffold(
      appBar: JAppBar(
        title: Text(widget.existing == null ? 'Design anlegen' : 'Design bearbeiten'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: ok ? _save : null, child: const Text('Speichern')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Firmen-CI')),
                const SizedBox(height: 16),
                _color('Hauptfarbe (Titel, Balken)', _primary),
                _color('Akzentfarbe', _secondary),
                _color('Hintergrund der Folien', _background),
                _color('Textfarbe', _text),
                DropdownButtonFormField<String>(
                  initialValue: _fonts.contains(_head) ? _head : _fonts.first,
                  decoration: const InputDecoration(labelText: 'Schrift für Überschriften'),
                  items: [for (final f in _fonts) DropdownMenuItem(value: f, child: Text(f, style: TextStyle(fontFamily: f)))],
                  onChanged: (v) => setState(() => _head = v ?? _head),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _fonts.contains(_font) ? _font : _fonts.first,
                  decoration: const InputDecoration(labelText: 'Schrift für Text'),
                  items: [for (final f in _fonts) DropdownMenuItem(value: f, child: Text(f, style: TextStyle(fontFamily: f)))],
                  onChanged: (v) => setState(() => _font = v ?? _font),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<DesignMotif>(
                  initialValue: _motif,
                  decoration: const InputDecoration(labelText: 'Verzierung'),
                  items: const [
                    DropdownMenuItem(value: DesignMotif.lines, child: Text('Schlicht (Balken oben)')),
                    DropdownMenuItem(value: DesignMotif.corners, child: Text('Ecken')),
                    DropdownMenuItem(value: DesignMotif.dots, child: Text('Punkte')),
                    DropdownMenuItem(value: DesignMotif.waves, child: Text('Wellen')),
                    DropdownMenuItem(value: DesignMotif.mountains, child: Text('Berge')),
                    DropdownMenuItem(value: DesignMotif.none, child: Text('Keine')),
                  ],
                  onChanged: (v) => setState(() => _motif = v ?? _motif),
                ),
                const SizedBox(height: 20),
                // kleine Vorschau einer Folie
                if (ok)
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _hex(_clean(_background.text)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.black12),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(height: 8, color: _hex(_clean(_primary.text))),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                          child: Text('Folientitel',
                              style: TextStyle(
                                  fontFamily: _head, fontSize: 22, fontWeight: FontWeight.bold, color: _hex(_clean(_primary.text)))),
                        ),
                        for (final l in ['Erster Punkt', 'Zweiter Punkt'])
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                            child: Row(children: [
                              Container(width: 7, height: 7, decoration: BoxDecoration(color: _hex(_clean(_secondary.text)), shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Text(l, style: TextStyle(fontFamily: _font, fontSize: 14, color: _hex(_clean(_text.text)))),
                            ]),
                          ),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
