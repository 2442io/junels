// Rohe FFI-Bindings an libagent_engine (siehe src/agent_engine.h).
// Ohne package:ffi, damit das Paket keine Pub-Abhängigkeiten braucht.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

typedef _CreateN = Pointer<Void> Function(
    Pointer<Uint8>, Int32, Int32, Int32, Int32, Pointer<Uint8>, Int32);
typedef _CreateD = Pointer<Void> Function(
    Pointer<Uint8>, int, int, int, int, Pointer<Uint8>, int);
typedef _VoidPtrN = Void Function(Pointer<Void>);
typedef _VoidPtrD = void Function(Pointer<Void>);
typedef _InfoN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32);
typedef _InfoD = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _FormatN = Int32 Function(Pointer<Void>, Pointer<Pointer<Uint8>>,
    Pointer<Pointer<Uint8>>, Int32, Int32, Pointer<Uint8>, Int32);
typedef _FormatD = int Function(Pointer<Void>, Pointer<Pointer<Uint8>>,
    Pointer<Pointer<Uint8>>, int, int, Pointer<Uint8>, int);
typedef _CountN = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _CountD = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _BeginN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>,
    Float, Float, Float, Int32, Int32);
typedef _BeginD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>,
    double, double, double, int, int);
typedef _StatsN = Void Function(Pointer<Void>, Pointer<Double>);
typedef _StatsD = void Function(Pointer<Void>, Pointer<Double>);
typedef _ErrN = Pointer<Uint8> Function(Pointer<Void>);
typedef _MemN = Int64 Function();
typedef _MemD = int Function();
typedef _VerN = Int32 Function();
typedef _VerD = int Function();
typedef _SttCreateN = Pointer<Void> Function(Pointer<Uint8>, Int32, Pointer<Uint8>, Int32);
typedef _SttCreateD = Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _SttTransN = Int32 Function(Pointer<Void>, Pointer<Float>, Int32, Pointer<Uint8>, Int32, Pointer<Uint8>, Int32);
typedef _SttTransD = int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _DiskN = Int64 Function(Pointer<Uint8>);
typedef _DiskD = int Function(Pointer<Uint8>);
typedef _MarkerN = Pointer<Uint8> Function();
typedef _VisionLoadN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Int32);
typedef _VisionLoadD = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _VisionBeginN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Uint8>>, Int32, Float, Int32);
typedef _VisionBeginD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Uint8>>, int, double, int);
typedef _ImgCreateN = Pointer<Void> Function(Pointer<Uint8>, Int32, Int32, Pointer<Uint8>, Int32);
typedef _ImgCreateD = Pointer<Void> Function(Pointer<Uint8>, int, int, Pointer<Uint8>, int);
typedef _ImgGenN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, Int32, Int32, Int32, Float, Int64,
    Pointer<Uint8>, Int32, Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>);
typedef _ImgGenD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, int, int, int, double, int,
    Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>);
typedef _ImgProgN = Void Function(Pointer<Int32>, Pointer<Int32>);
typedef _ImgProgD = void Function(Pointer<Int32>, Pointer<Int32>);
typedef _StateN = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _StateD = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _MallocN = Pointer<Void> Function(IntPtr);
typedef _MallocD = Pointer<Void> Function(int);
typedef _FreeN = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);

const int aeDone = -1;
const int aeError = -2;
const int aeContextFull = -3;

/// Lädt die native Bibliothek je Plattform.
/// Mit der Umgebungsvariable AE_LIB_PATH kann ein Pfad erzwungen werden (Tests).
DynamicLibrary openEngineLibrary() {
  final override = Platform.environment['AE_LIB_PATH'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libagent_engine.so');
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('AgentEngine.framework/AgentEngine');
  }
  if (Platform.isWindows) return DynamicLibrary.open('agent_engine.dll');
  throw UnsupportedError('Plattform nicht unterstützt');
}

class NativeEngine {
  NativeEngine._(DynamicLibrary lib)
      : version = lib.lookupFunction<_VerN, _VerD>('ae_version'),
        create = lib.lookupFunction<_CreateN, _CreateD>('ae_create'),
        destroy = lib.lookupFunction<_VoidPtrN, _VoidPtrD>('ae_destroy'),
        modelInfo = lib.lookupFunction<_InfoN, _InfoD>('ae_model_info'),
        formatChat = lib.lookupFunction<_FormatN, _FormatD>('ae_format_chat'),
        countTokens = lib.lookupFunction<_CountN, _CountD>('ae_count_tokens'),
        validateGrammar =
            lib.lookupFunction<_CountN, _CountD>('ae_validate_grammar'),
        begin = lib.lookupFunction<_BeginN, _BeginD>('ae_begin'),
        next = lib.lookupFunction<_InfoN, _InfoD>('ae_next'),
        stop = lib.lookupFunction<_VoidPtrN, _VoidPtrD>('ae_stop'),
        stats = lib.lookupFunction<_StatsN, _StatsD>('ae_stats'),
        lastError = lib.lookupFunction<_ErrN, _ErrN>('ae_last_error'),
        totalMemory = lib.lookupFunction<_MemN, _MemD>('ae_total_memory'),
        availableMemory =
            lib.lookupFunction<_MemN, _MemD>('ae_available_memory'),
        processMemory = lib.lookupFunction<_MemN, _MemD>('ae_process_memory'),
        sttCreate = lib.lookupFunction<_SttCreateN, _SttCreateD>('ae_stt_create'),
        sttDestroy = lib.lookupFunction<_VoidPtrN, _VoidPtrD>('ae_stt_destroy'),
        sttTranscribe = lib.lookupFunction<_SttTransN, _SttTransD>('ae_stt_transcribe'),
        sttLanguage = lib.lookupFunction<_ErrN, _ErrN>('ae_stt_language'),
        sttStop = lib.lookupFunction<_VoidPtrN, _VoidPtrD>('ae_stt_stop'),
        sttLastError = lib.lookupFunction<_ErrN, _ErrN>('ae_stt_last_error'),
        freeDisk = lib.lookupFunction<_DiskN, _DiskD>('ae_free_disk'),
        visionMarker = lib.lookupFunction<_MarkerN, _MarkerN>('ae_vision_marker'),
        visionLoad = lib.lookupFunction<_VisionLoadN, _VisionLoadD>('ae_vision_load'),
        visionBegin = lib.lookupFunction<_VisionBeginN, _VisionBeginD>('ae_vision_begin'),
        _lib = lib;

