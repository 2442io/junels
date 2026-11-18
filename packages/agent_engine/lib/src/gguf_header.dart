// Liest den Kopf einer GGUF-Datei, ohne das Modell zu laden.
// Damit prüft die App vor dem Laden Format, Architektur und Speicherbedarf.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class GgufFormatException implements Exception {
  GgufFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GgufInfo {
  GgufInfo({
    required this.path,
    required this.fileSize,
    required this.version,
    required this.tensorCount,
    required this.metadata,
  });

  final String path;
  final int fileSize;
  final int version;
  final int tensorCount;

  /// Alle skalaren Metadaten; Arrays nur als Länge ("<array:N>").
  final Map<String, Object> metadata;

  String get architecture => metadata['general.architecture'] as String? ?? '?';
  String get name =>
      metadata['general.name'] as String? ?? path.split(Platform.pathSeparator).last;
  String? get sizeLabel => metadata['general.size_label'] as String?;

  int? _archInt(String key) {
    final v = metadata['$architecture.$key'];
    return v is int ? v : null;
  }

  int? get contextLength => _archInt('context_length');
  int? get blockCount => _archInt('block_count');
  int? get embeddingLength => _archInt('embedding_length');
  int? get headCount => _archInt('attention.head_count');
  int? get headCountKv => _archInt('attention.head_count_kv') ?? headCount;
  int? get keyLength => _archInt('attention.key_length');
  int? get valueLength => _archInt('attention.value_length');

  String get quantization {
    final ft = metadata['general.file_type'];
    return ft is int ? (_fileTypes[ft] ?? 'Typ $ft') : '?';
  }

  bool get hasChatTemplate => metadata.containsKey('tokenizer.chat_template');

  /// Geschätzte Größe des KV-Caches in Bytes für [nCtx] Tokens.
  int estimateKvCacheBytes(int nCtx, {bool quantized = false}) {
    final layers = blockCount ?? 32;
    final heads = headCount ?? 32;
    final kvHeads = headCountKv ?? heads;
    final embd = embeddingLength ?? 4096;
    final kDim = keyLength ?? (embd ~/ heads);
    final vDim = valueLength ?? (embd ~/ heads);
    final bytesPerElem = quantized ? 1.0625 : 2.0; // q8_0 vs f16
    return (layers * nCtx * kvHeads * (kDim + vDim) * bytesPerElem).round();
  }

  static const _fileTypes = {
    0: 'F32', 1: 'F16', 2: 'Q4_0', 3: 'Q4_1', 7: 'Q8_0', 8: 'Q5_0', 9: 'Q5_1',
    10: 'Q2_K', 11: 'Q3_K_S', 12: 'Q3_K_M', 13: 'Q3_K_L', 14: 'Q4_K_S',
    15: 'Q4_K_M', 16: 'Q5_K_S', 17: 'Q5_K_M', 18: 'Q6_K', 19: 'IQ2_XXS',
    20: 'IQ2_XS', 21: 'Q2_K_S', 22: 'IQ3_XS', 23: 'IQ3_XXS', 24: 'IQ1_S',
    25: 'IQ4_NL', 26: 'IQ3_S', 27: 'IQ3_M', 28: 'IQ2_S', 29: 'IQ2_M',
    30: 'IQ4_XS', 31: 'IQ1_M', 32: 'BF16', 36: 'TQ1_0', 37: 'TQ2_0',
    38: 'MXFP4',
  };

  /// Liest den Kopf. Wirft [GgufFormatException] bei ungültigen Dateien.
  static Future<GgufInfo> read(String path) async {
    final file = File(path);
    if (!await file.exists()) throw GgufFormatException('Datei nicht gefunden');
    final size = await file.length();
    final raf = await file.open();
    try {
      final r = _Reader(raf);
      final magic = await r.bytes(4);
      if (utf8.decode(magic, allowMalformed: true) != 'GGUF') {
        throw GgufFormatException('Keine GGUF-Datei (falsche Kennung)');
      }
      final version = await r.u32();
      if (version < 2 || version > 3) {
        throw GgufFormatException('GGUF-Version $version wird nicht unterstützt');
      }
      final tensorCount = await r.u64();
      final kvCount = await r.u64();
      if (kvCount > 100000) throw GgufFormatException('Beschädigter GGUF-Kopf');
      final meta = <String, Object>{};
      for (var i = 0; i < kvCount; i++) {
        final key = await r.string();
        final type = await r.u32();
        meta[key] = await r.value(type);
      }
      return GgufInfo(
          path: path,
          fileSize: size,
          version: version,
          tensorCount: tensorCount,
          metadata: meta);
    } on RangeError {
      throw GgufFormatException('GGUF-Datei ist unvollständig');
    } finally {
      await raf.close();
    }
  }
}

class _Reader {
  _Reader(this.raf);
  final RandomAccessFile raf;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;

  Future<void> _ensure(int n) async {
    if (_buf.length - _pos >= n) return;
    final rest = _buf.sublist(_pos);
    final chunk = await raf.read(n > 65536 ? n : 65536);
    if (rest.length + chunk.length < n) throw RangeError('EOF');
    _buf = Uint8List.fromList([...rest, ...chunk]);
    _pos = 0;
  }

  Future<Uint8List> bytes(int n) async {
    await _ensure(n);
    final b = Uint8List.sublistView(_buf, _pos, _pos + n);
    _pos += n;
    return b;
  }

  Future<ByteData> _bd(int n) async => ByteData.sublistView(await bytes(n));
  Future<int> u8() async => (await _bd(1)).getUint8(0);
  Future<int> u32() async => (await _bd(4)).getUint32(0, Endian.little);
  Future<int> u64() async => (await _bd(8)).getUint64(0, Endian.little);

  Future<String> string() async {
    final len = await u64();
    if (len > 50 * 1024 * 1024) throw GgufFormatException('Zeichenkette zu lang');
    return utf8.decode(await bytes(len), allowMalformed: true);
  }

  Future<void> skip(int n) async {
    while (n > 0) {
      final step = n > 65536 ? 65536 : n;
      await bytes(step);
      n -= step;
    }
  }

  static const _sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8};

  Future<Object> value(int type) async {
    final bd = _sizes.containsKey(type) ? await _bd(_sizes[type]!) : null;
    switch (type) {
      case 0: return bd!.getUint8(0);
      case 1: return bd!.getInt8(0);
      case 2: return bd!.getUint16(0, Endian.little);
      case 3: return bd!.getInt16(0, Endian.little);
      case 4: return bd!.getUint32(0, Endian.little);
      case 5: return bd!.getInt32(0, Endian.little);
      case 6: return bd!.getFloat32(0, Endian.little);
      case 7: return bd!.getUint8(0) != 0;
      case 10: return bd!.getUint64(0, Endian.little);
      case 11: return bd!.getInt64(0, Endian.little);
      case 12: return bd!.getFloat64(0, Endian.little);
      case 8: return string();
      case 9:
        final itemType = await u32();
        final count = await u64();
        if (itemType == 8) {
          for (var i = 0; i < count; i++) {
            await skip(await u64());
          }
        } else if (_sizes.containsKey(itemType)) {
          await skip(count * _sizes[itemType]!);
        } else {
          throw GgufFormatException('Verschachtelte Arrays nicht unterstützt');
        }
        return '<array:$count>';
      default:
        throw GgufFormatException('Unbekannter Werttyp $type');
    }
  }
}
