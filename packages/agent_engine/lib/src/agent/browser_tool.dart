import 'dart:convert';

import 'network_tools.dart';
import 'site_search_tool.dart';
import 'tool.dart';

/// Ein echter Browser (WebView), den der Agent bedient. Die App liefert die Umsetzung.
abstract class BrowserDriver {
  /// Browser sichtbar machen (der Nutzer schaut zu).
  Future<void> show();

  /// Adresse laden und warten, bis die Seite fertig ist.
  Future<void> open(Uri url);

  /// JavaScript ausführen; das Skript gibt einen JSON-Text zurück.
  Future<String> eval(String js);

  /// Nach einer Aktion warten, bis eine ausgelöste Navigation fertig ist.
  Future<void> settle();

  Future<void> back();

  /// Ja/Nein beim Nutzer einholen (Bestellen, Absenden …).
  Future<bool> confirm(String title, String detail);

  /// Nutzer übernimmt selbst (Captcha, Anmeldung); kehrt zurück, wenn er „Weiter“ tippt.
  Future<bool> handOver(String message);
}

/// Liest die Seite: nummerierte Elemente, Text und Produkt-/Ergebnis-Karten.
const browserSnapshotJs = r'''
(function(){
  var vis=function(e){var r=e.getBoundingClientRect();if(r.width<2||r.height<2)return false;var s=getComputedStyle(e);return s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0';};
  var txt=function(s){return (s||'').replace(/\s+/g,' ').trim();};
  var it=function(e){return e?(e.innerText||e.textContent||''):'';};
  document.querySelectorAll('[data-jid]').forEach(function(e){e.removeAttribute('data-jid');});
  var els=[],n=0;
  var sel='a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[role=searchbox],[role=tab],[contenteditable=true],summary';
  var all=Array.prototype.slice.call(document.querySelectorAll(sel)).filter(vis);
  var vh=innerHeight;
  all.sort(function(a,b){return a.getBoundingClientRect().top-b.getBoundingClientRect().top;});
  // Erst was im sichtbaren Bereich (und knapp darunter) liegt
  var near=all.filter(function(e){var t=e.getBoundingClientRect().top;return t>-50&&t<vh*2.2;});
  for(var i=0;i<near.length&&n<70;i++){
    var e=near[i],tag=e.tagName.toLowerCase(),type=(e.getAttribute('type')||'').toLowerCase();
    var img=e.querySelector&&e.querySelector('img');
    var label=txt(e.getAttribute('aria-label'))||txt(it(e))||txt(e.getAttribute('placeholder'))||txt(e.getAttribute('title'))||txt(e.value)||(img?txt(img.alt):'')||txt(e.getAttribute('name'));
    if(!label&&tag!=='input'&&tag!=='textarea'&&tag!=='select')continue;
    n++;e.setAttribute('data-jid',String(n));
    var kind=tag==='a'?'link':(tag==='input'||tag==='textarea'||e.getAttribute('contenteditable')==='true'||e.getAttribute('role')==='searchbox')?'input':tag==='select'?'select':'button';
    if(tag==='input'&&(type==='submit'||type==='button'||type==='image'))kind='button';
    if(tag==='input'&&(type==='checkbox'||type==='radio'))kind=type;
    var o={id:n,kind:kind,label:label.slice(0,90)};
    if(kind==='input'){o.type=type||tag;o.ph=txt(e.getAttribute('placeholder')).slice(0,40);o.name=(e.getAttribute('name')||'').slice(0,30);
      var ac=(e.getAttribute('autocomplete')||'').toLowerCase();
      if(type==='password'||ac.indexOf('cc-')===0||ac.indexOf('password')>=0||/card|cvc|cvv|iban|kreditkarte|kartennummer/i.test(o.name+' '+o.ph))o.secret=1;
      if(type==='search'||/such|search|query|^q$|^k$|^s$|^fs$/i.test(o.name+' '+o.ph+' '+label)||e.getAttribute('role')==='searchbox')o.search=1;}
    if(kind==='link')o.href=e.href;
    if(kind==='select')o.options=Array.prototype.slice.call(e.options||[]).slice(0,12).map(function(x){return txt(x.text);});
    if(kind==='checkbox'||kind==='radio')o.checked=!!e.checked;
    els.push(o);
  }
  // Karten: Links mit Bild und Text (Produkte, Artikel)
  var cards=[],seen={};
  var boxes=document.querySelectorAll('[data-component-type="s-search-result"],article,li,div[class*="product"],div[class*="item"],div[class*="result"]');
  for(var j=0;j<boxes.length&&cards.length<40;j++){
    var b=boxes[j];if(!vis(b))continue;
    var im=b.querySelector('img');var h=b.querySelector('h2,h3,h4,[class*="title"],[class*="name"]');
    var a=(h&&(h.closest('a')||h.querySelector('a')))||b.querySelector('a[href]');
    if(!im||!a||!a.href||seen[a.href])continue;
    var t=txt(it(h||a))||txt(im.alt);
    if(t.length<8||b.querySelectorAll('img').length>8)continue;
    seen[a.href]=1;
    var m=txt(it(b)).match(/(ab\s*)?(€\s*\d[\d.]*,\d{2}|\d[\d.]*,\d{2}\s*€|EUR\s*\d[\d.]*,\d{2})/);
    var src=im.getAttribute('data-src')||im.getAttribute('data-lazy-src')||im.currentSrc||im.src||'';
    var ss=im.getAttribute('srcset')||im.getAttribute('data-srcset')||'';
    if((!src||src.indexOf('data:')===0||/grey-pixel|transparent|spacer|1x1|blank\./i.test(src))&&ss)src=ss.split(',')[0].trim().split(' ')[0];
    if(src.indexOf('data:')===0)src='';
    try{if(src)src=new URL(src,location.href).href;}catch(x){}
    cards.push({title:t.slice(0,140),link:a.href,image:src,price:m?m[0]:''});
  }
  var main=document.querySelector('main,[role=main],#content,#main')||document.body;
  var body=txt(it(main));
  var captcha=!!document.querySelector('iframe[src*="recaptcha"],iframe[src*="hcaptcha"],iframe[src*="challenges.cloudflare"],#captchacharacters,form[action*="validateCaptcha"]')||/captcha|ich bin kein roboter|i.m not a robot|verify you are human|geben sie die zeichen ein/i.test(body.slice(0,3000));
  return JSON.stringify({url:location.href,title:document.title,els:els,cards:cards,text:body.slice(0,2500),captcha:captcha,more:all.length>near.length,scrollY:Math.round(scrollY),height:document.body?document.body.scrollHeight:0});
})()
''';

