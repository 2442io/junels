// Macht aus einem beschriebenen Folienplan („Folie 1: … – Layout: … – Text: …“)
// echte Folien in Markdown (je Folie „# Titel“ + Stichpunkte).

final _slideHead = RegExp(
    r'^\s*(?:#{1,4}\s*)?(?:\*\*)?\s*(?:Folie|Slide|Seite)\s*(\d+)\s*(?:[:.\-–—)]\s*)?(.*?)\s*(?:\*\*)?\s*$',
    caseSensitive: false);
final _mdHead = RegExp(r'^\s*#{1,3}\s+(.+?)\s*$');
final _skipLabel = RegExp(
    r'^(?:layout|grafik(?:-idee)?|grafikidee|bild(?:idee)?|visual|design|stil|style|icon|icons|farben?|hintergrund|animation|übergang|'
    r'sprechernotiz(?:en)?|notizen|speaker notes|schriftart|font)\s*:',
    caseSensitive: false);
final _keepLabel = RegExp(r'^(?:text|inhalt|content|kernaussage|aussage|botschaft|stichpunkte|punkte)\s*:\s*', caseSensitive: false);
final _stop = RegExp(r'^\s*(?:#+\s*)?(?:\*\*)?\s*(?:anleitung|umsetzung|so setzt du|tipps zur umsetzung|nächste schritte)', caseSensitive: false);

String _clean(String s) {
  var t = s.trim();
  t = t.replaceAllMapped(RegExp(r'^\*\*(.+?)\*\*$'), (m) => m.group(1)!);
  t = t.replaceAll(RegExp(r'\s*\((?:the |die |der )?[A-Za-z ]+\)\s*$'), ''); // „(The Hook)“
  t = t.replaceAll(RegExp(r'\[(?:icon|bild|grafik|foto)[^\]]*\]\s*[–—-]?\s*', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'\s*\((?:icon|bild)[^)]*\)', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'^[„"“]|[“"”]$'), '');
  return t.trim();
}

/// Ergebnis: Titel (aus Folie 1 bzw. erster Überschrift) und Folien-Markdown.
({String title, String content}) slidesFromPlan(String plan) {
  final lines = plan.replaceAll('\r', '').split('\n');
  final slides = <(String, List<String>)>[];
  String? docTitle;
  var useMd = !lines.any((l) => _slideHead.hasMatch(l) && RegExp(r'folie|slide|seite', caseSensitive: false).hasMatch(l));
  for (final raw in lines) {
    if (_stop.hasMatch(raw) && slides.isNotEmpty) break;
    if (raw.trim() == '---') continue;
    final h = useMd ? _mdHead.firstMatch(raw) : _slideHead.firstMatch(raw);
    if (h != null && (useMd || RegExp(r'folie|slide|seite', caseSensitive: false).hasMatch(raw))) {
      var title = _clean(useMd ? h.group(1)! : h.group(2)!);
      if (title.isEmpty) title = 'Folie ${slides.length + 1}';
      slides.add((title, []));
      continue;
    }
    if (slides.isEmpty) {
      final t = _mdHead.firstMatch(raw);
      if (t != null) docTitle ??= _clean(t.group(1)!);
      continue;
    }
    var l = raw.trimRight();
    if (l.trim().isEmpty) continue;
    final indent = RegExp(r'^\s*').firstMatch(l)!.group(0)!.length;
    var body = l.trim().replaceFirst(RegExp(r'^(?:[-*•]|\d+[.)])\s+'), '');
    final numbered = RegExp(r'^\d+[.)]\s').hasMatch(l.trim());
    final plain = body.replaceAll('**', '');
    if (_skipLabel.hasMatch(plain)) continue;
    if (_keepLabel.hasMatch(plain)) body = plain.replaceFirst(_keepLabel, '');
    body = _clean(body);
    if (body.isEmpty || RegExp(r':$').hasMatch(body.replaceAll('**', '')) && body.length < 30) continue;
    slides.last.$2.add('${indent >= 3 && !numbered && slides.last.$2.isNotEmpty ? '  ' : ''}- $body');
  }
  if (slides.isEmpty) return (title: '', content: '');
  final title = docTitle ?? slides.first.$1;
  final b = StringBuffer();
  for (final (t, body) in slides) {
    b.writeln('# $t');
    for (final l in body) {
      b.writeln(l);
    }
    b.writeln();
  }
  return (title: title, content: b.toString().trim());
}
