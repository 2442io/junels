// Web-Jobs: planen → ausführen → prüfen, vorgemachte Abläufe (Aufnahme & Abspielen),
// Freigaben je Website und „Meine Daten“ zum Ausfüllen – reine Logik, ohne App.

import 'dart:convert';

// ------------------------------------------------------------------ Job

/// Ein Schritt eines Web-Jobs.
class JobStep {
  JobStep(this.text, {this.status = 'offen', this.note = ''});
  String text;

  /// offen | läuft | ok | problem | übersprungen
  String status;
  String note;

  Map<String, Object> toJson() => {'text': text, 'status': status, if (note.isNotEmpty) 'note': note};
  factory JobStep.fromJson(Map<String, dynamic> j) =>
      JobStep(j['text'] as String? ?? '', status: j['status'] as String? ?? 'offen', note: j['note'] as String? ?? '');
}

/// Ein Auftrag, den Junels selbstständig im Browser erledigt.
class WebJob {
  WebJob({
    required this.id,
    required this.title,
    required this.goal,
    this.skillId,
    this.output = '',
    List<JobStep>? steps,
    this.status = 'plant',
    this.current = 0,
    DateTime? created,
    this.result = '',
    this.proofUrl = '',
    this.proofTitle = '',
    this.proofText = '',
    List<String>? files,
    this.macro = false,
    this.problem = '',
  })  : steps = steps ?? [],
        files = files ?? [],
        created = created ?? DateTime.now(),
        updated = created ?? DateTime.now();

  final String id;
  String title;
  String goal;
  String? skillId;
  String output;
  final List<JobStep> steps;

  /// plant | läuft | pausiert | wartet | fertig | problem | abgebrochen
  String status;
  int current;
  final DateTime created;
  DateTime updated;
  String result;
  String proofUrl;
  String proofTitle;
  String proofText;
  final List<String> files;

  /// Abspielen eines vorgemachten Ablaufs (ohne Planen)
  bool macro;
  String problem;

  bool get active => status == 'plant' || status == 'läuft' || status == 'wartet';
  bool get finished => status == 'fertig' || status == 'abgebrochen';
  int get done => steps.where((s) => s.status == 'ok' || s.status == 'übersprungen').length;

  String get progressLabel => switch (status) {
        'plant' => 'plant die Schritte …',
        'läuft' => 'Schritt ${current + 1}/${steps.length}',
        'wartet' => 'wartet auf dich (Schritt ${current + 1}/${steps.length})',
        'pausiert' => 'pausiert bei Schritt ${current + 1}/${steps.length}',
        'problem' => 'Problem bei Schritt ${current + 1}/${steps.length}',
        'abgebrochen' => 'abgebrochen',
        _ => 'fertig · ${steps.length} Schritte',
      };

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'goal': goal,
        if (skillId != null) 'skillId': skillId,
        if (output.isNotEmpty) 'output': output,
        'steps': [for (final s in steps) s.toJson()],
        'status': status,
        'current': current,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        if (result.isNotEmpty) 'result': result,
        if (proofUrl.isNotEmpty) 'proofUrl': proofUrl,
        if (proofTitle.isNotEmpty) 'proofTitle': proofTitle,
        if (proofText.isNotEmpty) 'proofText': proofText,
        if (files.isNotEmpty) 'files': files,
        if (macro) 'macro': true,
        if (problem.isNotEmpty) 'problem': problem,
      };

  factory WebJob.fromJson(Map<String, dynamic> j) {
    final job = WebJob(
      id: j['id'] as String,
      title: j['title'] as String? ?? 'Job',
      goal: j['goal'] as String? ?? '',
      skillId: j['skillId'] as String?,
      output: j['output'] as String? ?? '',
      steps: [for (final s in (j['steps'] as List? ?? const [])) JobStep.fromJson((s as Map).cast<String, dynamic>())],
      status: j['status'] as String? ?? 'fertig',
      current: (j['current'] as num?)?.toInt() ?? 0,
      created: DateTime.tryParse(j['created'] as String? ?? ''),
      result: j['result'] as String? ?? '',
      proofUrl: j['proofUrl'] as String? ?? '',
      proofTitle: j['proofTitle'] as String? ?? '',
      proofText: j['proofText'] as String? ?? '',
      files: [for (final f in (j['files'] as List? ?? const [])) '$f'],
      macro: j['macro'] == true,
      problem: j['problem'] as String? ?? '',
    );
    job.updated = DateTime.tryParse(j['updated'] as String? ?? '') ?? job.created;
    // Beim App-Start lief nichts mehr: als pausiert weiterführbar
    if (job.status == 'läuft' || job.status == 'plant' || job.status == 'wartet') job.status = 'pausiert';
    return job;
  }
}

