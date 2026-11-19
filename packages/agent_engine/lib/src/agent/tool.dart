// Grundtypen für lokale Agenten-Tools.

enum ParamType { string, integer, number, boolean, enumeration }

class ToolParam {
  const ToolParam(this.name, this.type, this.description, {this.values = const []});
  final String name;
  final ParamType type;
  final String description;

  /// Erlaubte Werte bei [ParamType.enumeration].
  final List<String> values;

  String get typeLabel => switch (type) {
        ParamType.string => 'string',
        ParamType.integer => 'integer',
        ParamType.number => 'number',
        ParamType.boolean => 'boolean',
        ParamType.enumeration => values.map((v) => '"$v"').join(' | '),
      };
}

/// Eine vom Nutzer angehängte Datei (Text bereits extrahiert).
class Attachment {
  const Attachment({required this.name, required this.content, this.path});
  final String name;
  final String content;
  final String? path;
}

/// Ergebnis, das im Inspector-Panel erscheint.
class Artifact {
  Artifact({required this.title, required this.kind, required this.content, DateTime? created})
      : created = created ?? DateTime.now();
  final String title;
  final String kind; // code | markdown | table | json | text
  final String content;
  final DateTime created;

  Map<String, Object> toJson() => {
        'title': title,
        'kind': kind,
        'content': content,
        'created': created.toIso8601String(),
      };

  factory Artifact.fromJson(Map<String, dynamic> j) => Artifact(
        title: j['title'] as String? ?? '',
        kind: j['kind'] as String? ?? 'text',
        content: j['content'] as String? ?? '',
        created: DateTime.tryParse(j['created'] as String? ?? ''),
      );
}

class ToolContext {
  ToolContext({
    this.attachments = const [],
    this.knowledge = const [],
    void Function(Artifact)? onArtifact,
    DateTime Function()? clock,
    this.requestNetwork,
  })  : onArtifact = onArtifact ?? ((_) {}),
        clock = clock ?? DateTime.now;

  /// Fragt den Nutzer, ob ein Internetzugriff erlaubt ist ([purpose] wird angezeigt).
  /// null = kein Internet möglich.
  final Future<bool> Function(String purpose)? requestNetwork;

  /// Wirft [ToolException], wenn der Nutzer den Zugriff ablehnt.
  Future<void> ensureNetwork(String purpose) async {
    final ask = requestNetwork;
    if (ask == null) throw ToolException('Internetzugriff ist in dieser App-Konfiguration nicht verfügbar.');
    if (!await ask(purpose)) {
      throw ToolException('Der Nutzer hat den Internetzugriff abgelehnt. Antworte ohne Internet.');
    }
  }

  final List<Attachment> attachments;

  /// Dauerhafte lokale Wissensbasis (z. B. importierte Notizen).
  final List<Attachment> knowledge;
  final void Function(Artifact) onArtifact;
  final DateTime Function() clock;

  List<Attachment> get allDocuments => [...attachments, ...knowledge];

  Attachment? find(String name) {
    final n = name.trim().toLowerCase();
    for (final a in allDocuments) {
      if (a.name.toLowerCase() == n) return a;
    }
    for (final a in allDocuments) {
      if (a.name.toLowerCase().contains(n) && n.isNotEmpty) return a;
    }
    return null;
  }
}

class ToolException implements Exception {
  ToolException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class AgentTool {
  /// Technischer Name, wie ihn das Modell aufruft (snake_case).
  String get name;

  /// Anzeigename in der App.
  String get title;

  /// Beschreibung für das Modell (kurz, ein Satz).
  String get description;

  List<ToolParam> get params;

  /// true = braucht Internet (fragt vorher den Nutzer)
  bool get requiresNetwork => false;

  /// Zusätzliche Suchwörter, damit das Tool bei knappem Context passend ausgewählt wird.
  String get keywords => '';

  Future<String> run(Map<String, dynamic> args, ToolContext ctx);

  String describeForPrompt() {
    if (params.isEmpty) return '- $name: $description Argumente: {}';
    final p = params.map((x) => '"${x.name}": ${x.typeLabel} (${x.description})').join(', ');
    return '- $name: $description Argumente: {$p}';
  }
}
