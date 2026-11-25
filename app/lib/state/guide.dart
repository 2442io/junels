// Begleit-Modus: Junels geht mit dem Nutzer gemeinsam durch eine Webseite (Amtsweg, Tickets, Buchung …).
// Plan mit Häkchen, jede Browser-Aktion sichtbar, Übergabe bei Anmeldung/Captcha/Zahlung,
// Warten & melden (Warteschlange), am Ende als Vorlage speicherbar.

import 'package:agent_engine/agent_engine.dart';

import '../data/models.dart';
import 'browser_service.dart';

/// Möchte der Nutzer mit Junels etwas auf einer Webseite erledigen?
bool wantsGuide(String input) {
  final t = input.toLowerCase();
  final url = RegExp(r'https?://\S+|\b[a-z0-9-]+\.(at|de|ch|com|org|net|eu|gv\.at|io)/\S*').hasMatch(t);
  final verb = RegExp(
          r'mach|durchführ|durchfuehr|erledig|beantrag|bestell|buch|hilf|begleit|gemeinsam|mit mir|zusammen|ausfüll|ausfuell|'
          r'anmeld|registrier|kauf|ticket|termin|warteschlange|schritt für schritt|führ mich|fuehr mich|amtsweg|antrag|formular|abschließ|abschliess')
      .hasMatch(t);
  return url && verb;
}

/// Geht es um einen Amtsweg / eine Lebenslage (ohne konkrete Adresse)? → Skill „Amtsweg-Lotse“
bool wantsAmtsweg(String input) {
  final t = input.toLowerCase();
  if (RegExp(r'https?://').hasMatch(t)) return false;
  final topic = RegExp(
      r'amtsweg|behörde|behoerde|magistrat|bezirksamt|meldezettel|wohnsitz (an|ab|um)melden|(an|ab|um)melden.*wohnsitz|ummelden|'
      r'reisepass|personalausweis|staatsbürgerschaft|geburtsurkunde|heiratsurkunde|sterbeurkunde|parkpickerl|'
      r'familienbeihilfe|kinderbetreuungsgeld|familienbonus|pflegegeld|mindestsicherung|wohnbeihilfe|arbeitnehmerveranlagung|'
      r'führerschein|fuehrerschein|zulassung|ummeldung|abmeldung|anmeldebescheinigung|e-card|id austria|handysignatur|'
      r'lebenslage|todesfall|erbschaft|verlassenschaft|eheschließung|standesamt|gewerbe anmelden|hundeabgabe|wahlkarte',
      caseSensitive: false);
  final ask = RegExp(r'\b(wie|was|wo|welche|brauch|muss|kann ich|beantrag|antrag|anmeld|ummeld|verläng|verlaeng|hilf|unterlagen|kosten|frist)',
      caseSensitive: false);
  return topic.hasMatch(t) && ask.hasMatch(t);
}

/// Erste Adresse in einem Text.
String? firstUrl(String text) {
  final m = RegExp(r'https?://[^\s)>\]]+').firstMatch(text);
  return m?.group(0)?.replaceAll(RegExp(r'[.,;:!?]+$'), '');
}

class GuideStep {
  GuideStep(this.text, {this.you = false, this.status = 'offen'});
  String text;
  bool you; // macht der Nutzer selbst (Anmelden, Zahlen …)
  String status; // offen | aktiv | erledigt

  Map<String, Object> toJson() => {'t': text, if (you) 'du': true, 's': status};
  factory GuideStep.fromJson(Map<String, dynamic> j) =>
      GuideStep('${j['t'] ?? ''}', you: j['du'] == true, status: '${j['s'] ?? 'offen'}');
}

/// Zustand einer Begleitung (liegt am Chat).
class Guide {
  Guide({required this.goal, required this.url, List<GuideStep>? steps, this.state = 'aktiv', this.note = '', this.asked = false})
      : steps = steps ?? [];
  String goal;
  String url;
  final List<GuideStep> steps;
  String state; // aktiv | fertig
  String note; // z. B. Ergebnis der Beobachtung
  bool asked; // Modell-Frage (Cloud) schon gestellt