/// Plan aus der Antwort des Modells: nummerierte oder Aufzählungs-Zeilen (höchstens [max]).
List<String> parsePlan(String text, {int max = 8}) {
  final out = <String>[];
  for (final raw in text.split('\n')) {
    final m = RegExp(r'^\s*(?:\d{1,2}[.)]|[-*•])\s+(.+)$').firstMatch(raw);
    if (m == null) continue;
    var s = m.group(1)!.replaceAll(RegExp(r'\*\*'), '').trim();
    if (s.length < 4) continue;
    if (s.length > 200) s = '${s.substring(0, 200)}…';
    out.add(s);
    if (out.length >= max) break;
  }
  return out;
}

/// Auftrag an den Planer.
String jobPlanPrompt(String goal) => 'Plane diesen Auftrag für einen Browser-Agenten in 3 bis 7 konkreten Schritten. '
    'Jeder Schritt ist eine überprüfbare Handlung im Browser (Seite öffnen, suchen, filtern, Liste sammeln, Formular ausfüllen, '
    'Ergebnis zusammenstellen). Nenne Webseiten konkret (z. B. geizhals.at). Kein Bezahlen, kein Passwort, kein Absenden ohne Rückfrage. '
    'Der letzte Schritt fasst das Ergebnis zusammen.\n'
    'Antworte NUR mit der nummerierten Liste.\n\nAuftrag: $goal';

/// Auftrag an den Ausführer für Schritt [i].
String jobStepPrompt(WebJob job, int i, {String retryHint = ''}) {
  final b = StringBuffer()
    ..writeln('Du arbeitest einen Web-Job Schritt für Schritt ab. Ziel: ${job.goal}')
    ..writeln('Plan:');
  for (var k = 0; k < job.steps.length; k++) {
    final s = job.steps[k];
    final mark = k < i ? '✓' : (k == i ? '→' : ' ');
    b.writeln('$mark ${k + 1}. ${s.text}${k < i && s.note.isNotEmpty ? ' – ${s.note}' : ''}');
  }
  final last = i == job.steps.length - 1;
  b
    ..writeln()
    ..writeln('Führe JETZT NUR Schritt ${i + 1} aus: ${job.steps[i].text}')
    ..writeln('Nutze den Browser (er ist schon offen, falls ein früherer Schritt ihn benutzt hat). '
        'Anmeldung, CAPTCHA und Zahlung macht der Nutzer selbst – dann übergib an ihn.');
  if (retryHint.isNotEmpty) b.writeln('Der erste Versuch ging nicht: $retryHint. Versuch es diesmal anders (andere Seite, Suche, Link).');
  if (last) {
    b.writeln('Das ist der letzte Schritt: Gib das vollständige Ergebnis für den Nutzer aus (mit allen gesammelten Daten). '
        'Beginne mit „ERLEDIGT:“ in der ersten Zeile, danach das Ergebnis.');
  } else {
    b.writeln('Antworte am Ende in EINER Zeile: „ERLEDIGT: <was du gemacht/gefunden hast, mit den wichtigen Daten>“ '
        'oder „PROBLEM: <warum es nicht ging>“.');
  }
  return b.toString().trim();
}