  final DynamicLibrary _lib;

  /// Bildgenerierung ist optional (nicht jede Bibliothek enthält sie).
  bool get hasImageGen => _lib.providesSymbol('ae_img_create');
  late final imgCreate = _lib.lookupFunction<_ImgCreateN, _ImgCreateD>('ae_img_create');
  late final imgDestroy = _lib.lookupFunction<_VoidPtrN, _VoidPtrD>('ae_img_destroy');
  late final imgGenerate = _lib.lookupFunction<_ImgGenN, _ImgGenD>('ae_img_generate');
  late final imgCancel = _lib.lookupFunction<_VoidPtrN, _VoidPtrD>('ae_img_cancel');
  late final imgProgress = _lib.lookupFunction<_ImgProgN, _ImgProgD>('ae_img_progress');
  late final imgLastError = _lib.lookupFunction<_ErrN, _ErrN>('ae_img_last_error');
  late final freeBuffer = _lib.lookupFunction<_VoidPtrN, _VoidPtrD>('ae_free');
  late final stateSave = _lib.lookupFunction<_StateN, _StateD>('ae_state_save');
  late final stateLoad = _lib.lookupFunction<_StateN, _StateD>('ae_state_load');

  static NativeEngine? _instance;

  /// Eine Instanz pro Isolate.
  static NativeEngine get instance =>
      _instance ??= NativeEngine._(openEngineLibrary());

  final _VerD version;
  final _CreateD create;
  final _VoidPtrD destroy;
  final _InfoD modelInfo;
  final _FormatD formatChat;
  final _CountD countTokens;
  final _CountD validateGrammar;
  final _BeginD begin;
  final _InfoD next;
  final _VoidPtrD stop;
  final _StatsD stats;
  final _ErrN lastError;
  final _MemD totalMemory;
  final _MemD availableMemory;
  final _MemD processMemory;
  final _SttCreateD sttCreate;
  final _VoidPtrD sttDestroy;
  final _SttTransD sttTranscribe;
  final _ErrN sttLanguage;
  final _VoidPtrD sttStop;
  final _ErrN sttLastError;
  final _DiskD freeDisk;
  final _MarkerN visionMarker;
  final _VisionLoadD visionLoad;
  final _VisionBeginD visionBegin;
}

// ---------------------------------------------------------------------------
// Minimaler Speicher- und UTF-8-Helfer (statt package:ffi)
// ---------------------------------------------------------------------------

final DynamicLibrary _libc = DynamicLibrary.process();
final _MallocD _malloc = _libc.lookupFunction<_MallocN, _MallocD>('malloc');
final _FreeD _free = _libc.lookupFunction<_FreeN, _FreeD>('free');

Pointer<T> nativeAlloc<T extends NativeType>(int bytes) {
  final p = _malloc(bytes < 1 ? 1 : bytes);
  if (p.address == 0) throw StateError('malloc fehlgeschlagen ($bytes Bytes)');
  return p.cast<T>();
}

void nativeFree(Pointer p) {
  if (p.address != 0) _free(p.cast());
}

/// Kopiert einen Dart-String als NUL-terminiertes UTF-8 in nativen Speicher.
Pointer<Uint8> toNativeUtf8(String s) {
  final bytes = utf8.encode(s);
  final p = nativeAlloc<Uint8>(bytes.length + 1);
  final view = p.asTypedList(bytes.length + 1);
  view.setAll(0, bytes);
  view[bytes.length] = 0;
  return p;
}

/// Liest [length] Bytes (oder bis NUL, wenn length < 0) als UTF-8.
String fromNativeUtf8(Pointer<Uint8> p, [int length = -1]) {
  if (p.address == 0) return '';
  if (length < 0) {
    length = 0;
    while (p[length] != 0) {
      length++;
    }
  }
  return utf8.decode(Uint8List.fromList(p.asTypedList(length)),
      allowMalformed: true);
}

/// Ruft eine C-Funktion mit Ausgabepuffer auf, die die benötigte Länge
/// zurückgibt, und vergrößert den Puffer bei Bedarf.
String callWithBuffer(int Function(Pointer<Uint8> buf, int len) fn,
    {int initial = 4096}) {
  var size = initial;
  for (var attempt = 0; attempt < 3; attempt++) {
    final buf = nativeAlloc<Uint8>(size);
    try {
      final n = fn(buf, size);
      if (n < 0) return '';
      if (n < size) return fromNativeUtf8(buf, n);
      size = n + 1;
    } finally {
      nativeFree(buf);
    }
  }
  return '';
}
