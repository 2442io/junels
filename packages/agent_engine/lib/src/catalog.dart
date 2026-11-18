// Modell-Katalog und Empfehlung je Gerät (Systemcheck).
//
// Alle Downloads kommen direkt von Hugging Face bzw. GitHub-Releases.
// Größen sind Richtwerte aus den Modellseiten (Stand 11/2026).

import 'device_profile.dart';

enum ModelKind { llm, stt, tts }

class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.kind,
    required this.name,
    required this.description,
    required this.url,
    required this.fileName,
    required this.sizeBytes,
    required this.minClass,
    this.idealClass,
    this.language,
    this.isArchive = false,
    this.desktopOnly = false,
  });

  final String id;
  final ModelKind kind;
  final String name;
  final String description;
  final String url;
  final String fileName;
  final int sizeBytes;

  /// Kleinste Geräteklasse, auf der das Modell sinnvoll läuft.
  final DeviceClass minClass;

  /// Klasse, für die das Modell die erste Empfehlung ist.
  final DeviceClass? idealClass;
  final String? language;

  /// tar.bz2-Archiv (Piper-Stimmen inkl. espeak-ng-Daten)
  final bool isArchive;

  /// Nur auf dem Mac empfehlen (z. B. Whisper in voller Präzision)
  final bool desktopOnly;

  String get sizeLabel => sizeBytes >= 1 << 30
      ? '${(sizeBytes / (1 << 30)).toStringAsFixed(1)} GB'
      : '${(sizeBytes / (1 << 20)).round()} MB';

  /// Archive entpacken in diesen Ordner (Name ohne .tar.bz2).
  String get folderName => fileName.replaceAll(RegExp(r'\.tar\.bz2$'), '');
}

const _mb = 1 << 20;

const modelCatalog = <CatalogEntry>[
  // ---------------------------------------------------------------- Sprachmodelle
  CatalogEntry(
    id: 'qwen2.5-0.5b',
    kind: ModelKind.llm,
    name: 'Qwen 2.5 0.5B Instruct',
    description: 'Sehr klein und schnell, für einfache Fragen. Tools nur eingeschränkt.',
    url: 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    fileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    sizeBytes: 491 * _mb,
    minClass: DeviceClass.s,
  ),
  CatalogEntry(
    id: 'qwen2.5-1.5b',
    kind: ModelKind.llm,
    name: 'Qwen 2.5 1.5B Instruct',
    description: 'Guter Kompromiss für Geräte mit wenig RAM.',
    url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    sizeBytes: 1120 * _mb,
    minClass: DeviceClass.s,
    idealClass: DeviceClass.s,
  ),
  CatalogEntry(
    id: 'qwen2.5-3b',
    kind: ModelKind.llm,
    name: 'Qwen 2.5 3B Instruct',
    description: 'Solide Agenten-Fähigkeiten, gutes Deutsch.',
    url: 'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf',
    fileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    sizeBytes: 2100 * _mb,
    minClass: DeviceClass.m,
  ),
  CatalogEntry(
    id: 'qwen3-4b-2507',
    kind: ModelKind.llm,
    name: 'Qwen3 4B Instruct 2507',
    description: 'Bestes Modell dieser Größe für Tool-Aufrufe und Logik.',
    url: 'https://huggingface.co/lmstudio-community/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
    fileName: 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
    sizeBytes: 2500 * _mb,
    minClass: DeviceClass.m,
    idealClass: DeviceClass.m,
  ),
  CatalogEntry(
    id: 'qwen2.5-7b',
    kind: ModelKind.llm,
    name: 'Qwen 2.5 7B Instruct',
    description: 'Deutlich stärker, für Mac und Tablets mit viel RAM.',
    url: 'https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    fileName: 'Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    sizeBytes: 4680 * _mb,
    minClass: DeviceClass.l,
    idealClass: DeviceClass.l,
  ),

  // ------------------------------------------------------- Spracherkennung (Whisper)
  CatalogEntry(
    id: 'whisper-base',
    kind: ModelKind.stt,
    name: 'Whisper base (q5_1)',
    description: 'Klein und schnell, für schwache Geräte. Deutlich ungenauer.',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin',
    fileName: 'ggml-base-q5_1.bin',
    sizeBytes: 57 * _mb,
    minClass: DeviceClass.s,
    idealClass: DeviceClass.s,
  ),
  CatalogEntry(
    id: 'whisper-small',
    kind: ModelKind.stt,
    name: 'Whisper small (q5_1)',
    description: 'Gute Genauigkeit bei moderatem Tempo.',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin',
    fileName: 'ggml-small-q5_1.bin',
    sizeBytes: 181 * _mb,
    minClass: DeviceClass.s,
  ),
  CatalogEntry(
    id: 'whisper-turbo-q5',
    kind: ModelKind.stt,
    name: 'Whisper large-v3-turbo (q5_0)',
    description: 'Fast so genau wie large-v3, ein Drittel der Größe.',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
    fileName: 'ggml-large-v3-turbo-q5_0.bin',
    sizeBytes: 547 * _mb,
    minClass: DeviceClass.m,
    idealClass: DeviceClass.m,
  ),
  CatalogEntry(
    id: 'whisper-turbo',
    kind: ModelKind.stt,
    name: 'Whisper large-v3-turbo (voll)',
    description: 'Beste Genauigkeit, mit Metal-GPU auf dem Mac sehr schnell.',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin',
    fileName: 'ggml-large-v3-turbo.bin',
    sizeBytes: 1549 * _mb,
    minClass: DeviceClass.l,
    idealClass: DeviceClass.l,
    desktopOnly: true,
  ),

  // ---------------------------------------------------------- Stimmen (Piper)
  CatalogEntry(
    id: 'piper-de-thorsten',
    kind: ModelKind.tts,
    name: 'Piper Deutsch – Thorsten (männlich)',
    description: 'Natürliche deutsche Männerstimme, mittlere Qualität.',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-thorsten-medium.tar.bz2',
    fileName: 'vits-piper-de_DE-thorsten-medium.tar.bz2',
    sizeBytes: 64 * _mb,
    minClass: DeviceClass.s,
    idealClass: DeviceClass.s,
    language: 'de',
    isArchive: true,
  ),
  CatalogEntry(
    id: 'piper-de-kerstin',
    kind: ModelKind.tts,
    name: 'Piper Deutsch – Kerstin (weiblich)',
    description: 'Deutsche Frauenstimme, klein und schnell.',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-kerstin-low.tar.bz2',
    fileName: 'vits-piper-de_DE-kerstin-low.tar.bz2',
    sizeBytes: 64 * _mb,
    minClass: DeviceClass.s,
    language: 'de',
    isArchive: true,
  ),
  CatalogEntry(
    id: 'piper-en-amy',
    kind: ModelKind.tts,
    name: 'Piper English – Amy',
    description: 'Englische Frauenstimme für englische Antworten.',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-amy-medium.tar.bz2',
    fileName: 'vits-piper-en_US-amy-medium.tar.bz2',
    sizeBytes: 64 * _mb,
    minClass: DeviceClass.s,
    language: 'en',
    isArchive: true,
  ),
];