  bool get active => state == 'aktiv';
  int get current => steps.indexWhere((s) => s.status == 'aktiv');
  int get done => steps.where((s) => s.status == 'erledigt').length;

  Map<String, dynamic> toJson() => {
        'goal': goal,
        'url': url,
        'steps': [for (final s in steps) s.toJson()],
        'state': state,
        if (note.isNotEmpty) 'note': note,
        if (asked) 'asked': true,
      };

  factory Guide.fromJson(Map<String, dynamic> j) => Guide(
        goal: '${j['goal'] ?? ''}',
        url: '${j['url'] ?? ''}',
        steps: [for (final s in (j['steps'] as List? ?? const [])) GuideStep.fromJson((s as Map).cast())],
        state: '${j['state'] ?? 'aktiv'}',
        note: '${j['note'] ?? ''}',
        asked: j['asked'] == true,
      );

  static Guide? of(Conversation? c) => c?.guide == null ? null : Guide.fromJson(c!.guide!);

  /// Plan aus Zeilen („1. Urkundenart wählen“, „Anmelden (du)“).
  void setPlan(String lines) {
    final list = [
      for (final l in lines.split(RegExp(r'\n|;|\|')))
        if (l.trim().replaceAll(RegExp(r'^\s*(\d+[.)]|[-*•])\s*'), '').isNotEmpty) l.trim().replaceAll(RegExp(r'^\s*(\d+[.)]|[-*•])\s*'), ''),
    ];
    if (list.isEmpty) return;
    steps
      ..clear()
      ..addAll([
        for (final l in list.take(12))
          GuideStep(
            l.replaceAll(RegExp(r'\s*\((du|nutzer|selbst|user)\)\s*', caseSensitive: false), ' ').trim(),
            you: RegExp(r'\((du|nutzer|selbst|user)\)', caseSensitive: false).hasMatch(l) ||
                RegExp(r'anmeld|login|einlogg|bezahl|zahlung|unterschr|signatur|captcha|id austria', caseSensitive: false).hasMatch(l),
          ),
      ]);
    steps.first.status = 'aktiv';
  }

  /// Schritt nr (1-basiert) erledigt → nächster wird aktiv.
  void complete(int nr) {
    if (nr < 1 || nr > steps.length) return;
    for (var i = 0; i < nr; i++) {
      steps[i].status = 'erledigt';
    }
    if (nr < steps.length) {
      steps[nr].status = 'aktiv';
    } else {
      state = 'fertig';
    }
  }

  void activate(int nr) {
    if (nr < 1 || nr > steps.length) return;
    for (final s in steps) {
      if (s.status == 'aktiv') s.status = 'offen';
    }
    steps[nr - 1].status = 'aktiv';
  }

  /// Kurzfassung für das Modell (jede Runde).
  String brief() {
    final b = StringBuffer('[BEGLEITUNG aktiv] Ziel: $goal\nStartseite: $url\nPlan:\n');
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final mark = switch (s.status) { 'erledigt' => '✓', 'aktiv' => '▶', _ => '○' };
      b.writeln('$mark ${i + 1}. ${s.text}${s.you ? ' (macht der Nutzer)' : ''}');
    }
    if (note.isNotEmpty) b.writeln('Hinweis: $note');
    b.write('Arbeite am Schritt mit ▶: Seite lesen (browser read), handeln, fehlende Angaben kurz erfragen. '
        'FORMULAR auf der Seite: begleiten aktion formular (liest alle Felder F1, F2 …). Erkläre jedes Feld in einfachen Worten '
        '(was gemeint ist, wo man die Angabe findet – z. B. Meldezettel, Reisepass, Lohnzettel). Frag höchstens 3 Angaben auf einmal '
        'und trag sie mit browser type/select/check (target = F-Nummer) ein. 🔒-Felder (SV-Nummer, Passnummer, IBAN, Passwort) '
        'trägt der Nutzer selbst ein: begleiten aktion zeigen (nr = F-Nummer, text = Erklärung). Vor dem Absenden: begleiten aktion pruefen. '
        'Ist ein Schritt geschafft: begleiten aktion schritt (nr). Anmeldung, Captcha, Zahlung, Unterschrift: begleiten aktion uebergabe. '
        'Warteschlange/auf etwas warten: begleiten aktion warten. Antworte knapp: was du getan hast und was als Nächstes kommt.');
    return b.toString();
  }

  /// Wiederverwendbarer Leitfaden (Prompt-Vorlage).
  String asTemplate() {
    final b = StringBuffer('Begleite mich Schritt für Schritt: $goal\nStartseite: $url\n');
    if (steps.isNotEmpty) {
      b.writeln('Bewährter Ablauf:');
      for (var i = 0; i < steps.length; i++) {
        b.writeln('${i + 1}. ${steps[i].text}${steps[i].you ? ' (du)' : ''}');
      }
    }
    b.write('Öffne die Seite im Browser (Werkzeug begleiten, aktion start) und führe mich durch – Anmeldung und Zahlung mache ich selbst.');
    return b.toString();
  }
}