/// Ergebnis eines Schritts aus der Antwort: ok + kurze Notiz.
(bool, String) stepOutcome(String answer) {
  final t = answer.trim();
  if (t.isEmpty) return (false, 'keine Antwort');
  final p = RegExp(r'(?:^|\n)\s*\**\s*PROBLEM\s*:?\**\s*(.+)', caseSensitive: false).firstMatch(t);
  final ok = RegExp(r'(?:^|\n)\s*\**\s*ERLEDIGT\s*:?\**\s*(.*)', caseSensitive: false).firstMatch(t);
  if (p != null && (ok == null || p.start > ok.start)) return (false, _short(p.group(1)!));
  if (ok != null) return (true, _short(ok.group(1)!.isEmpty ? t.substring(ok.end).trim() : ok.group(1)!));
  // ohne Marker: Fehlermeldungen erkennen, sonst ok
  if (RegExp(r'(konnte|kann) (ich )?(die seite |das )?(nicht|leider nicht)|nicht erreichbar|fehlgeschlagen', caseSensitive: false)
      .hasMatch(t.length > 300 ? t.substring(0, 300) : t)) {
    return (false, _short(t));
  }
  return (true, _short(t));
}

/// Endergebnis ohne „ERLEDIGT:“-Marker
String stripOutcomeMarker(String answer) =>
    answer.replaceFirst(RegExp(r'^\s*\**\s*ERLEDIGT\s*:?\**\s*', caseSensitive: false), '').trim();

String _short(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 220 ? '${one.substring(0, 220)}…' : one;
}

// ------------------------------------------------------------------ Freigaben je Website

/// Wie frei Junels auf einer Website handeln darf. Stufen: allow (frei) | ask (Rückfrage) | block (nie).
/// Lesen und Suchen sind immer frei (die Internet-Freigabe gilt wie gehabt); Zahlen macht immer der Mensch.
class SitePolicy {
  SitePolicy({Map<String, Map<String, String>>? sites, this.fill = 'allow', this.submit = 'ask'}) : sites = sites ?? {};

  /// host → {fill: …, submit: …}
  final Map<String, Map<String, String>> sites;

  /// Standard für Websites ohne eigene Regel
  String fill;
  String submit;

