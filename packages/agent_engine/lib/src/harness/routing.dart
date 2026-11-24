/// Werkzeug-Auswahl des Agenten: Welche Werkzeuge sieht das Modell bei einer Nachricht,
/// und welches muss es benutzen? Reine Logik – im Test-Satz geprüft (test/agent_cases).
library;

/// Kurzbeschreibung eines Werkzeugs für die Auswahl (Name reicht für eingebaute Werkzeuge).
typedef ToolInfo = ({String name, String title, String description});

class ToolRouter {
  ToolRouter._();

  static final _makeVerb = RegExp(r'erstell|mach|bau|generier|erzeug|schreib|gestalt|überarbeit|entwirf|entwerf|anlegen|leg .* an|exportier|als (pdf|powerpoint|pptx|datei)|brauche|hätte gern|möchte',
      caseSensitive: false);
  static final deckWord = RegExp(r'präsentation|powerpoint|folien|pptx|slides|foliensatz|slide ?deck', caseSensitive: false);
  static final _docWord = RegExp(r'\bpdf\b|word-?dokument|dokument|handout|bericht als', caseSensitive: false);

  /// Verlangt die Nachricht eine Datei? → Werkzeug, das der Agent dafür nutzen muss.
  static final _editIntent = RegExp(r'(folie|abschnitt|kapitel|seite)\s*\d+|überarbeit|ändere|ersetze|lösche|füge .* ein|ergänze|kürze|korrigier',
      caseSensitive: false);

  static String? requiredToolFor(String text, {bool hasFiles = false}) {
    // Bestehende Datei ändern („Folie 3 überarbeiten“) – edit_file oder neu erstellen zählt
    if (hasFiles && _editIntent.hasMatch(text) && !RegExp(r'neue (präsentation|powerpoint|datei|pdf)', caseSensitive: false).hasMatch(text)) {
      return 'edit_file|create_presentation|create_document';
    }
    if (_makeVerb.hasMatch(text)) {
      if (deckWord.hasMatch(text)) return 'create_presentation';
      if (_docWord.hasMatch(text)) return 'create_document';
    }
    // Fragen zu den eigenen Daten: nachsehen statt raten
    for (final e in _ownData.entries) {
      if (e.value.hasMatch(text)) return e.key;
    }
    return null;
  }

  /// Eigene Daten des Nutzers – ohne Werkzeug kann das Modell nur raten (erfundene Termine o. Ä.)
  static final _ownData = <String, RegExp>{
    'calendar_list': RegExp(
        r'(was steht|was hab ich|was habe ich|hab ich|habe ich)\b.*\b(heute|morgen|übermorgen|termin|kalender)|'
        r'mein(em|en)? (kalender|terminen?)\b|meine termine|wann ist mein(e|en)? |bin ich .*(frei|verfügbar)',
        caseSensitive: false),
    'mail_inbox': RegExp(r'ungelesene? (mails?|e-?mails?)|meine (mails|e-?mails)|posteingang|neue (mails|e-?mails)', caseSensitive: false),
    'contacts_search': RegExp(r'(telefon|handy)?nummer von|e-?mail-?adresse von', caseSensitive: false),
    'remember': RegExp(r'\bmerk(e)? dir\b', caseSensitive: false),
    // ausdrückliche Aufträge (der Nutzer bestätigt danach selbst)
    'calendar_add': RegExp(r'\btrag\w* .*\bein\b|termin .*(eintragen|anlegen|ausmachen)|in (den|meinen) kalender', caseSensitive: false),
    'send_notification': RegExp(r'\berinner\w* mich\b', caseSensitive: false),
    // Fakten, die sich ändern: nachsehen statt aus dem (veralteten) Wissen antworten
    'web_search': RegExp(r'wer ist (der|die|das) (aktuelle|derzeitige|jetzige|neue)|aktuelle[rn]? (preis|kurs|wechselkurs|stand)|wie steht (der|die) (kurs|aktie)',
        caseSensitive: false),
  };