/// Werkzeug „begleiten“: Plan führen, übergeben, warten, als Vorlage speichern.
class GuideTool extends AgentTool {
  GuideTool({
    required this.conversation,
    required this.save,
    required this.browser,
    required this.service,
    required this.notify,
    required this.saveTemplate,
  });

  final Conversation? Function() conversation;
  final Future<void> Function(Conversation c) save;
  final BrowserTool browser;
  final BrowserService service;
  final Future<void> Function(String title, String body, String? conversationId) notify;
  final Future<void> Function(String title, String text) saveTemplate;

  @override
  String get name => 'begleiten';
  @override
  String get title => 'Begleiten (gemeinsam durch Webseiten)';
  @override
  String get keywords => 'begleiten gemeinsam amtsweg antrag formular beantragen bestellen ticket termin warteschlange schritt für schritt';
  @override
  bool get requiresNetwork => true;
  @override
  String get description =>
      'Führt den Nutzer gemeinsam durch eine Webseite (Amtsweg, Antrag, Tickets, Buchung, Kauf). aktion: '
      '"start" (url, ziel) öffnet die Seite im Browser, den der Nutzer sieht; '
      '"plan" (schritte = 3–8 kurze Schritte, je Zeile, Schritte des Nutzers mit „(du)“: Anmelden, Zahlen, Unterschreiben); '
      '"formular" liest das Formular der Seite (Felder F1 …, Pflicht, Hinweise, ausgefüllt ja/nein); '
      '"zeigen" (nr = F-Nummer, text = Erklärung) hebt ein Feld für den Nutzer hervor; '
      '"pruefen" zeigt vor dem Absenden offene Pflichtfelder und Fehlermeldungen; '
      '"schritt" (nr = geschaffter Schritt); "uebergabe" (text = was der Nutzer selbst tun soll: Anmeldung/ID Austria, Captcha, '
      'Zahlung) – wartet, bis er „Weiter“ tippt; "warten" (text = Wort, auf das gewartet wird, leer = Warteschlange) beobachtet '
      'die Seite und benachrichtigt; "fertig"; "vorlage" (text = Name) speichert den Ablauf. Die Seite bedienst du mit dem Werkzeug browser. '
      'Nie Passwörter, Ausweis- oder Zahlungsdaten eintippen; vor dem Absenden fragt Junels nach.';
  @override
  List<ToolParam> get params => const [
        ToolParam('aktion', ParamType.enumeration, 'Was tun',
            values: ['start', 'plan', 'formular', 'zeigen', 'pruefen', 'schritt', 'uebergabe', 'warten', 'fertig', 'vorlage']),
        ToolParam('url', ParamType.string, 'Adresse (bei start, sonst "")'),
        ToolParam('ziel', ParamType.string, 'Was der Nutzer erreichen will (bei start, sonst "")'),
        ToolParam('schritte', ParamType.string, 'Plan: ein Schritt pro Zeile (bei plan, sonst "")'),
        ToolParam('nr', ParamType.string, 'Nummer des geschafften Schritts (bei schritt) bzw. Feld F-Nummer (bei zeigen), sonst ""'),
        ToolParam('text', ParamType.string, 'Hinweis für den Nutzer, Wartebedingung oder Name (sonst "")'),
      ];

