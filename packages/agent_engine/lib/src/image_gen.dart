// Bildgenerierung (stable-diffusion.cpp) in einem eigenen Isolate.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'bindings.dart';
import 'documents/raster.dart';

class ImageGenException implements Exception {
  ImageGenException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Einstellungen für ein Bild.
class ImageRequest {
  const ImageRequest(this.prompt,
      {this.negative = '', this.width = 512, this.height = 512, this.steps = 4, this.cfg = 1.0, this.seed = -1, this.method = 'euler_a'});
  final String prompt;
  final String negative;
  final int width;
  final int height;
  final int steps;
  final double cfg;
  final int seed;
  final String method;
}

class ImageEngine {
  ImageEngine._(this._isolate, this._send, this._responses, this._ptr, this.modelPath);

  final Isolate _isolate;
  final SendPort _send;
  final Stream<dynamic> _responses;
  final int _ptr;
  final String modelPath;
  int _nextId = 1;
  bool _busy = false;
  bool _disposed = false;

  bool get busy => _busy;

  /// Ist die Bildgenerierung in dieser App-Version eingebaut?
  static bool get available {
    try {
      return NativeEngine.instance.hasImageGen;
    } catch (_) {
      return false;
    }
  }

  static Future<ImageEngine> load(String modelPath, {int threads = 4, bool vaeTiling = false}) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_imageMain, receive.sendPort, debugName: 'image-engine');
    final responses = receive.asBroadcastStream();
    final send = await responses.first as SendPort;
    final c = Completer<Map>();
    final sub = responses.listen((m) {
      if (m is Map && m['id'] == 0 && !c.isCompleted) c.complete(m);
    });
    send.send({'cmd': 'load', 'id': 0, 'path': modelPath, 'threads': threads, 'tiling': vaeTiling ? 1 : 0});
    final r = await c.future;
    await sub.cancel();
    if (r['ok'] != true) {
      isolate.kill(priority: Isolate.immediate);
      receive.close();
      throw ImageGenException(r['error'] as String? ?? 'Bildmodell konnte nicht geladen werden');
    }
    return ImageEngine._(isolate, send, responses, r['ptr'] as int, modelPath);
  }

  /// Erzeugt ein Bild. [onProgress] meldet (Schritt, Schritte) etwa alle 0,5 s.
  Future<RasterImage> generate(ImageRequest req, {void Function(int step, int steps)? onProgress}) async {
    if (_disposed) throw ImageGenException('Bild-Engine wurde freigegeben');
    if (_busy) throw ImageGenException('Es wird bereits ein Bild erzeugt');
    _busy = true;
    final id = _nextId++;
    final c = Completer<Map>();
    final sub = _responses.listen((m) {
      if (m is Map && m['id'] == id && !c.isCompleted) c.complete(m);
    });
    Timer? timer;
    if (onProgress != null) {
      timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final p = progress();
        onProgress(p.$1, p.$2);
      });
    }
    try {
      _send.send({
        'cmd': 'gen',
        'id': id,
        'prompt': req.prompt,
        'negative': req.negative,
        'w': req.width,
        'h': req.height,
        'steps': req.steps,
        'cfg': req.cfg,
        'seed': req.seed < 0 ? DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFF : req.seed,
        'method': req.method,
      });
      final r = await c.future;
      if (r['ok'] == 'cancelled') throw ImageGenException('Bildgenerierung abgebrochen');
      if (r['ok'] != true) throw ImageGenException(r['error'] as String? ?? 'Bildgenerierung fehlgeschlagen');
      final rgb = (r['rgb'] as TransferableTypedData).materialize().asUint8List();
      return RasterImage(r['w'] as int, r['h'] as int, rgb);
    } finally {
      timer?.cancel();
      await sub.cancel();
      _busy = false;
    }
  }

  /// Bricht die laufende Generierung ab (direkt per FFI).
  void cancel() {
    if (_disposed || _ptr == 0) return;
    NativeEngine.instance.imgCancel(Pointer<Void>.fromAddress(_ptr));
  }

  /// (Schritt, Schritte) der laufenden Generierung.
  static (int, int) progress() {
    final a = nativeAlloc<Int32>(8);
    try {
      NativeEngine.instance.imgProgress(a, a + 1);
      return (a[0], a[1]);
    } finally {
      nativeFree(a);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    cancel();
    final c = Completer<void>();
    final sub = _responses.listen((m) {
      if (m is Map && m['id'] == -1 && !c.isCompleted) c.complete();
    });
    _send.send({'cmd': 'dispose', 'id': -1});
    try {
      await c.future.timeout(const Duration(seconds: 15));
    } catch (_) {}
    await sub.cancel();
    _disposed = true;
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

void _imageMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final n = NativeEngine.instance;
  Pointer<Void> ctx = nullptr;
  inbox.listen((dynamic msg) {
    final m = msg as Map;
    final id = m['id'];
    switch (m['cmd']) {
      case 'load':
        final path = toNativeUtf8(m['path'] as String);
        final err = nativeAlloc<Uint8>(1024);
        try {
          ctx = n.imgCreate(path, m['threads'] as int, m['tiling'] as int, err, 1024);
          if (ctx.address == 0) {
            out.send({'id': id, 'ok': false, 'error': fromNativeUtf8(err)});
          } else {
            out.send({'id': id, 'ok': true, 'ptr': ctx.address});
          }
        } finally {
          nativeFree(path);
          nativeFree(err);
        }
      case 'gen':
        final prompt = toNativeUtf8(m['prompt'] as String);
        final neg = toNativeUtf8(m['negative'] as String);
        final method = toNativeUtf8(m['method'] as String);
        final outPtr = nativeAlloc<Pointer<Uint8>>(sizeOf<Pointer>());
        final dims = nativeAlloc<Int32>(8);
        try {
          final rc = n.imgGenerate(ctx, prompt, neg, m['w'] as int, m['h'] as int, m['steps'] as int,
              (m['cfg'] as num).toDouble(), m['seed'] as int, method, 0, outPtr, dims, dims + 1);
          if (rc == 0) {
            final w = dims[0], h = dims[1];
            final data = Uint8List.fromList(outPtr.value.asTypedList(w * h * 3));
            n.freeBuffer(outPtr.value.cast());
            out.send({'id': id, 'ok': true, 'w': w, 'h': h, 'rgb': TransferableTypedData.fromList([data])});
          } else if (rc == 1) {
            out.send({'id': id, 'ok': 'cancelled'});
          } else {
            out.send({'id': id, 'ok': false, 'error': fromNativeUtf8(n.imgLastError(ctx))});
          }
        } finally {
          nativeFree(prompt);
          nativeFree(neg);
          nativeFree(method);
          nativeFree(outPtr);
          nativeFree(dims);
        }
      case 'dispose':
        if (ctx.address != 0) n.imgDestroy(ctx);
        ctx = nullptr;
        out.send({'id': id, 'ok': true});
        inbox.close();
    }
  });
}
