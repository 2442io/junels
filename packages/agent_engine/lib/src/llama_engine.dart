// LlamaEngine: führt llama.cpp in einem eigenen Isolate aus, damit die UI
// während Prompt-Verarbeitung und Generierung flüssig bleibt.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'bindings.dart';

class EngineException implements Exception {
  EngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

class EngineConfig {
  const EngineConfig({
    required this.modelPath,
    this.contextSize = 2048,
    this.threads = 4,
    this.gpuLayers = 0,
    this.quantizeKvCache = false,
  });

  final String modelPath;
  final int contextSize;
  final int threads;

  /// -1 = alle Schichten auf die GPU (Metal), 0 = nur CPU.
  final int gpuLayers;
  final bool quantizeKvCache;

  Map<String, Object> toMap() => {
        'path': modelPath,
        'ctx': contextSize,
        'threads': threads,
        'gpu': gpuLayers,
        'kvq': quantizeKvCache ? 1 : 0,
      };
}

class SamplingParams {
  const SamplingParams({
    this.temperature = 0.7,
    this.topP = 0.95,
    this.minP = 0.05,
    this.seed = -1,
  });

  /// Deterministisch, gut für Tool-Aufrufe.
  static const precise = SamplingParams(temperature: 0.2, topP: 0.9);

  final double temperature;
  final double topP;
  final double minP;
  final int seed;
}

class ModelInfo {
  ModelInfo.fromJson(Map<String, dynamic> j)
      : description = j['desc'] as String? ?? '',
        sizeBytes = (j['size_bytes'] as num?)?.toInt() ?? 0,
        parameters = (j['n_params'] as num?)?.toInt() ?? 0,
        contextSize = (j['n_ctx'] as num?)?.toInt() ?? 0,
        trainedContext = (j['n_ctx_train'] as num?)?.toInt() ?? 0,
        chatTemplate = j['chat_template'] as String? ?? '';

  final String description;
  final int sizeBytes;
  final int parameters;
  final int contextSize;
  final int trainedContext;
  final String chatTemplate;
}

class ChatMessage {
  const ChatMessage(this.role, this.content);
  final String role; // system | user | assistant
  final String content;
}

enum FinishReason { done, stopped, contextFull, maxTokens, error }

class GenerationStats {
  GenerationStats.fromList(List<double> s)
      : promptTokens = s[0].round(),
        promptMs = s[1],
        generatedTokens = s[2].round(),
        generationMs = s[3],
        contextUsed = s[4].round(),
        contextSize = s[5].round(),
        reusedTokens = s[6].round(),
        timeToFirstTokenMs = s[7];

  final int promptTokens;
  final double promptMs;
  final int generatedTokens;
  final double generationMs;
  final int contextUsed;
  final int contextSize;
  final int reusedTokens;
  final double timeToFirstTokenMs;

  double get tokensPerSecond =>
      generationMs > 0 ? generatedTokens * 1000 / generationMs : 0;
  double get promptTokensPerSecond =>
      promptMs > 0 ? promptTokens * 1000 / promptMs : 0;
}

sealed class GenerationEvent {}

class TokenEvent extends GenerationEvent {
  TokenEvent(this.text);
  final String text;
}

class DoneEvent extends GenerationEvent {
  DoneEvent(this.reason, this.stats, [this.error]);
  final FinishReason reason;
  final GenerationStats stats;
  final String? error;
}

/// Was die Agenten-Schleife von einer Engine braucht (in Tests ersetzbar).
abstract interface class AgentBackend {
  int get contextSize;
  Future<String> formatChat(List<ChatMessage> messages, {bool addAssistant = true});
  Future<int> countTokens(String text);
  Stream<GenerationEvent> generate(String prompt,
      {String? grammar, SamplingParams sampling, int maxTokens});
  void stop();
}

/// Öffentliche Schnittstelle zur Engine.
class LlamaEngine implements AgentBackend {
  LlamaEngine._(this._isolate, this._send, this._responses, this.info,
      this._enginePtr, this.config);

  final Isolate _isolate;
  final SendPort _send;
  final Stream<dynamic> _responses;
  final int _enginePtr;
  final ModelInfo info;
  final EngineConfig config;
  int _nextId = 1;
  bool _disposed = false;
  bool _generating = false;
  bool _stopRequested = false;

  bool get isGenerating => _generating;

  @override
  int get contextSize => info.contextSize;