  Future<void> _store(Conversation c, Guide g) async {
    c.guide = g.toJson();
    await save(c);
  }

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final c = conversation();
    if (c == null) throw ToolException('Begleiten geht nur in einem Chat');
    final action = '${args['aktion'] ?? 'start'}'.trim().toLowerCase();
    final text = '${args['text'] ?? ''}'.trim();
    var g = Guide.of(c);

    if (action == 'start') {
      final url = '${args['url'] ?? ''}'.trim().isNotEmpty ? '${args['url']}'.trim() : (firstUrl(ctx.userRequest) ?? g?.url ?? '');
      if (url.isEmpty) throw ToolException('url fehlt – frag den Nutzer nach der Adresse');
      final goal = '${args['ziel'] ?? ''}'.trim().isNotEmpty
          ? '${args['ziel']}'.trim()
          : ctx.userRequest.replaceAll(RegExp(r'https?://\S+'), '').trim();
      g = Guide(goal: goal.isEmpty ? 'Vorgang auf ${Uri.tryParse(url)?.host ?? url}' : goal, url: url, asked: g?.asked ?? false)
        ..setPlan('Seite verstehen und Ablauf klären\nAngaben sammeln\nFormular ausfüllen\nPrüfen & absenden (du bestätigst)');
      await _store(c, g);
      service.stopWatch();
      final page = await browser.run({'action': 'open', 'target': url, 'text': ''}, ctx);
      return 'Begleitung gestartet – der Nutzer sieht die Seite im Browser.\n$page\n\n'
          'NÄCHSTES: begleiten aktion plan mit 3–8 kurzen Schritten für genau diese Seite (Schritte des Nutzers mit „(du)“). '
          'Dann sag in 2–3 Sätzen, wie es abläuft, und frag nach den Angaben für den ersten Schritt.';
    }
    if (g == null) throw ToolException('Noch keine Begleitung – zuerst aktion start mit der Adresse');

