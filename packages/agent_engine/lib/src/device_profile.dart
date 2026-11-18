// Geräteklassen und RAM-Schutz (SRS Abschnitt 4).

import 'dart:io';
import 'dart:math' as math;

import 'gguf_header.dart';
import 'llama_engine.dart';

enum DeviceClass { s, m, l, xl }

extension DeviceClassLabel on DeviceClass {
  String get label => switch (this) {
        DeviceClass.s => 'S (≤ 4 GB)',
        DeviceClass.m => 'M (6–8 GB)',
        DeviceClass.l => 'L (12–24 GB)',
        DeviceClass.xl => 'XL (≥ 32 GB)',
      };
}

class DeviceProfile {
  DeviceProfile({
    required this.deviceClass,
    required this.totalMemory,
    required this.maxContext,
    required this.threads,
    required this.gpuLayers,
    required this.quantizeKv,
    required this.isMobile,
  });

  final DeviceClass deviceClass;
  final int totalMemory;
  final int maxContext;
  final int threads;
  final int gpuLayers;
  final bool quantizeKv;
  final bool isMobile;

  static const _gb = 1024 * 1024 * 1024;

  /// Ermittelt das Profil des aktuellen Geräts.
  /// [isTablet] nur relevant für die Anzeige; die Klasse hängt am RAM.
  static DeviceProfile detect({int? totalMemoryOverride, int? cpuOverride}) {
    final total = totalMemoryOverride ?? LlamaEngine.totalMemory();
    final cpus = cpuOverride ?? Platform.numberOfProcessors;
    final mobile = Platform.isAndroid || Platform.isIOS;
    final apple = Platform.isIOS || Platform.isMacOS;

    final cls = total <= 4.5 * _gb
        ? DeviceClass.s
        : total <= 9.5 * _gb
            ? DeviceClass.m
            : total <= 26 * _gb
                ? DeviceClass.l
                : DeviceClass.xl;

    final maxCtx = switch (cls) {
      DeviceClass.s => 2048,
      DeviceClass.m => 4096,
      DeviceClass.l => 8192,
      DeviceClass.xl => 16384,
    };

    // Mobil: nur Performance-Kerne (meist 4), Desktop: alle bis auf zwei
    final threads = mobile
        ? math.max(2, math.min(4, cpus))
        : math.max(2, math.min(8, cpus - 2));

    return DeviceProfile(
      deviceClass: cls,
      totalMemory: total,
      maxContext: maxCtx,
      threads: threads,
      gpuLayers: apple ? -1 : 0,
      quantizeKv: cls == DeviceClass.s,
      isMobile: mobile,
    );
  }

  /// Context-Größe begrenzen: auf Klasse und auf das Trainingsfenster.
  int clampContext(int requested, GgufInfo? model) {
    var c = math.min(requested, maxContext);
    final trained = model?.contextLength;
    if (trained != null && trained > 0) c = math.min(c, trained);
    return math.max(512, c);
  }

  EngineConfig engineConfig(String modelPath, int contextSize) => EngineConfig(
        modelPath: modelPath,
        contextSize: contextSize,
        threads: threads,
        gpuLayers: gpuLayers,
        quantizeKvCache: quantizeKv,
      );

  /// Prüft, ob Modell + KV-Cache in den Speicher passen.
  FitResult checkFit(GgufInfo model, int contextSize, {int? availableOverride}) {
    final kv = model.estimateKvCacheBytes(contextSize, quantized: quantizeKv);
    const overhead = 300 * 1024 * 1024; // Rechenpuffer, Laufzeit
    final required = model.fileSize + kv + overhead;

    final reported = availableOverride ?? LlamaEngine.availableMemory();
    // Desktop: freier Speicher wird vom System dynamisch freigeräumt,
    // daher mindestens 60 % des Gesamt-RAM als Budget ansetzen.
    final budget = isMobile
        ? (reported > 0 ? reported : totalMemory ~/ 2)
        : math.max(reported, (totalMemory * 0.6).round());

    final ratio = required / budget;
    if (ratio > 1.0) {
      return FitResult(FitLevel.refuse, required, budget,
          'Das Modell braucht ca. ${_fmt(required)}, verfügbar sind nur ${_fmt(budget)}. '
          'Bitte ein kleineres Modell oder eine stärkere Quantisierung wählen.');
    }
    if (ratio > 0.6) {
      return FitResult(FitLevel.warn, required, budget,
          'Knapp: ca. ${_fmt(required)} von ${_fmt(budget)}. Andere Apps schließen, '
          'Context wird auf ${math.min(contextSize, 2048)} begrenzt.');
    }
    return FitResult(FitLevel.ok, required, budget,
        'Passt: ca. ${_fmt(required)} von ${_fmt(budget)}.');
  }

  static String _fmt(int bytes) => '${(bytes / _gb).toStringAsFixed(1)} GB';
}

enum FitLevel { ok, warn, refuse }

class FitResult {
  FitResult(this.level, this.requiredBytes, this.budgetBytes, this.message);
  final FitLevel level;
  final int requiredBytes;
  final int budgetBytes;
  final String message;
}
