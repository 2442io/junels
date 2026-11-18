// Dialog zum Bearbeiten eines Agent-Profils.

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_scope.dart';

Future<void> editProfile(BuildContext context, AgentProfile profile) async {
  final app = AppScope.read(context);
  final result = await showDialog<AgentProfile?>(
    context: context,
    builder: (_) => _ProfileDialog(profile: profile),
  );
  if (result == null) return;
  if (result.id == '__delete__') {
    await app.deleteProfile(profile);
    return;
  }
  await app.saveProfile(result);
  await app.selectProfile(result.id);
}

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.profile});
  final AgentProfile profile;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final _name = TextEditingController(text: widget.profile.name);
  late final _prompt = TextEditingController(text: widget.profile.systemPrompt);
  late double _temp = widget.profile.temperature;
  late int _steps = widget.profile.maxSteps;
  late bool _tools = widget.profile.useTools;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(p.builtin ? 'Profil anpassen' : 'Profil bearbeiten'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 12),
              TextField(
                controller: _prompt,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(labelText: 'System-Prompt', alignLabelWithHint: true),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Agent mit lokalen Tools'),
                subtitle: const Text('Aus: reiner Chat ohne Denkschritte'),
                value: _tools,
                onChanged: (v) => setState(() => _tools = v),
              ),
              Text('Temperatur: ${_temp.toStringAsFixed(1)}', style: t.bodyMedium),
              Slider(
                value: _temp,
                min: 0,
                max: 1.2,
                divisions: 12,
                label: _temp.toStringAsFixed(1),
                onChanged: (v) => setState(() => _temp = v),
              ),
              if (_tools) ...[
                Text('Max. Agenten-Schritte: $_steps', style: t.bodyMedium),
                Slider(
                  value: _steps.toDouble(),
                  min: 1,
                  max: 15,
                  divisions: 14,
                  label: '$_steps',
                  onChanged: (v) => setState(() => _steps = v.round()),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!p.builtin)
          TextButton(
            onPressed: () => Navigator.pop(
                context, AgentProfile(id: '__delete__', name: '', systemPrompt: '')),
            child: const Text('Löschen'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty || _prompt.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              AgentProfile(
                id: p.id,
                name: name,
                systemPrompt: _prompt.text.trim(),
                temperature: _temp,
                maxSteps: _steps,
                useTools: _tools,
                builtin: p.builtin,
              ),
            );
          },
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