  /// Startet das Engine-Isolate und lädt das Modell.
  static Future<LlamaEngine> load(EngineConfig config) async {
    final receive = ReceivePort();
    final errors = ReceivePort();
    final isolate = await Isolate.spawn(_engineMain, receive.sendPort,
        onError: errors.sendPort, debugName: 'llama-engine');
    final responses = receive.asBroadcastStream();
    errors.listen((e) {
      // Unerwarteter Absturz im Isolate: wird beim nächsten Aufruf sichtbar
    });
    final send = await responses.first as SendPort;

    final completer = Completer<Map>();
    late StreamSubscription sub;
    sub = responses.listen((m) {
      if (m is Map && m['id'] == 0) {
        completer.complete(m);
        sub.cancel();
      }
    });
    send.send({'cmd': 'load', 'id': 0, ...config.toMap()});
    final res = await completer.future;
    if (res['ok'] != true) {
      isolate.kill(priority: Isolate.immediate);
      receive.close();
      errors.close();
      throw EngineException(res['error'] as String? ?? 'Laden fehlgeschlagen');
    }
    final info = ModelInfo.fromJson(
        jsonDecode(res['info'] as String) as Map<String, dynamic>);
    return LlamaEngine._(
        isolate, send, responses, info, res['ptr'] as int, config);
  }

  Future<Map> _call(Map<String, Object?> msg) {
    if (_disposed) throw EngineException('Engine wurde bereits freigegeben');
    final id = _nextId++;
    final c = Completer<Map>();
    late StreamSubscription sub;
    sub = _responses.listen((m) {
      if (m is Map && m['id'] == id) {
        sub.cancel();
        c.complete(m);
      }
    });
    _send.send({...msg, 'id': id});
    return c.future;
  }

  Future<String> formatChat(List<ChatMessage> messages,
      {bool addAssistant = true}) async {
    final r = await _call({
      'cmd': 'format',
      'roles': [for (final m in messages) m.role],
      'contents': [for (final m in messages) m.content],
      'add': addAssistant,
    });
    if (r['ok'] != true) throw EngineException(r['error'] as String);
    return r['text'] as String;
  }

  Future<int> countTokens(String text) async {
    final r = await _call({'cmd': 'count', 'text': text});
    return r['n'] as int;
  }

  Future<String?> validateGrammar(String grammar) async {
    final r = await _call({'cmd': 'grammar', 'text': grammar});
    return r['ok'] == true ? null : (r['error'] as String? ?? 'ungültig');
  }

  /// Streamt die Antwort Stück für Stück. Nur eine Generierung gleichzeitig.
  Stream<GenerationEvent> generate(
    String prompt, {
    String? grammar,
    SamplingParams sampling = const SamplingParams(),
    int maxTokens = 1024,
  }) {
    if (_disposed) throw EngineException('Engine wurde bereits freigegeben');
    if (_generating) throw EngineException('Es läuft bereits eine Generierung');
    _generating = true;
    _stopRequested = false;
    final id = _nextId++;
    final controller = StreamController<GenerationEvent>();
    late StreamSubscription sub;
    sub = _responses.listen((m) {
      if (m is! Map || m['id'] != id) return;
      if (m['type'] == 'tok') {
        controller.add(TokenEvent(m['text'] as String));
      } else if (m['type'] == 'done') {
        var reason = FinishReason.values.byName(m['reason'] as String);
        if (_stopRequested && reason == FinishReason.done) {
          reason = FinishReason.stopped;
        }
        controller.add(DoneEvent(
            reason,
            GenerationStats.fromList((m['stats'] as List).cast<double>()),
            m['error'] as String?));
        _generating = false;
        sub.cancel();
        controller.close();
      }
    });
    _send.send({
      'cmd': 'gen',
      'id': id,
      'prompt': prompt,
      'grammar': grammar ?? '',
      'temp': sampling.temperature,
      'top_p': sampling.topP,
      'min_p': sampling.minP,
      'seed': sampling.seed,
      'max': maxTokens,
    });
    return controller.stream;
  }

  /// Bricht die laufende Generierung sofort ab (direkter FFI-Aufruf,
  /// weil das Engine-Isolate während der Generierung blockiert ist).
  @override
  void stop() {
    if (_disposed || _enginePtr == 0) return;
    _stopRequested = true;
    NativeEngine.instance.stop(Pointer<Void>.fromAddress(_enginePtr));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    stop();
    try {
      await _call({'cmd': 'dispose'}).timeout(const Duration(seconds: 10));
    } catch (_) {}
    _disposed = true;
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  // Speicherabfragen sind thread-sicher und dürfen aus dem UI-Isolate kommen.
  static int totalMemory() => NativeEngine.instance.totalMemory();
  static int availableMemory() => NativeEngine.instance.availableMemory();
  static int processMemory() => NativeEngine.instance.processMemory();
}

// ---------------------------------------------------------------------------
// Isolate-Seite
// ---------------------------------------------------------------------------

void _engineMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final n = NativeEngine.instance;
  Pointer<Void> engine = nullptr;
  final textBuf = nativeAlloc<Uint8>(4096);
  final statsBuf = nativeAlloc<Double>(8 * 8);