String _actJs(int id, String action, [String text = '', bool submit = false]) => '''
(function(){
  var e=document.querySelector('[data-jid="$id"]');
  if(!e)return JSON.stringify({ok:false,error:'Element $id nicht mehr auf der Seite – lies die Seite neu (action read)'});
  if(e.scrollIntoView)e.scrollIntoView({block:'center'});
  var act=${jsonEncode(action)},v=${jsonEncode(text)};
  if(act==='click'){
    if(e.tagName==='A'&&e.target==='_blank'&&e.href){location.href=e.href;return JSON.stringify({ok:true});}
    e.click();return JSON.stringify({ok:true});
  }
  if(act==='type'){
    if(!(e.tagName==='INPUT'||e.tagName==='TEXTAREA'||e.isContentEditable))return JSON.stringify({ok:false,error:'Element $id ist kein Eingabefeld'});
    e.focus();
    if(e.isContentEditable){e.textContent=v;}else{
      var p=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      var d=Object.getOwnPropertyDescriptor(p,'value');if(d&&d.set)d.set.call(e,v);else e.value=v;}
    e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
    if($submit){
      var ev={key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true};
      e.dispatchEvent(new KeyboardEvent('keydown',ev));e.dispatchEvent(new KeyboardEvent('keypress',ev));e.dispatchEvent(new KeyboardEvent('keyup',ev));
      var f=e.form;
      if(f){setTimeout(function(){try{if(f.requestSubmit)f.requestSubmit();else f.submit();}catch(x){}},150);}
    }
    return JSON.stringify({ok:true});
  }
  if(act==='select'){
    var o=Array.prototype.slice.call(e.options||[]).find(function(x){return x.text.toLowerCase().indexOf(v.toLowerCase())>=0;});
    if(!o)return JSON.stringify({ok:false,error:'Option nicht gefunden'});
    e.value=o.value;e.dispatchEvent(new Event('change',{bubbles:true}));return JSON.stringify({ok:true});
  }
  return JSON.stringify({ok:false,error:'unbekannte Aktion'});
})()
''';