  /// Auslöser je Werkzeug: Nur wenn die Nachricht danach klingt, bekommt das Modell
  /// das Werkzeug zu sehen. Für „Hi“ oder normale Fragen gibt es gar keine Werkzeuge –
  /// dann antwortet das Modell direkt (ein Durchlauf statt Agenten-Schleife).
  static final triggers = <String, RegExp>{
    'browser': RegExp(r'browser|https?://|flug|flüge|flight|\bvols?\b|vuelos?|voli\b|hotel|unterkunft|zimmer frei|bahn|zugticket|train|billet|ticket|reservier|buchen|booking|verfügbar|'
        r'tarif|\bprix\b|price|prezz|precio|günstigst|cheapest|moins cher|'
        r'\b[a-z0-9-]+\.(at|de|com|ch|li|net|org|io|eu|info|fyi|app|dev|ai|co|shop)\b|öffne\w* .*(seite|webseite|website)|geh\w* auf|navigier|klick|surf|'
        r'amazon|ebay|willhaben|shop|bestell|anmelde|formular|auf der seite|im browser|such\w* (auf|bei) '),
    'web_fetch': RegExp(r'https?://|www\.|\b[\w-]+\.(com|at|de|ch|li|org|net|io|eu|fyi|ai|app)\b|webseite|website|link\b|artikel'),
    'site_search': RegExp(r'amazon|ebay|geizhals|idealo|willhaben|otto\.de|mediamarkt|thalia|chefkoch|wikipedia|'
        r'shop|kaufen|bestell|angebot|günstig|preisvergleich|produkt|auf [\w-]+\.(at|de|com)\b.*such|such\w* (auf|bei) '),
    'web_search': RegExp(r'internet|im netz|online|google|web\b|search|look up|find\b|cherche|recherche|regarde|trouve|busca|cerca|'
        r'flug|flüge|flight|\bvols?\b|hotel|tarif|\bprix\b|price|prezz|precio|actuel|current|latest|'
        r'such(e|en)? (im|nach|mal|mir)|such mir|finde (mir|im)|recherch|'
        r'angebot|kaufen|empfehl\w* .*(produkt|marke)|vergleich|test(sieger|bericht)|'
        r'aktuell|neueste|letzte woche|börse|aktienkurs|wechselkurs|was kostet|preis von|wer ist (der|die) (aktuelle|neue)'),
    // Wortgrenzen: „Regenbogen“, „Windows“, „Jackett“ sind keine Wetterfragen
    'weather': RegExp(r'wetter|\bregen\b|regnet|regenschirm|temperatur|\d+\s*grad\b|\bgrad (wird|hat|haben)|\bschnee\b|schneit|sonnig|'
        r'\bwind(ig)?\b|gewitter|\bschirm\b|\bjacke\b|vorhersage'),
    'news': RegExp(r'news|nachrichten|schlagzeilen|neuigkeiten|neues (zu|von|aus|über|bei|in)|was gibt.s neues|was gibt es neues|meldungen|presse|morgen-übersicht'),
    'contacts_search': RegExp(r'nummer von|telefonnummer|handynummer|e-?mail-?adresse von|adresse von|kontakt'),
    'compose_email': RegExp(r'e-?mail|\bmail\b|mail an|mailen'),
    'compose_whatsapp': RegExp(r'whats ?app|\bwa\b'),
    'call_phone': RegExp(r'ruf\w* .*\ban\b|anrufen|telefonier|\banruf'),
    'calendar_add': RegExp(r'termin|kalender|eintragen|trag .* ein|meeting|besprechung|einladung|veranstaltung|plakat|flyer'),
    'calendar_list': RegExp(r'termin|kalender|was steht|was hab ich|habe ich (heute|morgen)|agenda|tagesplan|morgen-übersicht|bin ich (frei|verfügbar)'),
    'file_search': RegExp(r'datei|dateien|ordner|dokumente? (finden|suchen)|finde .*\.(pdf|docx?|xlsx?|jpg|png)|downloads|schreibtisch'),
    'file_rename': RegExp(r'umbenenn|benenn|dateinamen?'),
    'file_move': RegExp(r'verschieb|sortier|aufräumen|ordne|in den ordner'),
    'calculator': RegExp(r'\d\s*(%|prozent|[+*/^×÷]|mal\b|geteilt|plus|minus|hoch)|rechne|berechne|wurzel|zins'),
    'datetime': RegExp(r'uhrzeit|wie spät|datum|wochentag|welcher tag|kalenderwoche|wie lange (noch )?bis|in \d+ tagen'),
    'remember': RegExp(r'merk dir|merke dir|vergiss|behalte|notier dir|erinnere dich|was weißt du über mich'),
    'send_notification': RegExp(r'erinner|wecker|benachrichtig|push|in \d+ (minuten|stunden)|um \d{1,2}[:.]\d{2}|morgen um'),
    'save_prompt': RegExp(r'prompt|vorlage|als (prompt|vorlage)|jeden (morgen|tag|montag)|täglich'),
    'create_document': RegExp(r'\bpdf\b|dokument|bericht|report|handout|word'),
    'create_presentation': RegExp(r'präsentation|folien|powerpoint|pptx|slides'),
    // Nur bei App-/Musik-Wunsch – nicht bei jedem „such“ (Flugsuche!) oder „Beispiel“
    'control_app': RegExp(r'spotify|\bapp\b|öffne|starte|\bspiel(e|en)?\b|abspielen|\bplay\b|pause|nächste[rns]? (lied|titel|song)|lauter|leiser|'
        r'musik|playlist|podcast|youtube|\bhör\w* (mir|mal|musik|was)|jazz|\bsong|\blied\b|album|künstler|\bband\b'),
    'mail_inbox': RegExp(r'\bmails?\b|e-?mails?|posteingang|inbox|unbeantwortet|ungelesen|nachrichten von|hat .* geschrieben|liegengeblieben|unerledigt'),
    'find_loose_ends': RegExp(r'liegengeblieben|liegen geblieben|unerledigt|was (ist|hab ich|habe ich) (noch )?(offen|vergessen)|offene (punkte|aufgaben|sachen|dinge|themen)|nachfassen|was steht (noch )?aus'),
    'edit_file': RegExp(r'folie\s*\d|abschnitt|kapitel|überarbeit|änder|ersetz|lösch|einfüg|füg .* (ein|hinzu)|korrigier|tausch|umschreib|kürz|ergänz'),
    'create_chart': RegExp(r'diagramm|chart|grafik|balken|kurve|visualisier'),
    'skill_erstellen': RegExp(r'\bskills?\b|fähigkeit'),
    'generate_image': RegExp(r'(erstell|generier|mal|zeichne|erzeug)\w* .*\b(bild|foto|illustration|logo|grafik)|bild von|zeichne|male mir'),
    'knowledge_search': RegExp(r'wissensbasis|meine(n)? (dokument|unterlagen|quellen|notizen)|laut (dem|der|meinen)|im dokument'),
    'search_history': RegExp(r'früher|letztes mal|haben wir (schon|mal)|hatte ich|verlauf|vorhin|gestern (gesagt|gefragt)'),
    'read_file': RegExp(r'datei|file|\.txt|\.csv|\.md\b'),
    'text_search': RegExp(r'such(e|en)? (in|im) (der|dem|den) (datei|text)'),
    'json_query': RegExp(r'\bjson\b'),
    'write_artifact': RegExp(r'\bhtml\b|webseite (bauen|erstellen)|artefakt|code (für|schreiben)|skript'),
  };