  List<double> readStats() {
    n.stats(engine, statsBuf);
    return [for (var i = 0; i < 8; i++) statsBuf[i]];
  }

  String err() => fromNativeUtf8(n.lastError(engine));

  inbox.listen((dynamic msg) {
    final m = msg as Map;
    final id = m['id'];
    switch (m['cmd']) {
      case 'load':
        final path = toNativeUtf8(m['path'] as String);
        final errBuf = nativeAlloc<Uint8>(1024);
        try {
          engine = n.create(path, m['ctx'] as int, m['threads'] as int,
              m['gpu'] as int, m['kvq'] as int, errBuf, 1024);
          if (engine.address == 0) {
            out.send({'id': id, 'ok': false, 'error': fromNativeUtf8(errBuf)});
          } else {
            final info = callWithBuffer((b, l) => n.modelInfo(engine, b, l),
                initial: 16384);
            out.send(
                {'id': id, 'ok': true, 'info': info, 'ptr': engine.address});
          }
        } finally {
          nativeFree(path);
          nativeFree(errBuf);
        }

      case 'format':
        final roles = (m['roles'] as List).cast<String>();
        final contents = (m['contents'] as List).cast<String>();
        final rp = nativeAlloc<Pointer<Uint8>>(roles.length * sizeOf<Pointer>());
        final cp = nativeAlloc<Pointer<Uint8>>(roles.length * sizeOf<Pointer>());
        for (var i = 0; i < roles.length; i++) {
          rp[i] = toNativeUtf8(roles[i]);
          cp[i] = toNativeUtf8(contents[i]);
        }
        try {
          var total = 1024;
          for (final c in contents) {
            total += c.length * 4;
          }
          final text = callWithBuffer(
              (b, l) => n.formatChat(engine, rp, cp, roles.length,
                  m['add'] == true ? 1 : 0, b, l),
              initial: total);
          out.send({'id': id, 'ok': text.isNotEmpty, 'text': text, 'error': err()});
        } finally {
          for (var i = 0; i < roles.length; i++) {
            nativeFree(rp[i]);
            nativeFree(cp[i]);
          }
          nativeFree(rp);
          nativeFree(cp);
        }

      case 'count':
        final t = toNativeUtf8(m['text'] as String);
        out.send({'id': id, 'n': n.countTokens(engine, t)});
        nativeFree(t);

      case 'grammar':
        final t = toNativeUtf8(m['text'] as String);
        final ok = n.validateGrammar(engine, t) == 1;
        out.send({'id': id, 'ok': ok, 'error': ok ? null : err()});
        nativeFree(t);

      case 'gen':
        final prompt = toNativeUtf8(m['prompt'] as String);
        final grammar = toNativeUtf8(m['grammar'] as String);
        try {
          final rc = n.begin(
              engine,
              prompt,
              grammar,
              (m['temp'] as num).toDouble(),
              (m['top_p'] as num).toDouble(),
              (m['min_p'] as num).toDouble(),
              m['seed'] as int,
              m['max'] as int);
          if (rc != 0) {
            out.send({
              'id': id,
              'type': 'done',
              'reason': rc == aeContextFull ? 'contextFull' : 'error',
              'stats': readStats(),
              'error': err(),
            });
            return;
          }
          var produced = 0;
          final maxTokens = m['max'] as int;
          // kleine Stücke bündeln: weniger Nachrichten, flüssigere UI
          final pending = StringBuffer();
          var lastFlush = DateTime.now();
          while (true) {
            final r = n.next(engine, textBuf, 4096);
            if (r >= 0) {
              produced++;
              if (r > 0) pending.write(fromNativeUtf8(textBuf, r));
              final now = DateTime.now();
              if (pending.isNotEmpty &&
                  now.difference(lastFlush).inMilliseconds >= 30) {
                out.send({'id': id, 'type': 'tok', 'text': pending.toString()});
                pending.clear();
                lastFlush = now;
              }
              continue;
            }
            if (pending.isNotEmpty) {
              out.send({'id': id, 'type': 'tok', 'text': pending.toString()});
            }
            final stats = readStats();
            String reason;
            if (r == aeContextFull) {
              reason = 'contextFull';
            } else if (r == aeError) {
              reason = 'error';
            } else if (stats[2].round() >= maxTokens) {
              reason = 'maxTokens';
            } else {
              reason = 'done';
            }
            out.send({
              'id': id,
              'type': 'done',
              'reason': reason,
              'stats': stats,
              'error': r == aeError ? err() : null,
              'produced': produced,
            });
            break;
          }
        } finally {
          nativeFree(prompt);
          nativeFree(grammar);
        }

      case 'dispose':
        if (engine.address != 0) n.destroy(engine);
        engine = nullptr;
        nativeFree(textBuf);
        nativeFree(statsBuf);
        out.send({'id': id, 'ok': true});
        inbox.close();
    }
  });
}