/// Wörter, bei denen der Agent vor dem Klick nachfragt.
final _riskyLabel = RegExp(
    r'kaufen|bestell|zur kasse|kasse\b|checkout|bezahl|zahlungspflichtig|jetzt buchen|buchen|buy|order|pay\b|purchase|'
    r'senden|absenden|abschicken|abschließen|submit|send\b|post\b|veröffentlich|löschen|delete|entfernen|kündig|'
    r'abonnier|subscribe|registrier|konto erstellen|sign ?up|bestätig|confirm',
    caseSensitive: false);

class BrowserTool extends AgentTool {
  BrowserTool(this.driver);
  final BrowserDriver? Function() driver;

  @override
  String get name => 'browser';
  @override
  String get title => 'Browser';
  @override
  String get keywords => 'browser öffne seite webseite klick klicke anmelden formular scroll navigieren surfen amazon shop';
  @override
  String get description =>
      'Bedient einen echten Browser, den der Nutzer sieht. action: "open" (target = Adresse), "search" (target = Webseite, '
      'text = Suchbegriffe; sucht über das Suchfeld der Seite), "click" (target = Nummer), "type" (target = Nummer, text; '
      'mit Enter), "select" (target = Nummer, text = Option), "scroll" (target = "down"/"up"), "back", "read". '
      'Nach jeder Aktion bekommst du die Seite mit nummerierten Elementen [n]. Nie Passwörter oder Zahlungsdaten eingeben.';
  @override
  bool get requiresNetwork => true;
  @override
  List<ToolParam> get params => const [
        ToolParam('action', ParamType.enumeration, 'Was tun',
            values: ['open', 'search', 'click', 'type', 'select', 'scroll', 'back', 'read']),
        ToolParam('target', ParamType.string, 'Adresse, Webseite oder Nummer des Elements'),
        ToolParam('text', ParamType.string, 'Text zum Eingeben oder Suchbegriffe (sonst leer)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final d = driver();
    if (d == null) throw ToolException('Der Browser ist nur verfügbar, wenn die App geöffnet ist');
    final action = (args['action'] ?? 'read').toString().trim().toLowerCase();
    final target = (args['target'] ?? '').toString().trim();
    final text = (args['text'] ?? '').toString();
    await ctx.ensureNetwork(switch (action) {
      'open' => 'Browser: $target öffnen',
      'search' => 'Browser: auf $target nach „$text“ suchen',
      _ => 'Browser bedienen',
    });
    await d.show();
    switch (action) {
      case 'open' || 'goto' || 'navigate':
        await d.open(_url(target));
      case 'search':
        if (text.trim().isEmpty) throw ToolException('text (Suchbegriffe) fehlt');
        return _search(d, target, text.trim());
      case 'click':
        final el = await _element(d, target);
        final label = (el['label'] ?? '').toString();
        if (_riskyLabel.hasMatch(label) &&
            !await d.confirm('Im Browser klicken?', '„$label“\nDer Agent möchte diesen Knopf drücken.')) {
          return 'Der Nutzer hat den Klick auf „$label“ abgelehnt. Frag, wie es weitergehen soll.';
        }
        await _act(d, _actJs(el['id'] as int, 'click'));
      case 'type' || 'fill':
        final el = await _element(d, target);
        if (el['secret'] == 1) {
          await d.handOver('Bitte gib das selbst ein (Passwort oder Zahlungsdaten) und tippe dann auf „Weiter“.');
          return _snapshot(d, note: 'Der Nutzer hat das Feld selbst ausgefüllt.');
        }
        await _act(d, _actJs(el['id'] as int, 'type', text, true));
      case 'select':
        final el = await _element(d, target);
        await _act(d, _actJs(el['id'] as int, 'select', text));
      case 'scroll':
        final up = target.toLowerCase().contains('up') || target.toLowerCase().contains('hoch');
        await d.eval('(function(){window.scrollBy(0,${up ? '-' : ''}Math.round(innerHeight*0.8));return "{}";})()');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      case 'back':
        await d.back();
      case 'read' || 'snapshot':
        break;
      default:
        throw ToolException('Unbekannte action „$action“');
    }
    if (action != 'read' && action != 'snapshot' && action != 'scroll') await d.settle();
    return _snapshot(d);
  }

  static Uri _url(String target) {
    var t = target.trim();
    if (t.isEmpty) throw ToolException('target (Adresse) fehlt');
    if (!t.contains('://')) {
      if (!t.contains('.')) t = normalizeSite(t);
      t = 'https://$t';
    }
    final u = Uri.tryParse(t);
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) {
      throw ToolException('„$target“ ist keine gültige Adresse');
    }
    return u;
  }

