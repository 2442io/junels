// Sprachmodelle über eine API statt lokal: eigene Server (On-Prem, OpenAI-kompatibel
// wie Ollama, LM Studio, vLLM) oder Cloud-Anbieter (OpenAI, Anthropic, Gemini,
// Mistral, OpenRouter). Erfüllt dieselbe Schnittstelle wie die lokale Engine,
// damit die Agenten-Schleife unverändert bleibt.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'llama_engine.dart';

/// API-Dialekt eines Anbieters.
enum ProviderKind {
  openai('OpenAI', 'https://api.openai.com/v1', 'gpt-5-mini', false),
  anthropic('Anthropic (Claude)', 'https://api.anthropic.com/v1', 'claude-sonnet-5-5', false),
  gemini('Google Gemini', 'https://generativelanguage.googleapis.com/v1beta', 'gemini-2.5-flash', false),
  mistral('Mistral', 'https://api.mistral.ai/v1', 'mistral-medium-latest', false),
  openrouter('OpenRouter', 'https://openrouter.ai/api/v1', 'openrouter/auto', false),
  /// api.2442.io: wählt selbst einen freien Anbieter; „Modell“ = Favoriten in Reihenfolge (z. B. groq,gemini).
  api2442('2442 API', 'https://api.2442.io', '', false),
  ollama('Ollama (On-Prem)', 'http://192.168.1.10:11434/v1', 'qwen3:8b', true),
  compatible('OpenAI-kompatibler Server (On-Prem)', 'http://192.168.1.10:8000/v1', '', true);

  const ProviderKind(this.label, this.defaultUrl, this.defaultModel, this.onPrem);
  final String label;
  final String defaultUrl;
  final String defaultModel;

  /// Läuft typischerweise im eigenen Netz.
  final bool onPrem;

  bool get openAiStyle => this != anthropic && this != gemini && this != api2442;
  bool get needsKey => !onPrem;
}

/// Verbindung zu einem Anbieter (ohne Schlüssel – der liegt im Tresor).
class ProviderConfig {
  ProviderConfig({
    required this.id,
    required this.kind,
    required this.name,
    required this.baseUrl,
    required this.model,
    bool? onPrem,
    this.contextSize = 0,
    this.enabled = true,
  }) : onPrem = onPrem ?? kind.onPrem;

  final String id;
  ProviderKind kind;
  String name;
  String baseUrl;
  String model;

  /// Läuft im eigenen Netz (zählt nicht als Cloud).
  bool onPrem;

  /// 0 = Standard des Anbieters.
  int contextSize;
  bool enabled;

  int get effectiveContext => contextSize > 0 ? contextSize : (onPrem ? 32768 : 128000);

  String get label => kind == ProviderKind.api2442 && model.trim().isEmpty ? '$name · automatisch' : '$name · $model';

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        'onPrem': onPrem,
        'contextSize': contextSize,
        'enabled': enabled,
      };

  factory ProviderConfig.fromJson(Map<String, dynamic> j) {
    final kind = ProviderKind.values.where((k) => k.name == j['kind']).firstOrNull ?? ProviderKind.compatible;
    return ProviderConfig(
      id: j['id'] as String,
      kind: kind,
      name: j['name'] as String? ?? kind.label,
      baseUrl: j['baseUrl'] as String? ?? kind.defaultUrl,
      model: j['model'] as String? ?? kind.defaultModel,
      onPrem: j['onPrem'] as bool? ?? kind.onPrem,
      contextSize: (j['contextSize'] as num?)?.toInt() ?? 0,
      enabled: j['enabled'] as bool? ?? true,
    );
  }
}

const _marker = '\u0000JUNELS-REMOTE\u0000';