  static String hostOf(String url) {
    final raw = url.trim();
    final h = (raw.contains('://') ? (Uri.tryParse(raw)?.host ?? raw) : raw.split('/').first).toLowerCase();
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  /// Eigene Regel einer Website (auch für Unterdomains: shop.example.at → example.at)
  Map<String, String>? ruleFor(String host) {
    var h = hostOf(host);
    while (h.contains('.')) {
      final r = sites[h];
      if (r != null) return r;
      h = h.substring(h.indexOf('.') + 1);
    }
    return null;
  }

  /// kind: fill | submit | pay
  String level(String host, String kind) {
    if (kind == 'pay') return 'block';
    final r = ruleFor(host);
    return r?[kind] ?? (kind == 'fill' ? fill : submit);
  }

  void set(String host, String kind, String level) {
    final h = hostOf(host);
    (sites[h] ??= {})[kind] = level;
  }

  Map<String, Object> toJson() => {'fill': fill, 'submit': submit, 'sites': sites};
  factory SitePolicy.fromJson(Map<String, dynamic>? j) => SitePolicy(
        fill: j?['fill'] as String? ?? 'allow',
        submit: j?['submit'] as String? ?? 'ask',
        sites: {
          for (final e in ((j?['sites'] as Map?) ?? const {}).entries)
            '${e.key}': {for (final x in (e.value as Map).entries) '${x.key}': '${x.value}'},
        },
      );

  static const levelNames = {'allow': 'frei', 'ask': 'mit Rückfrage', 'block': 'nie'};
}

// ------------------------------------------------------------------ Meine Daten

/// Felder von „Meine Daten“ (nichts Sensibles: keine SV-Nummer, IBAN, Ausweis, Passwörter).
const myDataFields = <(String, String)>[
  ('anrede', 'Anrede'),
  ('titel', 'Titel'),
  ('vorname', 'Vorname'),
  ('nachname', 'Nachname'),
  ('geburtsdatum', 'Geburtsdatum'),
  ('strasse', 'Straße & Hausnummer'),
  ('plz', 'PLZ'),
  ('ort', 'Ort'),
  ('land', 'Land'),
  ('email', 'E-Mail'),
  ('telefon', 'Telefon'),
  ('firma', 'Firma'),
];

/// Sensibles, das nie in „Meine Daten“ gehört (und nie automatisch ausgefüllt wird)
final sensitiveField = RegExp(
    r'passw|kennwort|pin\b|tan\b|iban|bic|konto|kreditkarte|karte(nnummer)?|cvc|cvv|sozialversicherung|sv-?n|svnr|versicherungsnummer|'
    r'reisepass|pass(nummer|nr)|ausweis|personalausweis|steuer-?id|steuernummer|führerschein',
    caseSensitive: false);

/// Welche Formularfelder (F-Nummer → Wert) sich aus „Meine Daten“ füllen lassen.
/// [fields]: Felder aus dem Formular-Leser (id, label, type, secret, filled, options).
/// [data]: Schlüssel aus [myDataFields] plus Kundennummern („kunde:<Name>“).
Map<String, String> autofillPlan(List<Map<String, dynamic>> fields, Map<String, String> data) {
  final out = <String, String>{};
  final used = <String>{};
  String? pick(String label, String type) {
    final l = label.toLowerCase();
    if (sensitiveField.hasMatch(l)) return null;
    bool has(String re) => RegExp(re, caseSensitive: false).hasMatch(l);
    if (type == 'email' || has(r'e-?mail')) return 'email';
    if (type == 'tel' || has(r'telefon|handy|mobil|phone')) return 'telefon';
    if (has(r'vorname|first ?name|given')) return 'vorname';
    if (has(r'nachname|familienname|zuname|last ?name|surname')) return 'nachname';
    if (has(r'geburts|birth')) return 'geburtsdatum';
    if (has(r'stra(ss|ß)e|adresse|address|anschrift')) return 'strasse';
    if (has(r'\bplz\b|postleitzahl|zip|postal')) return 'plz';
    if (has(r'\bort\b|stadt|wohnort|city|gemeinde')) return 'ort';
    if (has(r'\bland\b|staat|country')) return 'land';
    if (has(r'anrede|salutation|geschlecht')) return 'anrede';
    if (has(r'titel|title|akad')) return 'titel';
    if (has(r'firma|unternehmen|company|organisation')) return 'firma';
    if (has(r'^name\b|ihr name|vollständiger name|full name')) return 'name';
    for (final k in data.keys.where((k) => k.startsWith('kunde:'))) {
      final who = k.substring(6).toLowerCase();
      if (has(r'kunden|vertrags|zählpunkt|mitglieds|referenz') && (l.contains(who) || data.keys.where((x) => x.startsWith('kunde:')).length == 1)) {
        return k;
      }
    }
    return null;
  }

  for (final f in fields) {
    if (f['secret'] == 1 || f['filled'] == true) continue;
    final type = '${f['type'] ?? ''}'.toLowerCase();
    if (type == 'checkbox' || type == 'radio' || type == 'file' || type == 'password') continue;
    final key = pick('${f['label'] ?? ''}', type);
    if (key == null) continue;
    final value = key == 'name' ? [data['vorname'] ?? '', data['nachname'] ?? ''].where((x) => x.isNotEmpty).join(' ') : (data[key] ?? '');
    if (value.trim().isEmpty || used.contains('$key|${f['id']}')) continue;
    used.add('$key|${f['id']}');
    out['${f['id']}'] = value.trim();
  }
  return out;
}

// ------------------------------------------------------------------ Vormachen: Aufnahme & Abspielen

/// Ein aufgenommener Schritt.
class MacroStep {
  MacroStep({required this.kind, Map<String, String>? hints, this.value = '', this.secret = false, this.enter = false, this.url = ''})
      : hints = hints ?? {};

  /// open | click | type | select | check
  String kind;
  final Map<String, String> hints;

  /// Eingegebener Wert – mit Platzhaltern wie {suchbegriff}
  String value;
  bool secret;
  bool enter;
  String url;

  String get label {
    final h = hints;
    final l = (h['label'] ?? '').isNotEmpty ? h['label']! : ((h['text'] ?? '').isNotEmpty ? h['text']! : (h['name'] ?? h['tag'] ?? ''));
    return l.length > 60 ? '${l.substring(0, 60)}…' : l;
  }

  String get describe => switch (kind) {
        'open' => 'Öffnen: ${SitePolicy.hostOf(url)}',
        'type' => secret ? '🔒 „$label“ – trägst du selbst ein' : '„$label“ ← ${value.isEmpty ? '(leer)' : value}',
        'select' => '„$label“: $value wählen',
        'check' => '„$label“ ${value == 'nein' ? 'abhaken (aus)' : 'anhaken'}',
        _ => 'Klick: „$label“',
      };

