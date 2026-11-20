// Modell-Katalog und Empfehlung je Gerät (Systemcheck).
//
// Alle Downloads kommen direkt von Hugging Face bzw. GitHub-Releases.
// Größen sind Richtwerte aus den Modellseiten (Stand 11/2026).

import 'device_profile.dart';

enum ModelKind { llm, stt, tts, image }

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
    this.vision = false,
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

  /// Sprachmodell kann Bilder verstehen (Projektor-Datei mmproj-*.gguf im selben Repo).
  final bool vision;

  /// Hugging-Face-Repo (owner/name) aus der URL, sonst null.
  String? get hfRepo {
    final m = RegExp(r'huggingface\.co/([^/]+/[^/]+)/resolve/').firstMatch(url);
    return m?.group(1);
  }

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
    id: 'qwen2.5-1.5b',
    kind: ModelKind.llm,
    name: 'Qwen 2.5 1.5B Instruct',
    description: 'Klein und bewährt, für Geräte mit wenig RAM.',
    url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    sizeBytes: 1120 * _mb,
    minClass: DeviceClass.s,
  ),
  CatalogEntry(
    id: 'qwen3.5-2b',
    kind: ModelKind.llm,
    name: 'Qwen 3.5 2B',
    description: 'Neueste kleine Qwen-Generation, deutlich klüger als 2.5 bei gleicher Größe.',
    url: 'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf',
    fileName: 'Qwen3.5-2B-Q4_K_M.gguf',
    sizeBytes: 1300 * _mb,
    minClass: DeviceClass.s,
    idealClass: DeviceClass.s,
    vision: true,
  ),
  CatalogEntry(
    id: 'gemma-4-e2b',
    kind: ModelKind.llm,
    name: 'Gemma 4 E2B',
    description: 'Googles effizientes Kleinmodell, gutes Deutsch.',
    url: 'https://huggingface.co/lmstudio-community/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf',
    fileName: 'gemma-4-E2B-it-Q4_K_M.gguf',
    sizeBytes: 3430 * _mb,
    minClass: DeviceClass.m,
    vision: true,
  ),
  CatalogEntry(
    id: 'qwen3.5-4b',
    kind: ModelKind.llm,
    name: 'Qwen 3.5 4B',
    description: 'Stark bei Tools und Logik, beste Wahl für Handys und Tablets mit 6–8 GB.',
    url: 'https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf',
    fileName: 'Qwen3.5-4B-Q4_K_M.gguf',
    sizeBytes: 2780 * _mb,
    minClass: DeviceClass.m,
    idealClass: DeviceClass.m,
    vision: true,
  ),
  CatalogEntry(
    id: 'gemma-4-e4b',
    kind: ModelKind.llm,
    name: 'Gemma 4 E4B',
    description: 'Größeres Gemma-Kleinmodell, sehr natürliche Sprache.',
    url: 'https://huggingface.co/lmstudio-community/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf',
    fileName: 'gemma-4-E4B-it-Q4_K_M.gguf',
    sizeBytes: 5340 * _mb,
    minClass: DeviceClass.l,
    vision: true,
  ),
  CatalogEntry(
    id: 'qwen3.5-9b',
    kind: ModelKind.llm,
    name: 'Qwen 3.5 9B',
    description: 'Sehr guter Allrounder für Mac und starke Tablets.',
    url: 'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf',
    fileName: 'Qwen3.5-9B-Q4_K_M.gguf',
    sizeBytes: 6170 * _mb,
    minClass: DeviceClass.l,
    idealClass: DeviceClass.l,
    vision: true,
  ),
  CatalogEntry(
    id: 'gemma-4-12b',
    kind: ModelKind.llm,
    name: 'Gemma 4 12B',
    description: 'Googles mittleres Modell, stark in Sprache und Wissen.',
    url: 'https://huggingface.co/lmstudio-community/gemma-4-12B-it-GGUF/resolve/main/gemma-4-12B-it-Q4_K_M.gguf',
    fileName: 'gemma-4-12B-it-Q4_K_M.gguf',
    sizeBytes: 7380 * _mb,
    minClass: DeviceClass.l,
    vision: true,
  ),
  CatalogEntry(
    id: 'gemma-4-26b-a4b',
    kind: ModelKind.llm,
    name: 'Gemma 4 26B A4B (MoE)',
    description: 'Großes Mixture-of-Experts-Modell: Qualität eines 26B, Tempo eines 4B. Für Macs ab 32 GB.',
    url: 'https://huggingface.co/lmstudio-community/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-Q4_K_M.gguf',
    fileName: 'gemma-4-26B-A4B-it-Q4_K_M.gguf',
    sizeBytes: 16800 * _mb,
    minClass: DeviceClass.xl,
    idealClass: DeviceClass.xl,
    desktopOnly: true,
    vision: true,
  ),

  // ---------------------------------------------------------- Bildgenerierung
  CatalogEntry(
    id: 'sd-turbo',
    kind: ModelKind.image,
    name: 'SD-Turbo (Stable Diffusion 2.1, q8_0)',
    description: 'Fotos und Illustrationen in 1–4 Schritten, 512 × 512. Am Mac Sekunden, am Handy 1–3 Minuten.',
    url: 'https://huggingface.co/Green-Sky/SD-Turbo-GGUF/resolve/main/sd_turbo-f16-q8_0.gguf',
    fileName: 'sd_turbo-f16-q8_0.gguf',
    sizeBytes: 2020 * _mb,
    minClass: DeviceClass.m,
    idealClass: DeviceClass.m,
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
    description: 'Gute Genauigkeit bei moderatem Tempo – die beste Wahl für Gespräche am Handy.',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin',
    fileName: 'ggml-small-q5_1.bin',
    sizeBytes: 181 * _mb,
    minClass: DeviceClass.s,
  ),
  CatalogEntry(
    id: 'whisper-turbo-q5',
    kind: ModelKind.stt,
    name: 'Whisper large-v3-turbo (q5_0)',
    description: 'Fast so genau wie large-v3, ein Drittel der Größe. Am Handy für Gespräche zu langsam.',
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
    id: 'kokoro-de-martin',
    kind: ModelKind.tts,
    name: 'Kokoro Deutsch – Martin (männlich)',
    description: 'Sehr natürliche deutsche Stimme (Kokoro-82M, Fine-Tune „Martin“). Größer und etwas langsamer '
        'als Piper – am Mac und auf schnellen Handys die schönste Stimme.',
    url: 'https://github.com/2442io/junels/releases/download/stimmen/kokoro-de-martin.tar.bz2',
    fileName: 'kokoro-de-martin.tar.bz2',
    sizeBytes: 330 * _mb,
    minClass: DeviceClass.m,
    language: 'de',
    isArchive: true,
  ),
  CatalogEntry(
    id: 'kokoro-de-victoria',
    kind: ModelKind.tts,
    name: 'Kokoro Deutsch – Victoria (weiblich)',
    description: 'Sehr natürliche deutsche Frauenstimme (Kokoro-82M, Fine-Tune „Victoria“, kompakt).',
    url: 'https://github.com/2442io/junels/releases/download/stimmen/kokoro-de-victoria.tar.bz2',
    fileName: 'kokoro-de-victoria.tar.bz2',
    sizeBytes: 100 * _mb,
    minClass: DeviceClass.m,
    language: 'de',
    isArchive: true,
  ),
  CatalogEntry(
    id: 'piper-de-thorsten-high',
    kind: ModelKind.tts,
    name: 'Piper Deutsch – Thorsten HD (männlich)',
    description: 'Thorsten in hoher Qualität – klarer, etwas größer.',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-thorsten-high.tar.bz2',
    fileName: 'vits-piper-de_DE-thorsten-high.tar.bz2',
    sizeBytes: 110 * _mb,
    minClass: DeviceClass.s,
    language: 'de',
    isArchive: true,
  ),
  CatalogEntry(
    id: 'piper-de-eva',
    kind: ModelKind.tts,
    name: 'Piper Deutsch – Eva (weiblich)',
    description: 'Sehr kleine, schnelle Frauenstimme.',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-eva_k-x_low.tar.bz2',
    fileName: 'vits-piper-de_DE-eva_k-x_low.tar.bz2',
    sizeBytes: 25 * _mb,
    minClass: DeviceClass.s,
    language: 'de',
    isArchive: true,
  ),
  CatalogEntry(
    id: 'piper-de-ramona',
    kind: ModelKind.tts,
    name: 'Piper Deutsch – Ramona (weiblich)',
    description: 'Deutsche Frauenstimme.',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-ramona-low.tar.bz2',
    fileName: 'vits-piper-de_DE-ramona-low.tar.bz2',
    sizeBytes: 63 * _mb,
    minClass: DeviceClass.s,
    language: 'de',
    isArchive: true,
  ),
  CatalogEntry(
    id: 'piper-de-karlsson',
    kind: ModelKind.tts,
    name: 'Piper Deutsch – Karlsson (männlich)',
    description: 'Deutsche Männerstimme.',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-karlsson-low.tar.bz2',
    fileName: 'vits-piper-de_DE-karlsson-low.tar.bz2',
    sizeBytes: 63 * _mb,
    minClass: DeviceClass.s,
    language: 'de',
    isArchive: true,
  ),
  CatalogEntry(
    id: 'piper-de-pavoque',
    kind: ModelKind.tts,
    name: 'Piper Deutsch – Pavoque (männlich)',
    description: 'Deutsche Männerstimme.',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-pavoque-low.tar.bz2',
    fileName: 'vits-piper-de_DE-pavoque-low.tar.bz2',
    sizeBytes: 64 * _mb,
    minClass: DeviceClass.s,
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
List<Recommendation> recommendFor(ModelKind kind, DeviceProfile device,
    {required int freeDiskBytes, int? availableMemory}) {
  final entries = modelCatalog.where((e) => e.kind == kind).toList();
  final result = <Recommendation>[];
  CatalogEntry? best;

  // Arbeitsspeicher: gleiche Rechnung wie beim Laden, damit nichts empfohlen wird,
  // das danach abgelehnt wird. Stimmen (Piper) sind klein und laufen immer.
  final budget = kind == ModelKind.tts ? 1 << 62 : device.memoryBudget(availableMemory);
  // Bildmodelle: Rechenpuffer kommen dazu (ca. 1 GB bei 512 × 512)
  bool memOk(CatalogEntry e) =>
      DeviceProfile.estimateRuntimeBytes(e.sizeBytes) + (e.kind == ModelKind.image ? 700 * _mb : 0) <= budget;
  bool runs(CatalogEntry e) =>
      e.minClass.index <= device.deviceClass.index && !(e.desktopOnly && device.isMobile) && memOk(e);

  // Empfehlung: Eintrag mit idealClass == Geräteklasse; passt der nicht in den
  // Arbeitsspeicher, die Empfehlung der nächstkleineren Klasse; sonst der größte passende
  // Handy: für flüssige Gespräche Whisper small statt turbo (CPU-Encoder ist sonst zu langsam)
  if (kind == ModelKind.stt && device.isMobile && device.deviceClass.index >= DeviceClass.m.index) {
    best = entries.where((e) => e.id == 'whisper-small' && runs(e)).firstOrNull;
  }
  for (var c = device.deviceClass.index; c >= 0 && best == null; c--) {
    for (final e in entries) {
      if (e.idealClass?.index == c && runs(e)) {
        best = e;
        break;
      }
    }
  }
  best ??= entries.where(runs).fold<CatalogEntry?>(null, (a, b) => a == null || b.sizeBytes > a.sizeBytes ? b : a);
  String gb(int b) => (b / (1 << 30)).toStringAsFixed(1);

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
    } else if (!memOk(e)) {
      s = Suitability.tooBig;
      reason = 'Braucht ca. ${gb(DeviceProfile.estimateRuntimeBytes(e.sizeBytes))} GB Arbeitsspeicher, '
          'nutzbar sind ca. ${gb(budget)} GB';
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