  Future<String> _search(BrowserDriver d, String site, String q) async {
    final s = normalizeSite(site);
    final tpl = siteSearchTemplates[s];
    if (tpl != null) {
      await d.open(Uri.parse(tpl.replaceAll('{q}', Uri.encodeQueryComponent(q))));
      return _snapshot(d, note: 'Auf $s nach „$q“ gesucht.');
    }
    await d.open(_url(site));
    var snap = await _read(d);
    if (snap['captcha'] == true) snap = await _captcha(d);
    final els = (snap['els'] as List).cast<Map<String, dynamic>>();
    final field = els.where((e) => e['kind'] == 'input' && e['search'] == 1).firstOrNull ??
        els.where((e) => e['kind'] == 'input' && (e['type'] == 'text' || e['type'] == 'input') && e['secret'] != 1).firstOrNull;
    if (field == null) {
      return _format(snap, note: 'Kein Suchfeld gefunden. Such selbst einen passenden Link oder Knopf (z. B. Lupe) und klicke ihn.');
    }
    await _act(d, _actJs(field['id'] as int, 'type', q, true));
    await d.settle();
    return _snapshot(d, note: 'Suchfeld [${field['id']}] ausgefüllt und abgeschickt.');
  }

  static Future<void> _act(BrowserDriver d, String js) async {
    final r = _decode(await d.eval(js));
    if (r['ok'] != true) throw ToolException((r['error'] ?? 'Aktion fehlgeschlagen').toString());
  }

  Future<Map<String, dynamic>> _element(BrowserDriver d, String target) async {
    final id = int.tryParse(target.replaceAll(RegExp(r'[^0-9]'), ''));
    if (id == null) throw ToolException('target muss die Nummer eines Elements sein, z. B. 3');
    var els = _lastEls;
    if (els.isEmpty) els = ((await _read(d))['els'] as List).cast<Map<String, dynamic>>();
    final el = els.where((e) => e['id'] == id).firstOrNull;
    if (el == null) throw ToolException('Element [$id] gibt es nicht – lies die Seite neu (action read)');
    return el;
  }

  List<Map<String, dynamic>> _lastEls = const [];

