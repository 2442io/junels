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
    // Eingabefelder: nie den eingegebenen Wert lesen (Passwörter, persönliche Daten) – nur Beschriftungen
    var isField=(tag==='input'&&!/^(submit|button|image|reset)$/.test(type))||tag==='textarea'||tag==='select';
    var lab=e.id?document.querySelector('label[for="'+e.id+'"]'):null;
    var label=txt(e.getAttribute('aria-label'))||(isField?'':txt(it(e)))||txt(lab?it(lab):'')||txt(e.getAttribute('placeholder'))||txt(e.getAttribute('title'))||(isField?'':txt(e.value))||(img?txt(img.alt):'')||txt(e.getAttribute('name'));
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
  // Seiten ohne <img> in den Einträgen (Hintergrundbilder, reine Textlisten): Links mit längerem Text
  if(cards.length<3){
    var bg=function(e){for(var k=0;e&&k<4;k++,e=e.parentElement){if(k>0&&e.querySelectorAll('a[href]').length>1)break;var c=getComputedStyle(e).backgroundImage;var mm=c&&c.match(/url\(["']?([^"')]+)/);if(mm)return mm[1];var ii=e.querySelector&&e.querySelector('img');if(ii&&(ii.currentSrc||ii.src))return ii.currentSrc||ii.src;}return '';};
    var as=document.querySelectorAll('a[href]');
    for(var q=0;q<as.length&&cards.length<40;q++){
      var A=as[q];if(!vis(A)||!A.href||A.href.indexOf('#')===A.href.length-1||seen[A.href])continue;
      if(A.closest&&A.closest('header,nav,footer'))continue;
      var hh=A.querySelector('h1,h2,h3,h4,strong,[class*="title"]');
      var T=txt(it(hh||A));
      if(T.length<20)continue;
      seen[A.href]=1;
      var box=A.closest('li,article,div');
      if(!box||box.querySelectorAll('a[href]').length>1)box=A;
      var desc=txt(it(box)).replace(T,'').trim().slice(0,200);
      cards.push({title:T.slice(0,140),link:A.href,image:bg(A),price:'',desc:desc});
    }
  }
  var main=document.querySelector('main,[role=main],#content,#main')||document.body;
  var body=txt(it(main));
  var captcha=!!document.querySelector('iframe[src*="recaptcha"],iframe[src*="hcaptcha"],iframe[src*="challenges.cloudflare"],#captchacharacters,form[action*="validateCaptcha"]')||/captcha|ich bin kein roboter|i.m not a robot|verify you are human|geben sie die zeichen ein/i.test(body.slice(0,3000));
  return JSON.stringify({url:location.href,title:document.title,els:els,cards:cards,text:body.slice(0,2500),captcha:captcha,more:all.length>near.length,scrollY:Math.round(scrollY),height:document.body?document.body.scrollHeight:0});
})()
''';


/// Liest ein Formular vollständig: Felder mit Beschriftung, Abschnitt, Pflicht, Hinweis, Fehlern und ob schon etwas
/// eingetragen ist – NIE den eingetragenen Wert. Felder bekommen data-jfid (Ziel „F3“).
const browserFormJs = r'''
(function(){
  var txt=function(s){return (s||'').replace(/\s+/g,' ').trim();};
  var it=function(e){return e?(e.innerText||e.textContent||''):'';};
  var vis=function(e){var r=e.getBoundingClientRect();var s=getComputedStyle(e);return (r.width>1||r.height>1)&&s.visibility!=='hidden'&&s.display!=='none';};
  document.querySelectorAll('[data-jfid]').forEach(function(e){e.removeAttribute('data-jfid');});
  var heads=Array.prototype.slice.call(document.querySelectorAll('h1,h2,h3,h4,legend,.section-title,[role=heading]')).filter(vis);
  var sectionOf=function(e){
    var fs=e.closest&&e.closest('fieldset');var lg=fs&&fs.querySelector('legend');if(lg)return txt(it(lg)).slice(0,80);
    var best='';for(var i=0;i<heads.length;i++){if(heads[i].compareDocumentPosition(e)&Node.DOCUMENT_POSITION_FOLLOWING)best=txt(it(heads[i]));}
    return best.slice(0,80);
  };
  var labelOf=function(e){
    var l='';
    if(e.id){var lf=document.querySelector('label[for="'+CSS.escape(e.id)+'"]');if(lf)l=txt(it(lf));}
    if(!l&&e.closest){var wl=e.closest('label');if(wl)l=txt(it(wl));}
    if(!l&&e.getAttribute('aria-labelledby')){l=e.getAttribute('aria-labelledby').split(' ').map(function(id){var x=document.getElementById(id);return x?txt(it(x)):'';}).join(' ');}
    if(!l)l=txt(e.getAttribute('aria-label'));
    if(!l&&e.closest){var td=e.closest('td,dd,.form-group,.field,.row');
      if(td&&td.tagName==='TD'){var tr=td.parentElement;var cells=Array.prototype.slice.call(tr.children);var k=cells.indexOf(td);
        for(var j=k-1;j>=0&&!l;j--)l=txt(it(cells[j]));}
      else if(td&&td.tagName==='DD'){var dt=td.previousElementSibling;if(dt)l=txt(it(dt));}
      else if(td){var c=td.cloneNode(true);c.querySelectorAll('input,select,textarea,option,script,style').forEach(function(x){x.remove();});l=txt(it(c));}}
    if(!l){var p=e.previousElementSibling;if(p&&!/INPUT|SELECT|TEXTAREA/.test(p.tagName))l=txt(it(p));}
    if(!l)l=txt(e.getAttribute('placeholder'))||txt(e.getAttribute('title'))||txt(e.getAttribute('name'));
    return l.slice(0,120);
  };
  var hintOf=function(e){
    var h='';var d=e.getAttribute('aria-describedby');
    if(d)h=d.split(' ').map(function(id){var x=document.getElementById(id);return x?txt(it(x)):'';}).join(' ');
    if(!h&&e.title)h=txt(e.title);
    if(!h&&e.parentElement){var n=e.parentElement.querySelector('small,.hint,.help,.helptext,.form-text,.description,.info');if(n)h=txt(it(n));}
    return h.slice(0,200);
  };
  var fields=[],n=0,radios={};
  var all=Array.prototype.slice.call(document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=image]):not([type=reset]),select,textarea'));
  for(var i=0;i<all.length&&fields.length<90;i++){
    var e=all[i];if(!vis(e)||e.disabled)continue;
    var type=(e.getAttribute('type')||e.tagName).toLowerCase();
    var label=labelOf(e);
    var req=!!(e.required||e.getAttribute('aria-required')==='true'||/\*\s*$|\(pflicht|pflichtfeld/i.test(label)||/required|pflicht/i.test(e.className));
    var low=(label+' '+(e.name||'')+' '+(e.getAttribute('autocomplete')||'')).toLowerCase();
    var secret=type==='password'||/passwort|password|kennwort|\bpin\b|\btan\b|sozialversicherung|svnr|sv-nummer|versicherungsnummer|reisepass|passnummer|pass-nr|ausweis|personalausweis|iban|\bbic\b|kontonummer|kreditkarte|kartennummer|cvc|cvv|steuernummer|cc-/.test(low);
    if(type==='radio'){
      var g=e.name||('r'+i);
      var optLabel=labelOf(e);
      if(radios[g]){radios[g].options.push(optLabel);if(e.checked)radios[g].filled=true;continue;}
      n++;e.setAttribute('data-jfid',String(n));
      // Frage zur Gruppe: Text direkt vor dem ersten Knopf (z. B. „Hauptwohnsitz? *“), sonst Tabellenzeile/Legende
      var gl='';var nd=(e.closest&&e.closest('label'))||e;
      for(var pv=nd.previousElementSibling,k2=0;pv&&k2<6&&!gl;pv=pv.previousElementSibling,k2++){if(!pv.querySelector('input')&&!/INPUT|SELECT/.test(pv.tagName))gl=txt(it(pv));}
      if(!gl){var tr2=e.closest&&e.closest('tr');if(tr2&&tr2.firstElementChild&&!tr2.firstElementChild.querySelector('input'))gl=txt(it(tr2.firstElementChild));}
      if(!gl){var grp=e.closest&&(e.closest('fieldset')||e.closest('.form-group'));gl=grp?txt(it(grp.querySelector('legend')||grp.firstElementChild||grp)):optLabel;}
      gl=gl.slice(0,100);
      if(/\*\s*$/.test(gl))req=true;
      radios[g]={id:'F'+n,kind:'radio',label:gl,options:[optLabel],filled:!!e.checked,required:req,section:sectionOf(e),hint:hintOf(e),name:g};
      fields.push(radios[g]);continue;
    }
    n++;e.setAttribute('data-jfid',String(n));
    var o={id:'F'+n,kind:e.tagName==='SELECT'?'select':(type==='checkbox'?'checkbox':(e.tagName==='TEXTAREA'?'textarea':'input')),type:type,label:label,required:req,section:sectionOf(e),hint:hintOf(e)};
    if(o.kind==='select'){o.options=Array.prototype.slice.call(e.options).slice(0,25).map(function(x){return txt(x.text);}).filter(function(x){return x;});o.filled=e.selectedIndex>0||(e.value&&e.selectedIndex>=0&&!/bitte|auswählen|--/i.test(txt(e.options[e.selectedIndex]&&e.options[e.selectedIndex].text)));}
    else if(o.kind==='checkbox')o.filled=!!e.checked;
    else o.filled=!!(e.value&&e.value.length);
    if(e.getAttribute('pattern'))o.pattern=e.getAttribute('pattern').slice(0,40);
    if(e.maxLength>0&&e.maxLength<500)o.max=e.maxLength;
    if(e.getAttribute('aria-invalid')==='true')o.invalid=true;
    if(secret)o.secret=1;
    var ph=txt(e.getAttribute('placeholder'));if(ph&&ph!==label)o.ph=ph.slice(0,50);
    fields.push(o);
  }
  var errs=[];document.querySelectorAll('[role=alert],.error,.fehler,.validation-summary-errors,.field-validation-error,.invalid-feedback,.alert-danger').forEach(function(x){if(vis(x)){var t=txt(it(x));if(t&&errs.indexOf(t)<0)errs.push(t.slice(0,200));}});
  var btns=[];document.querySelectorAll('button,input[type=submit],input[type=button],a.button,a.btn,[role=button]').forEach(function(b){if(!vis(b))return;var t=txt(it(b))||txt(b.value)||txt(b.getAttribute('aria-label'));if(t&&t.length<40&&btns.indexOf(t)<0)btns.push(t);});
  var body=txt(it(document.querySelector('main,[role=main],#content,form')||document.body));
  var step=(body.match(/schritt\s*\d+\s*(von|\/)\s*\d+/i)||[''])[0];
  return JSON.stringify({url:location.href,title:document.title,step:step,fields:fields,errors:errs.slice(0,8),buttons:btns.slice(0,12),intro:body.slice(0,600)});
})()
''';

/// Feld im Browser hervorheben (Rahmen + Sprechblase mit Erklärung), damit der Nutzer sieht, wo er tippen soll.
String browserMarkJs(int fid, String text) => '''
(function(){
  document.querySelectorAll('.junels-mark').forEach(function(x){x.remove();});
  document.querySelectorAll('[data-junels-outline]').forEach(function(x){x.style.outline=x.getAttribute('data-junels-outline');x.removeAttribute('data-junels-outline');});
  var e=document.querySelector('[data-jfid="$fid"]');
  if(!e)return JSON.stringify({ok:false,error:'Feld F$fid nicht mehr auf der Seite – Formular neu lesen (begleiten aktion formular)'});
  e.scrollIntoView({block:'center'});
  e.setAttribute('data-junels-outline',e.style.outline||'');
  e.style.outline='3px solid #8b5cf6';e.style.outlineOffset='2px';
  var t=${jsonEncode(text)};
  if(t){var b=document.createElement('div');b.className='junels-mark';b.textContent='💬 '+t;
    b.style.cssText='position:absolute;z-index:2147483647;max-width:320px;background:#8b5cf6;color:#fff;font:14px/1.4 system-ui,sans-serif;padding:8px 10px;border-radius:10px;box-shadow:0 4px 14px rgba(0,0,0,.25)';
    var r=e.getBoundingClientRect();b.style.left=Math.max(8,r.left+scrollX)+'px';b.style.top=(r.bottom+scrollY+8)+'px';document.body.appendChild(b);}
  try{e.focus({preventScroll:true});}catch(x){}
  return JSON.stringify({ok:true});
})()
''';

/// Formular-Daten (JSON aus [browserFormJs]) als Text für das Modell.
String formatForm(Map<String, dynamic> f) {
  final fields = ((f['fields'] as List?) ?? const []).cast<Map>();
  final b = StringBuffer('Formular: ${f['title'] ?? ''}${(f['step'] ?? '').toString().isNotEmpty ? ' – ${f['step']}' : ''}\n');
  var section = '';
  var openReq = 0, req = 0;
  for (final x in fields) {
    final sec = (x['section'] ?? '').toString();
    if (sec.isNotEmpty && sec != section) {
      section = sec;
      b.writeln('Abschnitt „$sec“');
    }
    final required = x['required'] == true;
    if (required) {
      req++;
      if (x['filled'] != true) openReq++;
    }
    final kind = switch (x['kind']) {
      'select' => 'Auswahl: ${((x['options'] as List?) ?? const []).take(10).join(' | ')}',
      'radio' => 'eins wählen: ${((x['options'] as List?) ?? const []).take(10).join(' | ')}',
      'checkbox' => 'Häkchen',
      'textarea' => 'Text, mehrzeilig',
      _ => switch (x['type']) { 'date' => 'Datum', 'email' => 'E-Mail', 'tel' => 'Telefon', 'number' => 'Zahl', _ => 'Text' },
    };
    b.write('  ${x['id']} ${x['label']}${required ? ' *' : ''} ($kind)');
    b.write(x['filled'] == true ? ' – ausgefüllt' : ' – leer');
    if (x['invalid'] == true) b.write(' – ⚠ FEHLER');
    if (x['secret'] == 1) b.write(' – 🔒 trägt der Nutzer selbst ein');
    if ((x['ph'] ?? '').toString().isNotEmpty) b.write(' – Beispiel: ${x['ph']}');
    if ((x['hint'] ?? '').toString().isNotEmpty) b.write(' – Hinweis: ${x['hint']}');
    if (x['max'] != null) b.write(' – max. ${x['max']} Zeichen');
    b.writeln();
  }
  if (fields.isEmpty) b.writeln('(keine Eingabefelder auf dieser Seite)');
  final errs = ((f['errors'] as List?) ?? const []);
  if (errs.isNotEmpty) b.writeln('Fehlermeldungen der Seite: ${errs.join(' · ')}');
  final btns = ((f['buttons'] as List?) ?? const []);
  if (btns.isNotEmpty) b.writeln('Knöpfe: ${btns.join(' · ')} (anklicken: browser read, dann click mit Nummer)');
  if (req > 0) b.writeln('Pflichtfelder: ${req - openReq} von $req ausgefüllt${openReq > 0 ? ' – $openReq offen' : ''}');
  return b.toString();
}

String _actJs(int id, String action, [String text = '', bool submit = false, String attr = 'data-jid']) => '''
(function(){
  var e=document.querySelector('[$attr="$id"]');
  if(!e)return JSON.stringify({ok:false,error:'Element $id nicht mehr auf der Seite – lies die Seite neu (action read bzw. Formular neu lesen)'});
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
  if(act==='select'&&e.type==='radio'){
    var rs=Array.prototype.slice.call(document.querySelectorAll('input[type=radio][name="'+e.name+'"]'));
    var lab=function(r){var l=r.id?document.querySelector('label[for="'+r.id+'"]'):null;return ((l?l.innerText:'')||(r.closest('label')?r.closest('label').innerText:'')||r.value||'').toLowerCase();};
    var hit=rs.find(function(r){return lab(r).indexOf(v.toLowerCase())>=0;});
    if(!hit)return JSON.stringify({ok:false,error:'Option nicht gefunden'});
    hit.click();return JSON.stringify({ok:true});
  }
  if(act==='check'){
    var want=!/^(nein|no|false|aus|0)\$/i.test(v.trim());if(e.checked!==want)e.click();return JSON.stringify({ok:true});
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

/// Zahlung: macht immer der Mensch – Junels klickt das nie, sondern übergibt.
final _paymentLabel = RegExp(
    r'bezahl|zahlungspflichtig|kostenpflichtig|zahlung (abschließen|bestätigen|ausführen)|jetzt kaufen|kaufen\b|zur kasse|kasse\b|'
    r'checkout|pay now|pay\b|place order|purchase|zahlungsart|kreditkarte|paypal|sofortüberweisung|eps-überweisung|apple pay|google pay',
    caseSensitive: false);

/// Anmelde-Seiten (ID Austria, Handy-Signatur, Passkey, Logins): der Nutzer meldet sich selbst an.
final _loginPage = RegExp(
    r'id-austria|idaustria|eid\.gv\.at|a-trust|handy-signatur|oauth|openid|/login|/signin|/sign-in|/anmeld|/auth|accounts\.|sso\.',
    caseSensitive: false);

/// Ist die Seite eine Anmeldeseite? (Adresse oder Passwortfeld)
bool looksLikeLogin(Map<String, dynamic> snap) {
  final url = (snap['url'] ?? '').toString();
  final text = (snap['text'] ?? '').toString();
  final head = text.length > 1500 ? text.substring(0, 1500) : text;
  final secret = ((snap['els'] as List?) ?? const []).any((e) => e is Map && e['secret'] == 1);
  return _loginPage.hasMatch(url) || secret || RegExp(r'mit id austria anmelden|passkey', caseSensitive: false).hasMatch(head);
}

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
      'Enter nur bei Suchfeldern), "select" (target = Nummer, text = Option), "check" (Häkchen, text = ja/nein), '
      '"scroll" (target = "down"/"up"), "back", "read", "form" (liest alle Formularfelder als F1, F2 … mit Beschriftung, '
      'Pflicht, Hinweis, ob ausgefüllt), "mark" (target = F-Nummer, text = kurze Erklärung: hebt das Feld für den Nutzer hervor). '
      'type/select/check gehen auch mit F-Nummern. Nach jeder Aktion bekommst du die Seite mit nummerierten Elementen [n]. '
      'Nie Passwörter, Ausweis-, Sozialversicherungs- oder Zahlungsdaten eingeben (🔒-Felder trägt der Nutzer ein).';
  @override
  bool get requiresNetwork => true;
  @override
  List<ToolParam> get params => const [
        ToolParam('action', ParamType.enumeration, 'Was tun',
            values: ['open', 'search', 'click', 'type', 'select', 'check', 'scroll', 'back', 'read', 'form', 'mark']),
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
        await d.settle();
        // Inhalte, die per JavaScript nachgeladen werden: kurz warten, bis Einträge da sind
        for (var i = 0; i < 3; i++) {
          final probe = await _read(d);
          if (((probe['cards'] as List?) ?? const []).length >= 3 || probe['captcha'] == true) break;
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
        // text = worum es geht (z. B. „News zu Anthropic“): passende Einträge zuerst
        final r = await _snapshot(d, focus: text.trim());
        if (text.trim().isNotEmpty && parseResultCards(r).isNotEmpty) ctx.answerNow = true;
        return r;
      case 'search':
        if (text.trim().isEmpty) throw ToolException('text (Suchbegriffe) fehlt');
        final r = await _search(d, target, text.trim());
        // Genug Treffer → direkt antworten statt weiterzuklicken
        if (parseResultCards(r).length >= 3) ctx.answerNow = true;
        return r;
      case 'click':
        final el = await _element(d, target);
        final label = (el['label'] ?? '').toString();
        if (_paymentLabel.hasMatch(label)) {
          // Bezahlen/Kaufen: immer der Mensch – Junels drückt diesen Knopf nie
          final ok = await d.handOver('💳 Zahlung machst du selbst: „$label“. Prüfe Betrag und Angaben, bezahle im Browser '
              'und tippe dann auf „Weiter“ (oder „Abbrechen“).');
          return _snapshot(d,
              note: ok
                  ? 'Der Nutzer hat die Zahlung („$label“) selbst übernommen. Prüfe die Seite (Bestätigung?) und sag, wie es weitergeht.'
                  : 'Der Nutzer hat die Zahlung abgebrochen. Frag, wie es weitergehen soll.');
        }
        if (_riskyLabel.hasMatch(label) &&
            !await d.confirm('Im Browser klicken?', '„$label“\nDer Agent möchte diesen Knopf drücken.')) {
          return 'Der Nutzer hat den Klick auf „$label“ abgelehnt. Frag, wie es weitergehen soll.';
        }
        await _act(d, _actJs(_num(el['id']), 'click', '', false, _attr(el)));
      case 'type' || 'fill':
        final el = await _element(d, target);
        if (el['secret'] == 1) {
          if (_attr(el) == 'data-jfid') await d.eval(browserMarkJs(_num(el['id']), 'Bitte hier selbst eintragen – Junels liest das nicht.'));
          await d.handOver('🔒 Gib „${el['label'] ?? 'dieses Feld'}“ selbst im Browser ein (Passwort, Ausweis-, SV- oder Zahlungsdaten) '
              'und tippe dann auf „Weiter“. Junels liest diese Felder nie – die KI sieht die Angabe nicht.');
          return _attr(el) == 'data-jfid' ? await _form(d, note: 'Der Nutzer hat ${el['id']} selbst ausgefüllt.') : _snapshot(d, note: 'Der Nutzer hat das Feld selbst ausgefüllt.');
        }
        // Enter nur bei Suchfeldern – in Formularen würde Enter vorzeitig absenden
        await _act(d, _actJs(_num(el['id']), 'type', text, el['search'] == 1, _attr(el)));
        if (_attr(el) == 'data-jfid') return _form(d, note: '${el['id']} eingetragen.');
      case 'select':
        final el = await _element(d, target);
        await _act(d, _actJs(_num(el['id']), 'select', text, false, _attr(el)));
        if (_attr(el) == 'data-jfid') return _form(d, note: '${el['id']}: „$text“ gewählt.');
      case 'check':
        final el = await _element(d, target);
        await _act(d, _actJs(_num(el['id']), 'check', text, false, _attr(el)));
        if (_attr(el) == 'data-jfid') return _form(d, note: '${el['id']}: Häkchen ${RegExp(r'^(nein|no|false|aus|0)$', caseSensitive: false).hasMatch(text.trim()) ? 'entfernt' : 'gesetzt'}.');
      case 'form' || 'formular':
        return _form(d);
      case 'mark' || 'zeigen':
        final el = await _element(d, target.toUpperCase().startsWith('F') ? target : 'F$target');
        await _act(d, browserMarkJs(_num(el['id']), text.trim()));
        ctx.answerNow = true;
        return '${el['id']} „${el['label']}“ ist im Browser hervorgehoben${text.trim().isEmpty ? '' : ' mit der Erklärung „${text.trim()}“'}. '
            'Sag dem Nutzer kurz, was er dort eintragen soll.';
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

  static int _num(Object? id) => id is int ? id : int.parse(id.toString().replaceAll(RegExp(r'[^0-9]'), ''));
  static String _attr(Map<String, dynamic> el) => el['id'] is String && (el['id'] as String).startsWith('F') ? 'data-jfid' : 'data-jid';

  List<Map<String, dynamic>> _lastFields = const [];

  /// Formular lesen (Felder F1 …), merken und als Text liefern
  Future<String> _form(BrowserDriver d, {String note = ''}) async {
    final f = _decode(await d.eval(browserFormJs));
    _lastFields = ((f['fields'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    lastForm = f;
    return '${note.isEmpty ? '' : '$note\n'}${formatForm(f)}';
  }

  /// Zuletzt gelesenes Formular (für Begleiten: Fortschritt, Prüfen vor dem Absenden)
  Map<String, dynamic>? lastForm;

  Future<Map<String, dynamic>> _element(BrowserDriver d, String target) async {
    if (RegExp(r'^\s*F\d+\s*$', caseSensitive: false).hasMatch(target)) {
      if (_lastFields.isEmpty) await _form(d);
      final fid = 'F${target.replaceAll(RegExp(r'[^0-9]'), '')}';
      final f = _lastFields.where((e) => e['id'] == fid).firstOrNull;
      if (f == null) throw ToolException('Feld $fid gibt es nicht – Formular neu lesen (action form)');
      return f;
    }
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

  Future<String> _snapshot(BrowserDriver d, {String note = '', String focus = ''}) async {
    var snap = await _read(d);
    if (snap['captcha'] == true) snap = await _captcha(d);
    return _format(snap, note: note, focus: focus);
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

  static String _format(Map<String, dynamic> snap, {String note = '', String focus = ''}) {
    final b = StringBuffer();
    if (note.isNotEmpty) b.writeln(note);
    b.writeln('Seite: ${snap['title'] ?? ''} (${snap['url'] ?? ''})');
    final cards = [
      for (final c in ((snap['cards'] as List?) ?? const []).cast<Map<String, dynamic>>())
        if (!isJunkLink((c['link'] ?? '').toString(), (c['title'] ?? '').toString()))
          PageItem((c['title'] ?? '').toString(), cleanLink((c['link'] ?? '').toString()), (c['image'] ?? '').toString(),
              summary: (c['price'] ?? '').toString().isNotEmpty ? 'Preis: ${c['price']}' : (c['desc'] ?? '').toString()),
    ];
    if (focus.isNotEmpty) {
      // Passende Einträge nach vorne, der Rest danach (fürs Karussell)
      final hit = relevantItems(cards, focus);
      if (hit.isNotEmpty) {
        cards
          ..removeWhere(hit.contains)
          ..insertAll(0, hit);
      }
    }
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
    if (looksLikeLogin(snap)) {
      b.writeln('ANMELDUNG: Das ist eine Anmeldeseite (z. B. ID Austria, Passkey, Passwort). Der Nutzer meldet sich selbst an – '
          'übergib an ihn (Werkzeug begleiten, aktion uebergabe – sonst bitte ihn, sich im Browser anzumelden) statt etwas einzutippen.');
    }
    final text = (snap['text'] ?? '').toString();
    final stems = focus.isEmpty ? const <String>[] : queryStems(focus);
    if (stems.isNotEmpty) {
      // Sätze der Seite, die zum Thema passen
      final hits = [
        for (final m in RegExp(r'[^.!?]{20,300}[.!?]?').allMatches(text))
          if (stems.any(m.group(0)!.toLowerCase().contains)) m.group(0)!.trim(),
      ];
      b.writeln(hits.isEmpty
          ? 'Zum Thema „$focus“ steht auf dieser Seite nichts im sichtbaren Teil (eventuell weiter unten – action scroll).'
          : 'Passende Stellen: ${hits.take(6).join(' … ')}');
    } else if (text.isNotEmpty) {
      b.writeln('Text: ${text.length > 600 ? '${text.substring(0, 600)}…' : text}');
    }
    b.writeln('Antworte, sobald du genug weißt; sonst nächste Aktion. Nenne Produkte mit Namen und Preis, '
        'aber schreib keine Adressen (URLs) in die Antwort – die Karten zeigen die Links. '
        'Bei Anmeldung und Zahlung: der Nutzer macht das selbst.');
    if (cards.length > 5) b..write(moreCardsMarker)..write(formatCardItems(cards.skip(5).take(35)));
    return b.toString().trim();
  }
}

/// Nur für Tests: Aktions-Skript erzeugen.
String debugActJs(int id, String action, [String text = '', bool submit = false]) => _actJs(id, action, text, submit);