  /// Werkzeuge im Stil eines MCP-Servers, die bei „Was ist liegengeblieben?“ mitkommen.
  static final looseEndsMcp = RegExp(r'mail|gmail|outlook|inbox|imap|message|slack|todo|task|aufgabe|ticket|issue|jira|linear|asana|trello|notion|github|calendar',
    caseSensitive: false);

  /// Wählt aus [available] die Werkzeuge, die zur Nachricht passen (Reihenfolge bleibt).
  static List<T> select<T>(List<T> available, ToolInfo Function(T) info, String input, {bool hasImages = false, bool hasDocs = false}) {
    final t = input.toLowerCase();
    final words = RegExp(r'[\p{L}\d]{5,}', unicode: true).allMatches(t).map((m) => m.group(0)!).toSet();
    final loose = triggers['find_loose_ends']?.hasMatch(t) ?? false;
    return [
      for (final x in available)
        if (_matches(info(x), t, words, hasImages: hasImages, hasDocs: hasDocs, loose: loose)) x,
    ];
  }

  /// Ausdrücklich nach dem Wetter gefragt (nicht nur „Schnee“ im Bildmotiv)
  static final _weatherExplicit = RegExp(r'wetter|vorhersage|temperatur|regnet|schneit|regenschirm|\bschirm\b|jacke');

  static bool _matches(ToolInfo tool, String t, Set<String> words, {required bool hasImages, required bool hasDocs, required bool loose}) {
    // Bild-Wunsch („Fuchs im Schnee“): Wetter nur, wenn ausdrücklich danach gefragt
    if (tool.name == 'weather' && (triggers['generate_image']?.hasMatch(t) ?? false) && !_weatherExplicit.hasMatch(t)) return false;
    final trig = triggers[tool.name];
    if (trig != null && trig.hasMatch(t)) return true;
    if (trig == null) {
      if (tool.name == 'look_at_image' && hasImages) return true;
      // MCP: wenn Wörter aus Name/Beschreibung in der Nachricht vorkommen
      if (tool.name.contains('__') && words.any((w) => '${tool.name} ${tool.title} ${tool.description}'.toLowerCase().contains(w))) return true;
    }
    if (hasDocs && (tool.name == 'knowledge_search' || tool.name == 'read_file')) return true;
    // „Was ist liegengeblieben?“: auch Mail-/Aufgaben-Werkzeuge (MCP) und Kalender
    if (loose && (tool.name == 'calendar_list' || (tool.name.contains('__') && looseEndsMcp.hasMatch('${tool.name} ${tool.title} ${tool.description}')))) {
      return true;
    }
    return false;
  }

  /// Nur Namen (für Tests und den Test-Satz).
  static Set<String> selectNames(Iterable<String> names, String input, {bool hasImages = false, bool hasDocs = false}) => select(
          names.toList(), (String n) => (name: n, title: n, description: ''), input,
          hasImages: hasImages, hasDocs: hasDocs)
      .toSet();
}