  Future<Map<String, dynamic>> _read(BrowserDriver d) async {
    var snap = _decode(await d.eval(browserSnapshotJs));
    // Seite noch nicht fertig aufgebaut (oder Browser gerade erst erstellt) → kurz warten, nochmal
    for (var i = 0; i < 3 && ((snap['els'] as List?) ?? const []).isEmpty && (snap['text'] ?? '').toString().length < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      snap = _decode(await d.eval(browserSnapshotJs));
    }
    _lastEls = ((snap['els'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return snap;
  }

  Future<Map<String, dynamic>> _captcha(BrowserDriver d) async {
    final ok = await d.handOver('Die Seite will eine Sicherheitsabfrage (Captcha). Bitte löse sie und tippe dann auf „Weiter“.');
    if (!ok) throw ToolException('Sicherheitsabfrage nicht gelöst – der Nutzer hat abgebrochen');
    await d.settle();
    return _read(d);
  }

  Future<String> _snapshot(BrowserDriver d, {String note = ''}) async {
    var snap = await _read(d);
    if (snap['captcha'] == true) snap = await _captcha(d);
    return _format(snap, note: note);
  }

  static Map<String, dynamic> _decode(String raw) {
    Object? v = raw;
    // Android liefert das Ergebnis doppelt als JSON-Text
    for (var i = 0; i < 3 && v is String; i++) {
      try {
        v = jsonDecode(v);
      } catch (_) {
        break;
      }
    }
    if (v is Map<String, dynamic>) return v;
    throw ToolException('Seite konnte nicht gelesen werden');
  }

  /// Seite als Text für das Modell; Karten nach dem Marker nur fürs Karussell.
  static String formatSnapshot(Map<String, dynamic> snap, {String note = ''}) => _format(snap, note: note);

  static String _format(Map<String, dynamic> snap, {String note = ''}) {
    final b = StringBuffer();
    if (note.isNotEmpty) b.writeln(note);
    b.writeln('Seite: ${snap['title'] ?? ''} (${snap['url'] ?? ''})');
    final cards = [
      for (final c in ((snap['cards'] as List?) ?? const []).cast<Map<String, dynamic>>())
        if (!isJunkLink((c['link'] ?? '').toString(), (c['title'] ?? '').toString()))
          PageItem((c['title'] ?? '').toString(), cleanLink((c['link'] ?? '').toString()), (c['image'] ?? '').toString(),
              summary: (c['price'] ?? '').toString().isEmpty ? '' : 'Preis: ${c['price']}'),
    ];
    if (cards.isNotEmpty) {
      b.writeln('Treffer (der Nutzer sieht sie als Karten):');
      b.write(formatCardItems(cards.take(5)));
    }
    b.writeln('Elemente:');
    for (final e in ((snap['els'] as List?) ?? const []).cast<Map<String, dynamic>>().take(40)) {
      final kind = switch (e['kind']) {
        'input' => e['search'] == 1 ? 'Suchfeld' : (e['secret'] == 1 ? 'Geheimfeld (nicht ausfüllen)' : 'Eingabe'),
        'link' => 'Link',
        'select' => 'Auswahl',
        'checkbox' => 'Kästchen${e['checked'] == true ? ' ✓' : ''}',
        'radio' => 'Option${e['checked'] == true ? ' ●' : ''}',
        _ => 'Knopf',
      };
      final extra = e['kind'] == 'select' ? ' (${(e['options'] as List?)?.take(6).join(' | ')})' : '';
      b.writeln('[${e['id']}] $kind „${e['label']}“$extra');
    }
    if (snap['more'] == true) b.writeln('(weiter unten gibt es mehr – action scroll)');
    final text = (snap['text'] ?? '').toString();
    if (text.isNotEmpty) b.writeln('Text: ${text.length > 600 ? '${text.substring(0, 600)}…' : text}');
    b.writeln('Antworte, sobald du genug weißt; sonst nächste Aktion. Nenne Produkte mit Namen und Preis, '
        'aber schreib keine Adressen (URLs) in die Antwort – die Karten zeigen die Links. '
        'Bei Bestellung/Zahlung: der Nutzer macht das selbst.');
    if (cards.length > 5) b..write(moreCardsMarker)..write(formatCardItems(cards.skip(5).take(35)));
    return b.toString().trim();
  }
}

/// Nur für Tests: Aktions-Skript erzeugen.
String debugActJs(int id, String action, [String text = '', bool submit = false]) => _actJs(id, action, text, submit);