  /// Platzhalter im Wert, z. B. {suchbegriff}
  List<String> get placeholders => [for (final m in RegExp(r'\{([a-zäöüß0-9_ -]{1,30})\}').allMatches(value)) m.group(1)!];

  Map<String, Object> toJson() => {
        'kind': kind,
        if (hints.isNotEmpty) 'hints': hints,
        if (value.isNotEmpty) 'value': value,
        if (secret) 'secret': true,
        if (enter) 'enter': true,
        if (url.isNotEmpty) 'url': url,
      };

  factory MacroStep.fromJson(Map<String, dynamic> j) => MacroStep(
        kind: j['kind'] as String? ?? 'click',
        hints: {for (final e in ((j['hints'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
        value: j['value'] as String? ?? '',
        secret: j['secret'] == true,
        enter: j['enter'] == true,
        url: j['url'] as String? ?? '',
      );
}

/// Rohe Aufnahme (Ereignisse aus dem Browser) → saubere Schritte:
/// mehrfaches Tippen ins selbe Feld → letzter Wert; Klick ins Feld vor dem Tippen weg; doppelte Klicks weg.
List<MacroStep> cleanRecording(String startUrl, List<Map<String, dynamic>> events) {
  final steps = <MacroStep>[MacroStep(kind: 'open', url: startUrl)];
  String key(MacroStep s) => '${s.hints['id']}|${s.hints['name']}|${s.hints['label']}|${s.hints['tag']}';
  for (final e in events) {
    final kind = '${e['kind'] ?? ''}';
    if (!const {'click', 'type', 'select', 'check'}.contains(kind)) continue;
    final s = MacroStep(
      kind: kind,
      hints: {for (final x in ((e['hints'] as Map?) ?? const {}).entries) if ('${x.value}'.isNotEmpty) '${x.key}': '${x.value}'},
      value: e['secret'] == true ? '' : '${e['value'] ?? ''}',
      secret: e['secret'] == true,
      enter: e['enter'] == true,
      url: '${e['url'] ?? ''}',
    );
    final last = steps.last;
    if (s.kind == 'type' && last.kind == 'type' && key(last) == key(s)) {
      // gleiches Feld: letzter Stand zählt (Enter bleibt erhalten)
      last
        ..value = s.value
        ..enter = last.enter || s.enter
        ..secret = last.secret || s.secret;
      continue;
    }
    if (s.kind == 'type' && last.kind == 'click' && key(last) == key(s)) {
      steps.removeLast();
    }
    if (s.kind == 'click' && last.kind == 'click' && key(last) == key(s) && last.url == s.url) continue;
    if (s.kind == 'click' && (s.hints['tag'] == 'input' || s.hints['tag'] == 'textarea') && s.hints['type'] != 'submit' && s.hints['type'] != 'button') {
      continue; // Klick in ein Textfeld: kommt als „type“
    }
    steps.add(s);
  }
  return steps;
}

/// Werte, die wie Suchbegriffe/Daten aussehen, werden zu Platzhaltern ({suchbegriff}, {datum} …).
/// Gibt die Platzhalter mit ihrem aufgenommenen Beispielwert zurück.
Map<String, String> autoPlaceholders(List<MacroStep> steps) {
  final out = <String, String>{};
  for (final s in steps) {
    if (s.kind != 'type' || s.secret || s.value.trim().isEmpty || s.placeholders.isNotEmpty) continue;
    final l = '${s.hints['label']} ${s.hints['name']} ${s.hints['ph']} ${s.hints['type']}'.toLowerCase();
    String? name;
    if (RegExp(r'such|search|query|stichwort|was suchst|produkt|begriff|\bq\b').hasMatch(l) || s.enter) {
      name = 'suchbegriff';
    } else if (RegExp(r'datum|date|anreise|abreise|hinfahrt|rückfahrt|von\b|bis\b|tag').hasMatch(l) ||
        RegExp(r'^\d{1,2}\.\d{1,2}\.(\d{2,4})?$|^\d{4}-\d{2}-\d{2}$').hasMatch(s.value.trim())) {
      name = 'datum';
    } else if (RegExp(r'\bort\b|stadt|ziel|nach\b|start|abfahrt|bahnhof|from|to\b|wohin|woher').hasMatch(l)) {
      name = 'ort';
    } else if (RegExp(r'preis|price|max|min|betrag').hasMatch(l)) {
      name = 'preis';
    }
    if (name == null) continue;
    var n = name;
    for (var i = 2; out.containsKey(n); i++) {
      n = '$name$i';
    }
    out[n] = s.value;
    s.value = '{$n}';
  }
  return out;
}

/// Werte für Platzhalter aus der Eingabe: „name=wert; name2=wert“ oder – bei einem Platzhalter – der ganze Text.
Map<String, String> parseParams(String rest, List<String> names, {Map<String, String> defaults = const {}}) {
  final out = {...defaults};
  final t = rest.trim();
  if (t.isEmpty) return out;
  final pairs = RegExp(r'([a-zäöüß0-9_]+)\s*[=:]\s*([^;\n]+)', caseSensitive: false).allMatches(t).toList();
  if (pairs.isNotEmpty && pairs.any((m) => names.contains(m.group(1)!.toLowerCase()))) {
    for (final m in pairs) {
      final k = m.group(1)!.toLowerCase();
      if (names.contains(k)) out[k] = m.group(2)!.trim();
    }
    return out;
  }
  if (names.isNotEmpty) out[names.first] = t;
  return out;
}

/// Platzhalter im Wert ersetzen
String fillPlaceholders(String value, Map<String, String> params) =>
    value.replaceAllMapped(RegExp(r'\{([a-zäöüß0-9_ -]{1,30})\}'), (m) => params[m.group(1)!] ?? m.group(0)!);

String macroToJson(List<MacroStep> steps) => jsonEncode([for (final s in steps) s.toJson()]);
List<MacroStep> macroFromJson(Object? raw) {
  final list = raw is String ? (raw.isEmpty ? const [] : jsonDecode(raw) as List) : (raw as List? ?? const []);
  return [for (final e in list) MacroStep.fromJson((e as Map).cast<String, dynamic>())];
}

/// Aufnahme im Browser: meldet Klicks, Eingaben und Auswahl über den Kanal „JunelsRec“
/// (Werte von Geheimfeldern – Passwort, Karte, IBAN, SV-Nummer, Ausweis – werden NIE gelesen).
const browserRecordJs = r'''
(function(){
  if(window.__jrecOn)return '{}';window.__jrecOn=true;
  var txt=function(s){return (s||'').replace(/\s+/g,' ').trim();};
  var labelOf=function(e){var lab=null;try{lab=e.id?document.querySelector('label[for="'+CSS.escape(e.id)+'"]'):null;}catch(x){}var l=e.closest&&e.closest('label');
    return txt(e.getAttribute('aria-label'))||txt(lab?lab.innerText:'')||txt(l?l.innerText:'')||txt(e.getAttribute('placeholder'))||txt(e.getAttribute('title'))||txt(e.getAttribute('name'))||txt(e.innerText||'').slice(0,80);};
  var hints=function(e){var tag=e.tagName.toLowerCase();return {tag:tag,id:e.id||'',name:e.getAttribute('name')||'',type:(e.getAttribute('type')||'').toLowerCase(),label:labelOf(e).slice(0,90),text:(tag==='a'||tag==='button')?txt(e.innerText).slice(0,90):'',href:tag==='a'?(e.getAttribute('href')||''):'',ph:e.getAttribute('placeholder')||'',role:e.getAttribute('role')||''};};
  var secret=function(e){var t=(e.getAttribute('type')||'').toLowerCase();var ac=(e.getAttribute('autocomplete')||'').toLowerCase();var s=(e.getAttribute('name')||'')+' '+(e.getAttribute('placeholder')||'')+' '+labelOf(e);
    return t==='password'||ac.indexOf('cc-')===0||ac.indexOf('password')>=0||/passw|kennwort|card|cvc|cvv|iban|kreditkarte|kartennummer|sozialversicherung|sv-?nummer|svnr|reisepass|ausweis|\bpin\b|\btan\b/i.test(s);};
  var send=function(o){o.url=location.href;o.t=Date.now();var m=JSON.stringify(o);try{JunelsRec.postMessage(m);}catch(x){(window.__jrec=window.__jrec||[]).push(o);}};
  document.addEventListener('click',function(ev){var e=ev.target&&ev.target.closest&&ev.target.closest('a,button,input[type=submit],input[type=button],input[type=image],[role=button],[role=link],[role=tab],[role=option],summary,label,li[onclick],div[onclick]');
    if(!e)return;var tag=e.tagName.toLowerCase();var ty=(e.getAttribute('type')||'').toLowerCase();if(tag==='input'&&(ty==='checkbox'||ty==='radio'))return;send({kind:'click',hints:hints(e)});},true);
  document.addEventListener('change',function(ev){var e=ev.target;if(!e||!e.tagName)return;var tag=e.tagName.toLowerCase();var ty=(e.getAttribute('type')||'').toLowerCase();
    if(tag==='select'){var o=e.options[e.selectedIndex];send({kind:'select',hints:hints(e),value:o?txt(o.text):''});return;}
    if(ty==='checkbox'||ty==='radio'){send({kind:'check',hints:hints(e),value:e.checked?'ja':'nein'});return;}
    if(tag==='input'||tag==='textarea'){if(secret(e)){send({kind:'type',hints:hints(e),secret:true});return;}send({kind:'type',hints:hints(e),value:e.value||''});}},true);
  document.addEventListener('keydown',function(ev){if(ev.key!=='Enter')return;var e=ev.target;if(!e||!e.tagName)return;var tag=e.tagName.toLowerCase();if(tag!=='input')return;
    if(secret(e))send({kind:'type',hints:hints(e),secret:true,enter:true});else send({kind:'type',hints:hints(e),value:e.value||'',enter:true});},true);
  return '{}';
})()
''';

/// Element für einen aufgenommenen Schritt wiederfinden (Merkmale vergleichen); markiert es mit data-jmid="1".
String browserFindJs(Map<String, String> hints) => '''
(function(){
  var H=${jsonEncode(hints)};
  var txt=function(s){return (s||'').replace(/\\s+/g,' ').trim().toLowerCase();};
  document.querySelectorAll('[data-jmid]').forEach(function(e){e.removeAttribute('data-jmid');});
  var vis=function(e){var r=e.getBoundingClientRect();var s=getComputedStyle(e);return (r.width>1||r.height>1)&&s.visibility!=='hidden'&&s.display!=='none';};
  var labelOf=function(e){var lab=null;try{lab=e.id?document.querySelector('label[for="'+CSS.escape(e.id)+'"]'):null;}catch(x){}var l=e.closest&&e.closest('label');
    return txt(e.getAttribute('aria-label'))||txt(lab?lab.innerText:'')||txt(l?l.innerText:'')||txt(e.getAttribute('placeholder'))||txt(e.getAttribute('title'))||txt(e.getAttribute('name'))||txt(e.innerText||'').slice(0,80);};
  var all=document.querySelectorAll('a,button,input,select,textarea,[role=button],[role=link],[role=tab],[role=option],summary,label,li[onclick],div[onclick]');
  var best=null,bs=0;
  var hl=txt(H.label),ht=txt(H.text),hp=txt(H.ph);
  for(var i=0;i<all.length;i++){var e=all[i];if(!vis(e))continue;var s=0;var tag=e.tagName.toLowerCase();
    if(H.id&&e.id===H.id)s+=10;
    if(H.name&&e.getAttribute('name')===H.name)s+=6;
    var l=labelOf(e).slice(0,90);if(hl&&l===hl)s+=6;else if(hl&&hl.length>3&&(l.indexOf(hl)>=0||hl.indexOf(l)>=0)&&l.length>3)s+=3;
    var t=txt(e.innerText).slice(0,90);if(ht&&t===ht)s+=5;else if(ht&&ht.length>3&&t.indexOf(ht)>=0)s+=2;
    if(hp&&txt(e.getAttribute('placeholder'))===hp)s+=3;
    if(H.href&&tag==='a'){var a=e.getAttribute('href')||'';if(a===H.href)s+=4;}
    if(H.tag&&tag===H.tag)s+=1;
    if(H.type&&(e.getAttribute('type')||'').toLowerCase()===H.type)s+=1;
    if(s>bs){bs=s;best=e;}}
  if(!best||bs<5)return JSON.stringify({ok:false,score:bs});
  best.setAttribute('data-jmid','1');best.scrollIntoView({block:'center'});
  return JSON.stringify({ok:true,score:bs,label:labelOf(best).slice(0,80)});
})()
''';

/// Nächste Seite einer Ergebnisliste (rel=next, „Weiter“, „Nächste“, ›, »)
const browserNextPageJs = r'''
(function(){
  var txt=function(s){return (s||'').replace(/\s+/g,' ').trim().toLowerCase();};
  var l=document.querySelector('link[rel=next]');if(l&&l.href){location.href=l.href;return JSON.stringify({ok:true});}
  var c=document.querySelector('a[rel=next]');
  if(!c){var as=Array.prototype.slice.call(document.querySelectorAll('a[href],button'));
    c=as.find(function(a){var t=txt(a.innerText||a.getAttribute('aria-label')||a.getAttribute('title'));var al=txt(a.getAttribute('aria-label')||a.getAttribute('title'));
      return /^(weiter|nächste|nächste seite|next|next page|›|»|>|vor)$/.test(t)||/nächste seite|next page|weiter zur nächsten|zur nächsten seite/.test(t+' '+al);});}
  if(!c||c.disabled||c.getAttribute('aria-disabled')==='true')return JSON.stringify({ok:false});
  c.scrollIntoView({block:'center'});c.click();return JSON.stringify({ok:true});
})()
''';

/// Wichtigstes einer Detailseite: Titel, Preis (auch aus JSON-LD), Verfügbarkeit, Merkmale (dl/Tabellen).
const browserDetailJs = r'''
(function(){
  var txt=function(s){return (s||'').replace(/\s+/g,' ').trim();};
  var h1=document.querySelector('h1');var out={title:txt(h1?h1.innerText:document.title).slice(0,140),url:location.href,facts:{}};
  var lds=document.querySelectorAll('script[type="application/ld+json"]');
  for(var i=0;i<lds.length;i++){try{var j=JSON.parse(lds[i].textContent);var arr=Array.isArray(j)?j:(j['@graph']||[j]);
    arr.forEach(function(o){if(!o)return;var off=o.offers;if(off){if(Array.isArray(off))off=off[0];
      if(off.price&&!out.price)out.price=off.price+' '+(off.priceCurrency||'');if(off.lowPrice&&!out.price)out.price='ab '+off.lowPrice+' '+(off.priceCurrency||'');
      if(off.availability)out.availability=String(off.availability).split('/').pop();}
      if(o.brand&&!out.brand)out.brand=o.brand.name||o.brand;});}catch(e){}}
  var body=txt(document.body?document.body.innerText:'');
  if(!out.price){var m=body.match(/(€\s*\d[\d.]*,(\d{2}|-)|\d[\d.]*,(\d{2}|-)\s*€)/);if(m)out.price=m[0];}
  var n=0;
  document.querySelectorAll('dl').forEach(function(dl){dl.querySelectorAll('dt').forEach(function(dt){var dd=dt.nextElementSibling;if(dd&&n<12){var k=txt(dt.innerText).slice(0,40);if(k){out.facts[k]=txt(dd.innerText).slice(0,80);n++;}}});});
  document.querySelectorAll('table tr').forEach(function(tr){var c=tr.querySelectorAll('th,td');if(c.length===2&&n<12){var k=txt(c[0].innerText),v=txt(c[1].innerText);if(k&&v&&k.length<40){out.facts[k]=v.slice(0,80);n++;}}});
  var md=document.querySelector('meta[name=description]');out.desc=md?txt(md.content).slice(0,200):'';
  return JSON.stringify(out);
})()
''';

/// Für den Nachweis: Titel, Adresse und sichtbarer Text der Seite.
const browserProofJs = r'''
(function(){var b=document.querySelector('main,[role=main]')||document.body;var t=(b?(b.innerText||''):'').replace(/\s+/g,' ').trim();
return JSON.stringify({url:location.href,title:document.title,text:t.slice(0,1500)});})()
''';