enum Suitability { recommended, suitable, tooBig, noSpace }

class Recommendation {
  Recommendation(this.entry, this.suitability, this.reason);
  final CatalogEntry entry;
  final Suitability suitability;
  final String reason;
}

/// Bewertet alle Katalogeinträge einer Art für das Gerät.
/// Reihenfolge: Empfehlung zuerst, dann passende, dann zu große.
List<Recommendation> recommendFor(ModelKind kind, DeviceProfile device, {required int freeDiskBytes}) {
  final entries = modelCatalog.where((e) => e.kind == kind).toList();
  final result = <Recommendation>[];
  CatalogEntry? best;

  // Empfehlung: Eintrag mit idealClass == Geräteklasse; sonst der größte passende
  for (final e in entries) {
    if (e.desktopOnly && device.isMobile) continue;
    if (e.idealClass == device.deviceClass) best ??= e;
  }
  best ??= entries
      .where((e) => e.minClass.index <= device.deviceClass.index && !(e.desktopOnly && device.isMobile))
      .fold<CatalogEntry?>(null, (a, b) => a == null || b.sizeBytes > a.sizeBytes ? b : a);

  for (final e in entries) {
    final needsSpace = e.sizeBytes * (e.isArchive ? 2 : 1) + 200 * _mb;
    Suitability s;
    String reason;
    if (freeDiskBytes >= 0 && freeDiskBytes < needsSpace) {
      s = Suitability.noSpace;
      reason = 'Zu wenig freier Speicher (${e.sizeLabel} nötig)';
    } else if (e.minClass.index > device.deviceClass.index || (e.desktopOnly && device.isMobile)) {
      s = Suitability.tooBig;
      reason = e.desktopOnly && device.isMobile
          ? 'Für den Mac gedacht'
          : 'Braucht Geräteklasse ${e.minClass.label} oder mehr';
    } else if (identical(e, best)) {
      s = Suitability.recommended;
      reason = 'Empfohlen für dieses Gerät';
    } else {
      s = Suitability.suitable;
      reason = 'Läuft auf diesem Gerät';
    }
    result.add(Recommendation(e, s, reason));
  }
  result.sort((a, b) => a.suitability.index.compareTo(b.suitability.index));
  return result;
}
