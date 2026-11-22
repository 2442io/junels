// Eigene, gespeicherte Designs (z. B. Firmen-CI): einmal anlegen, immer verwenden.

import 'design.dart';

class UserDesign {
  UserDesign({required this.design, this.templatePath});
  final SlideDesign design;

  /// Gespeicherte PowerPoint-Vorlage (Folienmaster) – optional.
  final String? templatePath;

  String get id => design.id;
  String get name => design.name;

  Map<String, dynamic> toJson() => {'design': design.toJson(), if (templatePath != null) 'template': templatePath};

  factory UserDesign.fromJson(Map<String, dynamic> j) => UserDesign(
        design: SlideDesign.fromJson((j['design'] as Map).cast<String, dynamic>()),
        templatePath: j['template'] as String?,
      );
}

/// Von der App gefüllt (designs.json); die Werkzeuge lesen hier.
class DesignLibrary {
  static final List<UserDesign> user = [];

  /// Dieses Design gilt, wenn der Nutzer nichts anderes vorgibt (z. B. Firmen-CI).
  static String? defaultId;

  static UserDesign? byId(String? id) {
    if (id == null || id.trim().isEmpty) return null;
    final k = id.trim().toLowerCase();
    return user.where((u) => u.id.toLowerCase() == k || u.name.toLowerCase() == k).firstOrNull;
  }

  static UserDesign? get standard => byId(defaultId);

  /// Eindeutige ID aus einem Namen („Firmen-CI“ → „eigen-firmen-ci“).
  static String idFor(String name) {
    var base = 'eigen-${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]+'), '-').replaceAll(RegExp(r'^-|-$'), '')}';
    if (base == 'eigen-') base = 'eigen-design';
    var id = base;
    var i = 2;
    while (user.any((u) => u.id == id)) {
      id = '$base-${i++}';
    }
    return id;
  }

  /// Für die Werkzeug-Beschreibung.
  static String get describe =>
      user.isEmpty ? '' : ' Eigene Designs des Nutzers: ${user.map((u) => '${u.id} („${u.name}“)').join(', ')}${defaultId != null ? '; Standard: $defaultId' : ''}.';
}
