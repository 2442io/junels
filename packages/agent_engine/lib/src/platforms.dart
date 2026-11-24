import 'dart:convert';

/// Externe Agenten-/Workflow-Plattformen, die ein Prozess-Baustein aufrufen kann.
enum AgentPlatform {
  n8n('n8n', 'n8n-Webhook', 'https://dein-n8n.example/webhook/…'),
  dify('dify', 'Dify', 'https://api.dify.ai/v1/workflows/run'),
  flowise('flowise', 'Flowise', 'https://dein-flowise.example/api/v1/prediction/<id>'),
  langflow('langflow', 'Langflow', 'https://dein-langflow.example/api/v1/run/<flow-id>'),
  webhook('webhook', 'Eigener Webhook', 'https://…');

  const AgentPlatform(this.id, this.label, this.example);
  final String id;
  final String label;
  final String example;

  static AgentPlatform parse(String? s) =>
      values.where((p) => p.id == (s ?? '').toLowerCase().trim()).firstOrNull ?? AgentPlatform.webhook;
}

/// Baut den Anfrage-Text für die Plattform. [input] ist der Auftrag/Text, [meta] Zusatzangaben
/// (Prozessname, Datum …), [inputKey] der Name des Eingabefelds (Dify-Workflows).
String platformRequestBody(AgentPlatform p, Uri url, String input,
    {Map<String, String> meta = const {}, String inputKey = 'query'}) {
  final key = inputKey.trim().isEmpty ? 'query' : inputKey.trim();
  return jsonEncode(switch (p) {
    AgentPlatform.dify => url.path.contains('chat-messages') || url.path.contains('completion-messages')
        ? {'query': input, 'inputs': <String, String>{}, 'response_mode': 'blocking', 'user': 'junels'}
        : {
            'inputs': {key: input},
            'response_mode': 'blocking',
            'user': 'junels'
          },
    AgentPlatform.flowise => {'question': input},
    AgentPlatform.langflow => {'input_value': input, 'input_type': 'chat', 'output_type': 'chat'},
    AgentPlatform.n8n => {'eingabe': input, 'quelle': 'junels', ...meta},
    AgentPlatform.webhook => {'text': input, 'quelle': 'junels', ...meta},
  });
}

/// Holt die eigentliche Antwort aus der Plattform-Antwort; sonst der (eingerückte) Text.
String platformAnswer(AgentPlatform p, String body) {
  final t = body.trim();
  Object? j;
  try {
    j = jsonDecode(t);
  } catch (_) {
    return t;
  }
  String? s(Object? v) {
    if (v == null) return null;
    if (v is String) return v.trim().isEmpty ? null : v;
    if (v is Map && v.length == 1) return s(v.values.first);
    return const JsonEncoder.withIndent('  ').convert(v);
  }

  Object? at(Object? o, List<Object> path) {
    for (final k in path) {
      if (k is String && o is Map) {
        o = o[k];
      } else if (k is int && o is List && o.length > k) {
        o = o[k];
      } else {
        return null;
      }
    }
    return o;
  }

  final hit = switch (p) {
    AgentPlatform.dify => s(at(j, ['answer'])) ?? s(at(j, ['data', 'outputs'])),
    AgentPlatform.flowise => s(at(j, ['text'])) ?? s(at(j, ['json'])),
    AgentPlatform.langflow => s(at(j, ['outputs', 0, 'outputs', 0, 'results', 'message', 'text'])) ??
        s(at(j, ['outputs', 0, 'outputs', 0, 'results', 'message', 'data', 'text'])) ??
        s(at(j, ['outputs', 0, 'outputs', 0, 'messages', 0, 'message'])),
    _ => null,
  };
  if (hit != null) return hit;
  // n8n/Webhook (oder unbekannt): übliche Felder, auch in einer Liste
  final o = j is List && j.length == 1 ? j.first : j;
  for (final k in const ['output', 'text', 'answer', 'result', 'message', 'antwort', 'ergebnis']) {
    final v = s(at(o, [k]));
    if (v != null) return v;
  }
  return s(j) ?? t;
}

/// Urteil eines Prüfer-Agenten im Team: erste Zeile „OK“ → fertig, sonst Rückmeldung.
(bool ok, String feedback) teamVerdict(String answer) {
  final t = answer.trim();
  final first = t.split('\n').first.trim().toLowerCase().replaceAll(RegExp(r'[^a-zäöüß ]'), '').trim();
  final ok = first == 'ok' || first.startsWith('ok ') || first == 'passt' || first.startsWith('freigegeben') || first == 'okay';
  final rest = t.split('\n').skip(1).join('\n').trim();
  return (ok, ok ? rest : t.replaceFirst(RegExp(r'^\s*(überarbeiten|ueberarbeiten)\s*[:.\-–]?\s*', caseSensitive: false), '').trim());
}