class RemoteException implements Exception {
  RemoteException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sprachmodell über HTTP mit Streaming.
class RemoteBackend implements AgentBackend {
  RemoteBackend(this.config, {this.apiKey, HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
  }

  final ProviderConfig config;
  final String? apiKey;
  final HttpClient _client;
  StreamSubscription<String>? _sub;
  HttpClientRequest? _req;
  bool _stop = false;

  @override
  int get contextSize => config.effectiveContext;

  @override
  Future<String> formatChat(List<ChatMessage> messages, {bool addAssistant = true}) async =>
      '$_marker${jsonEncode([for (final m in messages) [m.role, m.content]])}';

  /// Grobe Schätzung (für das Kürzen des Verlaufs) – ca. 3,6 Zeichen je Token.
  @override
  Future<int> countTokens(String text) async {
    final t = text.startsWith(_marker) ? text.substring(_marker.length) : text;
    return (t.length / 3.6).ceil();
  }

  @override
  void stop() {
    _stop = true;
    _sub?.cancel();
    try {
      _req?.abort();
    } catch (_) {}
  }

  void close() => _client.close(force: true);

  static List<ChatMessage> decode(String prompt) {
    if (!prompt.startsWith(_marker)) return [ChatMessage('user', prompt)];
    final raw = jsonDecode(prompt.substring(_marker.length)) as List;
    return [for (final m in raw) ChatMessage((m as List)[0] as String, m[1] as String)];
  }

  Uri _uri(String path) {
    final base = config.baseUrl.endsWith('/') ? config.baseUrl.substring(0, config.baseUrl.length - 1) : config.baseUrl;
    return Uri.parse('$base$path');
  }

  Map<String, String> _headers() => switch (config.kind) {
        ProviderKind.anthropic => {
            'x-api-key': apiKey ?? '',
            'anthropic-version': '2023-06-01',
          },
        ProviderKind.gemini => {'x-goog-api-key': apiKey ?? ''},
        ProviderKind.openrouter => {
            if (apiKey?.isNotEmpty ?? false) 'authorization': 'Bearer $apiKey',
            'http-referer': 'https://github.com/2442io/junels',
            'x-title': 'Junels',
          },
        ProviderKind.api2442 => {if (apiKey?.isNotEmpty ?? false) 'x-api-key': apiKey!},
        _ => {if (apiKey?.isNotEmpty ?? false) 'authorization': 'Bearer $apiKey'},
      };

  /// Anfrage-Body je Dialekt.
  (Uri, Map<String, dynamic>) _request(List<ChatMessage> msgs, {required bool json, required SamplingParams s, required int maxTokens}) {
    final system = msgs.where((m) => m.role == 'system').map((m) => m.content).join('\n\n');
    final rest = [for (final m in msgs) if (m.role != 'system') m];
    final jsonHint = json
        ? '\n\nANTWORTFORMAT: Antworte ausschließlich mit genau einem JSON-Objekt im oben beschriebenen Format – '
            'ohne Text davor oder danach und ohne Codeblock.'
        : '';
    // Rollen müssen sich abwechseln und mit „user“ beginnen (Anthropic, Gemini)
    final merged = <ChatMessage>[];
    for (final m in rest) {
      final role = m.role == 'assistant' ? 'assistant' : 'user';
      if (merged.isNotEmpty && merged.last.role == role) {
        merged[merged.length - 1] = ChatMessage(role, '${merged.last.content}\n\n${m.content}');
      } else {
        merged.add(ChatMessage(role, m.content));
      }
    }
    if (merged.isEmpty || merged.first.role != 'user') merged.insert(0, const ChatMessage('user', '…'));
    final temp = s.temperature.clamp(0.0, 1.0);
    switch (config.kind) {
      case ProviderKind.anthropic:
        return (
          _uri('/messages'),
          {
            'model': config.model,
            'max_tokens': maxTokens,
            'stream': true,
            'temperature': temp,
            if (system.isNotEmpty || json) 'system': '$system$jsonHint',
            'messages': [for (final m in merged) {'role': m.role, 'content': m.content}],
          }
        );
      case ProviderKind.gemini:
        return (
          _uri('/models/${config.model}:streamGenerateContent').replace(queryParameters: {'alt': 'sse'}),
          {
            if (system.isNotEmpty || json)
              'systemInstruction': {
                'parts': [
                  {'text': '$system$jsonHint'}
                ]
              },
            'contents': [
              for (final m in merged)
                {
                  'role': m.role == 'assistant' ? 'model' : 'user',
                  'parts': [
                    {'text': m.content}
                  ]
                }
            ],
            'generationConfig': {
              'temperature': temp,
              'maxOutputTokens': maxTokens,
              if (json) 'responseMimeType': 'application/json',
            },
          }
        );
      default:
        final strictJson = json && (config.kind == ProviderKind.openai || config.kind == ProviderKind.mistral);
        return (
          _uri('/chat/completions'),
          {
            'model': config.model,
            'stream': true,
            if (config.kind == ProviderKind.openai) 'stream_options': {'include_usage': true},
            // Neuere OpenAI-Modelle kennen nur max_completion_tokens
            if (config.kind == ProviderKind.openai) 'max_completion_tokens': maxTokens else 'max_tokens': maxTokens,
            if (config.kind != ProviderKind.openai) 'temperature': temp,
            if (strictJson) 'response_format': {'type': 'json_object'},
            'messages': [
              if (system.isNotEmpty || json) {'role': 'system', 'content': '$system$jsonHint'},
              for (final m in merged) {'role': m.role, 'content': m.content},
            ],
          }
        );
    }
  }

  /// Textstücke aus einem SSE-Ereignis.
  String? _delta(Map<String, dynamic> j, void Function(int inTok, int outTok) usage) {
    switch (config.kind) {
      case ProviderKind.anthropic:
        final type = j['type'];
        if (type == 'message_start') {
          final u = (j['message'] as Map?)?['usage'] as Map?;
          if (u != null) usage((u['input_tokens'] as num?)?.toInt() ?? 0, -1);
        } else if (type == 'message_delta') {
          final u = j['usage'] as Map?;
          if (u != null) usage(-1, (u['output_tokens'] as num?)?.toInt() ?? 0);
        } else if (type == 'content_block_delta') {
          final d = j['delta'] as Map?;
          if (d?['type'] == 'text_delta') return d!['text'] as String?;
        } else if (type == 'error') {
          throw RemoteException('${(j['error'] as Map?)?['message'] ?? j['error']}');
        }
        return null;
      case ProviderKind.gemini:
        final u = j['usageMetadata'] as Map?;
        if (u != null) {
          usage((u['promptTokenCount'] as num?)?.toInt() ?? -1, (u['candidatesTokenCount'] as num?)?.toInt() ?? -1);
        }
        final parts = (((j['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
        if (parts == null) return null;
        return parts.map((p) => (p as Map)['thought'] == true ? '' : (p['text'] as String? ?? '')).join();
      default:
        final u = j['usage'] as Map?;
        if (u != null) {
          usage((u['prompt_tokens'] as num?)?.toInt() ?? -1, (u['completion_tokens'] as num?)?.toInt() ?? -1);
        }
        if (j['error'] != null) throw RemoteException('${(j['error'] as Map?)?['message'] ?? j['error']}');
        final ch = (j['choices'] as List?)?.firstOrNull as Map?;
        final d = ch?['delta'] as Map?;
        return d?['content'] as String?;
    }
  }

  @override
  Stream<GenerationEvent> generate(String prompt,
      {String? grammar, SamplingParams sampling = const SamplingParams(), int maxTokens = 1024}) {
    final out = StreamController<GenerationEvent>();
    _stop = false;
    final json = grammar != null && grammar.contains('final_answer');
    final msgs = decode(prompt);
    final sw = Stopwatch()..start();
    var inTok = -1, outTok = -1;
    double ttft = 0;
    final text = StringBuffer();
    final filter = json ? _JsonFilter() : null;

    GenerationStats stats() {
      final p = inTok >= 0 ? inTok : (prompt.length / 3.6).ceil();
      final g = outTok >= 0 ? outTok : (text.length / 3.6).ceil();
      final gen = sw.elapsedMilliseconds - ttft;
      return GenerationStats.fromList(
          [p.toDouble(), ttft, g.toDouble(), gen < 1 ? 1 : gen, (p + g).toDouble(), contextSize.toDouble(), 0, ttft]);
    }

    void emit(String piece) {
      if (piece.isEmpty) return;
      if (ttft == 0) ttft = sw.elapsedMilliseconds.toDouble();
      final shown = filter == null ? piece : filter.feed(piece);
      if (shown.isEmpty) return;
      text.write(shown);
      out.add(TokenEvent(shown));
    }

    Future<void> run() async {
      try {
        if (config.kind == ProviderKind.api2442) {
          final r = await _ask2442(msgs, json: json);
          if (_stop) {
            out.add(DoneEvent(FinishReason.stopped, stats()));
            return;
          }
          emit(r.$1);
          if (filter != null && text.isEmpty) {
            final wrapped = jsonEncode({'thought': '', 'final_answer': filter.raw.toString().trim()});
            text.write(wrapped);
            out.add(TokenEvent(wrapped));
          } else if (!json && r.$2 != null) {
            emit('\n\n_${r.$2}_');
          }
          out.add(DoneEvent(FinishReason.done, stats()));
          return;
        }
        final (uri, body) = _request(msgs, json: json, s: sampling, maxTokens: maxTokens);
        final req = await _client.postUrl(uri);
        _req = req;
        req.headers.contentType = ContentType.json;
        req.headers.set('accept', 'text/event-stream');
        _headers().forEach(req.headers.set);
        req.add(utf8.encode(jsonEncode(body)));
        final res = await req.close().timeout(const Duration(seconds: 90));
        if (res.statusCode != 200) {
          final err = await res.transform(utf8.decoder).join();
          throw RemoteException('${config.name}: HTTP ${res.statusCode} – ${_errorText(err)}');
        }
        final lines = res.transform(utf8.decoder).transform(const LineSplitter());
        final done = Completer<void>();
        _sub = lines.listen((line) {
          if (!line.startsWith('data:')) return;
          final data = line.substring(5).trim();
          if (data.isEmpty || data == '[DONE]') return;
          try {
            final j = jsonDecode(data);
            if (j is Map<String, dynamic>) {
              final d = _delta(j, (i, o) {
                if (i >= 0) inTok = i;
                if (o >= 0) outTok = o;
              });
              if (d != null) emit(d);
            }
          } on RemoteException catch (e) {
            if (!done.isCompleted) done.completeError(e);
          } catch (_) {}
        }, onDone: () {
          if (!done.isCompleted) done.complete();
        }, onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        }, cancelOnError: true);
        await done.future.timeout(const Duration(minutes: 5));
        if (_stop) {
          out.add(DoneEvent(FinishReason.stopped, stats()));
        } else {
          if (filter != null && text.isEmpty) {
            // Kein JSON erkannt: Text als Antwort verpacken, damit der Agent nicht scheitert
            final plain = filter.raw.toString().trim();
            final wrapped = jsonEncode({'thought': '', 'final_answer': plain});
            text.write(wrapped);
            out.add(TokenEvent(wrapped));
          }
          out.add(DoneEvent(FinishReason.done, stats()));
        }
      } catch (e) {
        if (_stop) {
          out.add(DoneEvent(FinishReason.stopped, stats()));
        } else {
          out.add(DoneEvent(FinishReason.error, stats(), _friendly(e)));
        }
      } finally {
        _sub = null;
        _req = null;
        await out.close();
      }
    }

    unawaited(run());
    return out.stream;
  }

  /// 2442-API: eine Frage, eine Antwort (ohne Streaming). Der Verlauf wird zu einem Text.
  /// Ergebnis: (Antwort, Hinweis bei erschöpften Favoriten).
  Future<(String, String?)> _ask2442(List<ChatMessage> msgs, {required bool json}) async {
    final b = StringBuffer();
    for (final m in msgs) {
      final who = switch (m.role) { 'system' => 'Anweisungen', 'assistant' => 'Assistent', _ => 'Nutzer' };
      b.writeln('### $who\n${m.content.trim()}\n');
    }
    if (json) {
      b.writeln('ANTWORTFORMAT: Antworte ausschließlich mit genau einem JSON-Objekt im oben beschriebenen Format – '
          'ohne Text davor oder danach und ohne Codeblock.');
    }
    b.write('### Assistent\n');
    final favs = config.model.split(RegExp(r'[,;\s]+')).where((f) => f.isNotEmpty).toList();
    var base = config.baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final uri = Uri.parse(base.endsWith('.php') ? base : '$base/api.php');
    final req = await _client.postUrl(uri);
    _req = req;
    req.headers.contentType = ContentType.json;
    req.headers.set('accept', 'application/json');
    if (apiKey?.isNotEmpty ?? false) req.headers.set('x-api-key', apiKey!);
    req.add(utf8.encode(jsonEncode({'question': b.toString(), if (favs.isNotEmpty) 'favorites': favs})));
    final res = await req.close().timeout(const Duration(seconds: 120));
    final body = await res.transform(utf8.decoder).join();
    Map? j;
    try {
      final d = jsonDecode(body);
      if (d is Map) j = d;
    } catch (_) {}
    if (j == null || j['success'] != true || j['answer'] == null) {
      final why = ((j?['error_detail'] as Map?)?['message'] ?? j?['message'] ?? j?['error'] ??
              (res.statusCode != 200 ? 'HTTP ${res.statusCode}' : 'Keine gültige Antwort erhalten.'))
          .toString();
      throw RemoteException('${config.name}: $why');
    }
    final note = (j['notification'] as String?)?.trim();
    return ('${j['answer']}', note == null || note.isEmpty ? null : note);
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (e is SocketException || s.contains('SocketException')) {
      return '${config.name} ist nicht erreichbar (${config.baseUrl}). ${config.onPrem ? 'Läuft der Server und ist das Gerät im selben Netz?' : 'Besteht eine Internetverbindung?'}';
    }
    if (e is TimeoutException) return '${config.name} antwortet nicht (Zeitüberschreitung).';
    if (e is HandshakeException) return '${config.name}: TLS-Fehler – Zertifikat ungültig?';
    return s;
  }

  static String _errorText(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        if (e is Map && e['message'] != null) return '${e['message']}';
        if (e is String) return e;
        if (j['message'] != null) return '${j['message']}';
      }
      if (j is List && j.isNotEmpty && j.first is Map) {
        final e = (j.first as Map)['error'];
        if (e is Map && e['message'] != null) return '${e['message']}';
      }
    } catch (_) {}
    return body.length > 300 ? '${body.substring(0, 300)}…' : body;
  }

  /// Verfügbare Modelle abfragen (für die Auswahl in den Einstellungen).
  Future<List<String>> listModels() async {
    if (config.kind == ProviderKind.api2442) {
      // Keine Modellliste: Favoriten in Reihenfolge, leer = zufälliger freier Anbieter
      return const ['groq', 'gemini', 'openrouter', 'mistral', 'cerebras', 'groq,gemini', 'gemini,groq,openrouter'];
    }
    final uri = switch (config.kind) {
      ProviderKind.gemini => _uri('/models').replace(queryParameters: {'pageSize': '200'}),
      _ => _uri('/models'),
    };
    final req = await _client.getUrl(uri);
    _headers().forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw RemoteException('HTTP ${res.statusCode} – ${_errorText(body)}');
    final j = jsonDecode(body);
    final list = <String>[];
    if (j is Map) {
      for (final m in (j['data'] ?? j['models'] ?? const []) as List) {
        if (m is! Map) continue;
        var id = (m['id'] ?? m['name'] ?? '') as String;
        if (config.kind == ProviderKind.gemini) {
          final methods = (m['supportedGenerationMethods'] as List?) ?? const [];
          if (!methods.contains('generateContent')) continue;
          id = id.replaceFirst('models/', '');
        }
        if (id.isNotEmpty) list.add(id);
      }
    }
    list.sort();
    return list;
  }

  /// Kurzer Verbindungstest: eine Mini-Anfrage, liefert die Antwort.
  Future<String> ping() async {
    final buf = StringBuffer();
    String? err;
    await for (final ev in generate(
        await formatChat(const [ChatMessage('user', 'Antworte nur mit: OK')]),
        maxTokens: 256)) {
      if (ev is TokenEvent) buf.write(ev.text);
      if (ev is DoneEvent && ev.reason == FinishReason.error) err = ev.error;
    }
    if (err != null) throw RemoteException(err);
    return buf.toString().trim();
  }
}

/// Lässt bei JSON-Antworten nur das erste vollständige Objekt durch
/// (ohne Codeblock-Zäune oder Text davor/danach).
class _JsonFilter {
  final raw = StringBuffer();
  int _depth = 0;
  bool _started = false;
  bool _finished = false;
  bool _inString = false;
  bool _escape = false;

  String feed(String piece) {
    raw.write(piece);
    if (_finished) return '';
    final out = StringBuffer();
    for (final ch in piece.split('')) {
      if (!_started) {
        if (ch != '{') continue;
        _started = true;
      }
      out.write(ch);
      if (_inString) {
        if (_escape) {
          _escape = false;
        } else if (ch == r'\') {
          _escape = true;
        } else if (ch == '"') {
          _inString = false;
        }
        continue;
      }
      if (ch == '"') {
        _inString = true;
      } else if (ch == '{') {
        _depth++;
      } else if (ch == '}') {
        _depth--;
        if (_depth == 0) {
          _finished = true;
          break;
        }
      }
    }
    return out.toString();
  }
}