    switch (action) {
      case 'formular':
        final form = await browser.run({'action': 'form', 'target': '', 'text': ''}, ctx);
        final f = browser.lastForm;
        final fields = ((f?['fields'] as List?) ?? const []).cast<Map>();
        final open = fields.where((x) => x['required'] == true && x['filled'] != true).length;
        g.note = fields.isEmpty ? '' : 'Formular: ${fields.length} Felder, $open Pflichtfelder offen';
        await _store(c, g);
        if (fields.isEmpty) {
          return '$form\nAuf dieser Seite ist kein Formular. Lies die Seite (browser read) und führe zum Formular (z. B. Link „Online-Antrag“).';
        }
        return '$form\n\nSO WEITER: Erkläre in 2–4 Sätzen, worum es in diesem Formular(-schritt) geht und welche Unterlagen man '
            'bereitlegen sollte. Dann frag die ersten 1–3 offenen Pflichtangaben in einfachen Worten ab (mit kurzer Erklärung, '
            'wo man sie findet). 🔒-Felder nicht erfragen – mit begleiten aktion zeigen hervorheben, der Nutzer tippt selbst.';
      case 'zeigen':
        final nr = '${args['nr'] ?? ''}'.trim().isNotEmpty ? '${args['nr']}'.trim() : text;
        if (nr.isEmpty) throw ToolException('nr (Feld, z. B. F3) fehlt');
        return browser.run({'action': 'mark', 'target': nr.toUpperCase().startsWith('F') ? nr : 'F$nr', 'text': text == nr ? '' : text}, ctx);
      case 'pruefen':
        final form = await browser.run({'action': 'form', 'target': '', 'text': ''}, ctx);
        final f = browser.lastForm;
        final fields = ((f?['fields'] as List?) ?? const []).cast<Map>();
        final missing = [for (final x in fields) if (x['required'] == true && x['filled'] != true) '${x['id']} ${x['label']}'];
        final bad = [for (final x in fields) if (x['invalid'] == true) '${x['id']} ${x['label']}'];
        final errs = ((f?['errors'] as List?) ?? const []);
        if (missing.isEmpty && bad.isEmpty && errs.isEmpty) {
          return '$form\n\nALLES AUSGEFÜLLT. Fass für den Nutzer in 2–3 Sätzen zusammen, was eingetragen wurde (ohne 🔒-Angaben), '
              'erinnere an Beilagen/Unterschrift und frag, ob abgeschickt werden soll. Den Absende-Knopf klickst du erst nach seinem Ja '
              '(Junels fragt zusätzlich nach).';
        }
        return '$form\n\nNOCH NICHT FERTIG: ${missing.isEmpty ? '' : 'offene Pflichtfelder: ${missing.join(', ')}. '}'
            '${bad.isEmpty ? '' : 'fehlerhaft: ${bad.join(', ')}. '}${errs.isEmpty ? '' : 'Meldungen: ${errs.join(' · ')}. '}'
            'Erklär dem Nutzer kurz, was fehlt bzw. falsch ist und wie es richtig geht (z. B. Datumsformat TT.MM.JJJJ).';
      case 'plan':
        final lines = '${args['schritte'] ?? ''}'.trim().isNotEmpty ? '${args['schritte']}' : text;
        if (lines.trim().isEmpty) throw ToolException('schritte fehlen (ein Schritt pro Zeile)');
        g.setPlan(lines);
        await _store(c, g);
        return 'Plan gespeichert (der Nutzer sieht ihn als Liste):\n${g.brief()}';
      case 'schritt':
        final nr = int.tryParse('${args['nr'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '')) ?? (g.current + 1);
        g.complete(nr);
        await _store(c, g);
        if (!g.active) return 'Alle Schritte erledigt. Sag dem Nutzer, dass es geschafft ist, und biete an, den Ablauf als Vorlage zu speichern.';
        return 'Schritt $nr erledigt.\n${g.brief()}';
      case 'uebergabe':
        final msg = text.isEmpty ? 'Bitte erledige diesen Schritt selbst im Browser und tippe dann auf „Weiter“.' : text;
        final ok = await service.handOver('🙋 $msg');
        final page = await browser.run({'action': 'read', 'target': '', 'text': ''}, ctx);
        return ok
            ? 'Der Nutzer hat übernommen und „Weiter“ getippt. Aktuelle Seite:\n$page\nPrüfe, ob der Schritt geklappt hat (dann begleiten aktion schritt), und mach weiter.'
            : 'Der Nutzer hat abgebrochen bzw. nicht reagiert. Frag kurz, wie es weitergehen soll.';
      case 'warten':
        final convId = c.id;
        service.startWatch(
          until: text,
          everySeconds: text.isEmpty ? 20 : 45,
          onHit: (msg) async {
            final cur = Guide.of(c);
            if (cur != null) {
              cur.note = '$msg (${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')})';
              await _store(c, cur);
            }
            await notify('Junels: ${g!.goal.length > 40 ? '${g.goal.substring(0, 40)}…' : g.goal}', msg, convId);
          },
        );
        g.note = text.isEmpty ? 'Junels beobachtet die Warteschlange.' : 'Junels wartet auf „$text“.';
        await _store(c, g);
        ctx.answerNow = true;
        return 'Beobachtung läuft (${text.isEmpty ? 'Warteschlange/Änderung' : '„$text“'}). Der Nutzer bekommt eine Benachrichtigung, '
            'sobald es so weit ist – Junels muss dafür geöffnet bleiben (darf im Hintergrund sein). Sag ihm das kurz.';
      case 'fertig':
        for (final s in g.steps) {
          s.status = 'erledigt';
        }
        g.state = 'fertig';
        service.stopWatch();
        await _store(c, g);
        return 'Begleitung abgeschlossen. Fasse in 1–2 Sätzen zusammen und biete an, den Ablauf als Vorlage zu speichern.';
      case 'vorlage':
        final name = text.isEmpty ? g.goal : text;
        await saveTemplate(name.length > 60 ? '${name.substring(0, 60)}…' : name, g.asTemplate());
        return 'Als Vorlage „$name“ gespeichert (Vorlagen im Eingabefeld). Sag es dem Nutzer kurz.';
      default:
        throw ToolException('Unbekannte aktion „$action“');
    }
  }
}
