// Wissensbasis (RAG) und Gedächtnis verwalten.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/memory_store.dart';
import 'quick_nav.dart';

Future<void> openKnowledge(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const KnowledgePage()));

class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key});

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  final _url = TextEditingController();
  final _note = TextEditingController();
  bool _crawl = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _addUrl() async {
    final app = AppScope.read(context);
    if (_url.text.trim().isEmpty) return;
    setState(() => _error = null);
    final err = await app.addWebSource(_url.text, followLinks: _crawl);
    if (!mounted) return;
    setState(() => _error = err);
    if (err == null) _url.clear();
  }

  Future<void> _addFiles() async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (r == null) return;
    for (final f in r.files) {
      if (f.path == null) continue;
      final err = await app.addFileSource(f.path!, f.name);
      if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final kb = app.knowledge;
    final busy = app.knowledgeProgress != null;
    String date(DateTime d) => '${d.day}.${d.month}.${d.year}';

    return Scaffold(
      appBar: JAppBar(title: const Text('Wissensbasis & Gedächtnis')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text('Wissensbasis', style: t.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Webseiten und Textdateien, die der Agent bei jeder Frage durchsucht. '
                'Passende Abschnitte bekommt er automatisch mit und nennt die Quelle. '
                'Die Inhalte werden einmal geladen und liegen dann lokal.',
                style: t.bodySmall,
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _url,
                            enabled: !busy,
                            keyboardType: TextInputType.url,
                            onSubmitted: (_) => _addUrl(),
                            decoration: InputDecoration(
                              hintText: 'https://www.beispiel.at/hilfe',
                              errorText: _error,
                              prefixIcon: const Icon(Icons.public),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: busy ? null : _addUrl, child: const Text('Hinzufügen')),
                      ]),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _crawl,
                        onChanged: busy ? null : (v) => setState(() => _crawl = v ?? false),
                        title: const Text('Unterseiten mitnehmen (gleiche Website, bis 30 Seiten)'),
                      ),
                      if (busy)
                        Row(children: [
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 10),
                          Expanded(child: Text(app.knowledgeProgress!, style: t.bodySmall, maxLines: 2)),
                          TextButton(onPressed: app.cancelKnowledgeLoad, child: const Text('Stopp')),
                        ]),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: busy ? null : _addFiles,
                          icon: const Icon(Icons.note_add_outlined),
                          label: const Text('Textdateien hinzufügen (TXT, MD, CSV, JSON)'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (kb.sources.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('Noch keine Quellen.', style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              for (final s in kb.sources)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(s.kind == 'web' ? Icons.public : Icons.description_outlined),
                    title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${s.origin}\n${s.pages} Seite(n) · ${(s.chars / 1000).toStringAsFixed(0)}k Zeichen · ${date(s.updated)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isThreeLine: true,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (s.kind == 'web')
                        IconButton(
                          tooltip: 'Aktualisieren',
                          icon: const Icon(Icons.refresh),
                          onPressed: busy
                              ? null
                              : () async {
                                  final messenger = ScaffoldMessenger.of(context);
                                  final err = await app.refreshSource(s);
                                  messenger.showSnackBar(SnackBar(content: Text(err ?? '${s.name} aktualisiert')));
                                },
                        ),
                      IconButton(
                        tooltip: 'Entfernen',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: busy ? null : () => app.removeSource(s),
                      ),
                    ]),
                  ),
                ),
              const SizedBox(height: 28),
              Text('Gedächtnis', style: t.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Was sich der Agent über dich gemerkt hat – gilt für alle Chats und den Gesprächsmodus. '
                'Sag einfach „Merk dir, dass …“ oder trag es hier ein.',
                style: t.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _note,
                    decoration: const InputDecoration(hintText: 'z. B. Ich heiße Christoph und wohne in Wien.', isDense: true),
                    onSubmitted: (v) async {
                      await app.addMemory(v);
                      _note.clear();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () async {
                    await app.addMemory(_note.text);
                    _note.clear();
                  },
                  child: const Text('Merken'),
                ),
              ]),
              const SizedBox(height: 8),
              // Neue Einträge warten auf Bestätigung
              if (app.memory.pending.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Neu – bitte bestätigen (${app.memory.pending.length})',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary)),
                for (final n in app.memory.pending.reversed)
                  Card(
                    color: scheme.primaryContainer.withValues(alpha: 0.4),
                    child: ListTile(
                      dense: true,
                      title: Text(n.text),
                      subtitle: Text('${MemoryNote.categories[n.category]} · ${date(n.created)}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Bestätigen',
                          icon: const Icon(Icons.check_circle_outline),
                          onPressed: () => app.confirmMemory(n),
                        ),
                        IconButton(tooltip: 'Verwerfen', icon: const Icon(Icons.close), onPressed: () => app.removeMemory(n)),
                      ]),
                    ),
                  ),
              ],
              for (final cat in MemoryNote.categories.entries)
                if (app.memory.notes.any((n) => n.confirmed && n.category == cat.key)) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 2),
                    child: Text(cat.value, style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final n in app.memory.notes.reversed)
                    if (n.confirmed && n.category == cat.key)
                      ListTile(
                        dense: true,
                        leading: Icon(
                            switch (n.category) {
                              'vorliebe' => Icons.favorite_border,
                              'person' => Icons.person_outline,
                              'routine' => Icons.repeat,
                              _ => Icons.bookmark_border,
                            },
                            size: 20),
                        title: Text(n.text),
                        subtitle: Text(date(n.created)),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          PopupMenuButton<String>(
                            tooltip: 'Bereich ändern',
                            icon: const Icon(Icons.label_outline, size: 18),
                            onSelected: (k) => app.setMemoryCategory(n, k),
                            itemBuilder: (_) => [
                              for (final c in MemoryNote.categories.entries) PopupMenuItem(value: c.key, child: Text(c.value)),
                            ],
                          ),
                          IconButton(
                            tooltip: 'Vergessen',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => app.removeMemory(n),
                          ),
                        ]),
                      ),
                ],
              const Divider(height: 24),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Neue Einträge erst nach Bestätigung nutzen'),
                subtitle: const Text('Was der Agent sich merken will, erscheint oben zum Bestätigen.'),
                value: app.settings.memoryConfirm,
                onChanged: (v) => app.setMemoryOptions(confirm: v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sensible Themen merken'),
                subtitle: const Text('Gesundheit, Finanzen, Religion, Politik u. Ä. – standardmäßig aus.'),
                value: app.settings.memorySensitive,
                onChanged: (v) => app.setMemoryOptions(sensitive: v),
              ),
              if (app.memory.notes.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('Noch nichts gemerkt.', style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

