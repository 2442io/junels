// Excel-Datei (.xlsx) erzeugen und bestehende Mappen gezielt ändern – ohne Abhängigkeiten.
// Zahlen, Datum, Prozent und Euro werden als echte Werte gespeichert, Formeln als Formeln
// (deutsche Funktionsnamen wie SUMME werden übersetzt). Einfache Formeln rechnet Junels selbst vor,
// damit auch Programme ohne Neuberechnung (Vorschau, Numbers) gleich das Ergebnis zeigen.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'design.dart';
import 'docx_writer.dart' show xmlEscape;
import 'md_blocks.dart';
import 'office_read.dart';
import 'zip_writer.dart';

/// Ein Tabellenblatt: Name + Zeilen (erste Zeile = Kopfzeile).
class SheetSpec {
  SheetSpec(this.name, this.rows);
  String name;
  final List<List<String>> rows;
}

/// Markdown → Blätter: jede Tabelle wird ein Blatt, die Überschrift davor ihr Name.
/// Ohne Markdown-Tabelle: CSV/TSV/Semikolon-Zeilen.
List<SheetSpec> sheetsFromMarkdown(String md, {String fallbackName = 'Tabelle1'}) {
  final out = <SheetSpec>[];
  String? heading;
  for (final b in parseMarkdown(md)) {
    if (b is MdHeading) heading = plainInline(b.text);
    if (b is MdTable && b.rows.isNotEmpty) {
      out.add(SheetSpec(heading ?? (out.isEmpty ? fallbackName : 'Tabelle${out.length + 1}'), [
        for (final r in b.rows) [for (final c in r) _stripMd(c)]
      ]));
      heading = null;
    }
  }
  if (out.isNotEmpty) return _uniqueNames(out);
  final rows = csvRows(md);
  return rows.isEmpty ? [] : [SheetSpec(fallbackName, rows)];
}

String _stripMd(String c) {
  final t = c.trim();
  return t.startsWith('=') ? t : plainInline(t).replaceAll('<br>', '\n');
}

/// CSV/TSV/Semikolon-getrennte Zeilen (Anführungszeichen beachtet). Leer, wenn kein Trennzeichen.
List<List<String>> csvRows(String text) {
  final lines = text.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#')).toList();
  if (lines.isEmpty) return [];
  final sample = lines.take(5).join('\n');
  final sep = ['\t', ';', ',', '|'].firstWhere((s) => sample.contains(s), orElse: () => '');
  if (sep.isEmpty) return [];
  List<String> split(String l) {
    final cells = <String>[];
    final b = StringBuffer();
    var q = false;
    for (var i = 0; i < l.length; i++) {
      final ch = l[i];
      if (ch == '"') {
        if (q && i + 1 < l.length && l[i + 1] == '"') {
          b.write('"');
          i++;
        } else {
          q = !q;
        }
      } else if (ch == sep && !q) {
        cells.add(b.toString().trim());
        b.clear();
      } else {
        b.write(ch);
      }
    }
    cells.add(b.toString().trim());
    if (sep == '|') {
      if (cells.isNotEmpty && cells.first.isEmpty) cells.removeAt(0);
      if (cells.isNotEmpty && cells.last.isEmpty) cells.removeLast();
    }
    return cells;
  }

  return [for (final l in lines) split(l)];
}

List<SheetSpec> _uniqueNames(List<SheetSpec> sheets) {
  final used = <String>{};
  for (final s in sheets) {
    var n = sheetName(s.name);
    var base = n;
    for (var i = 2; used.contains(n.toLowerCase()); i++) {
      base = base.length > 27 ? base.substring(0, 27) : base;
      n = '$base ($i)';
    }
    used.add(n.toLowerCase());
    s.name = n;
  }
  return sheets;
}

/// Gültiger Blattname: max. 31 Zeichen, ohne : \ / ? * [ ]
String sheetName(String raw) {
  var n = raw.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (n.isEmpty) n = 'Tabelle';
  return n.length > 31 ? n.substring(0, 31).trim() : n;
}

// ---------------------------------------------------------------------------------------------
// Zellwerte

enum CellKind { text, number, integer, date, percent, currency, formula, bool }

class CellValue {
  const CellValue(this.kind, {this.text = '', this.number = 0, this.formula = ''});
  final CellKind kind;
  final String text;
  final double number;
  final String formula;
}

final _thousands = RegExp(r'^-?\d{1,3}(\.\d{3})+(,\d+)?$');
final _deDecimal = RegExp(r'^-?\d+,\d+$');
final _plain = RegExp(r'^-?\d+(\.\d+)?$');

/// Zahl aus deutscher oder englischer Schreibweise; null, wenn keine Zahl.
double? cellNumber(String s) {
  final t = s.replaceAll(RegExp(r'[\s  ]'), '');
  if (t.isEmpty) return null;
  // 1.500 = tausendfünfhundert (deutsche Schreibweise geht vor)
  if (_thousands.hasMatch(t)) return double.parse(t.replaceAll('.', '').replaceAll(',', '.'));
  if (_plain.hasMatch(t)) return double.parse(t);
  if (_deDecimal.hasMatch(t)) return double.parse(t.replaceAll(',', '.'));
  if (RegExp(r'^-?\d{1,3}(,\d{3})+(\.\d+)?$').hasMatch(t)) return double.parse(t.replaceAll(',', ''));
  return null;
}

/// Excel-Datum (Tage seit 30.12.1899)
double excelDate(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(1899, 12, 30)).inDays.toDouble();

CellValue parseCell(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return const CellValue(CellKind.text);
  if (s.startsWith("'")) return CellValue(CellKind.text, text: s.substring(1));
  if (s.startsWith('=') && s.length > 1) return CellValue(CellKind.formula, formula: excelFormula(s.substring(1)));
  // führende Null (Telefon, PLZ mit 0, Kontonummern) bleibt Text
  if (RegExp(r'^0\d').hasMatch(s) && !s.contains(',') && !s.contains('.')) return CellValue(CellKind.text, text: s);
  final lower = s.toLowerCase();
  if (lower == 'wahr' || lower == 'true') return const CellValue(CellKind.bool, number: 1);
  if (lower == 'falsch' || lower == 'false') return const CellValue(CellKind.bool, number: 0);
  final pct = RegExp(r'^(-?[\d.,\s]+)\s*%$').firstMatch(s);
  if (pct != null) {
    final n = cellNumber(pct.group(1)!);
    if (n != null) return CellValue(CellKind.percent, number: n / 100);
  }
  final cur = RegExp(r'^(?:€|EUR)\s*(-?[\d.,\s]+)$|^(-?[\d.,\s]+)\s*(?:€|EUR)$', caseSensitive: false).firstMatch(s);
  if (cur != null) {
    final n = cellNumber(cur.group(1) ?? cur.group(2)!);
    if (n != null) return CellValue(CellKind.currency, number: n);
  }
  final de = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(s);
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
  if (de != null || iso != null) {
    final y = int.parse(de?.group(3) ?? iso!.group(1)!), m = int.parse(de?.group(2) ?? iso!.group(2)!), d = int.parse(de?.group(1) ?? iso!.group(3)!);
    if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return CellValue(CellKind.date, number: excelDate(DateTime(y, m, d)));
  }
  final n = cellNumber(s);
  if (n != null) {
    final t = s.replaceAll(' ', '');
    final decimals = RegExp(r',\d').hasMatch(t) && !RegExp(r'^-?\d{1,3}(,\d{3})+$').hasMatch(t) || RegExp(r'\.\d').hasMatch(t) && !_thousands.hasMatch(t);
    return CellValue(decimals ? CellKind.number : CellKind.integer, number: n);
  }
  return CellValue(CellKind.text, text: s);
}


const _deFunctions = {
  'SUMME': 'SUM', 'MITTELWERT': 'AVERAGE', 'ANZAHL2': 'COUNTA', 'ANZAHL': 'COUNT', 'WENNFEHLER': 'IFERROR', 'WENN': 'IF',
  'RUNDEN': 'ROUND', 'ABRUNDEN': 'ROUNDDOWN', 'AUFRUNDEN': 'ROUNDUP', 'SVERWEIS': 'VLOOKUP', 'WVERWEIS': 'HLOOKUP',
  'XVERWEIS': 'XLOOKUP', 'ZÄHLENWENNS': 'COUNTIFS', 'ZÄHLENWENN': 'COUNTIF', 'SUMMEWENNS': 'SUMIFS', 'SUMMEWENN': 'SUMIF',
  'MITTELWERTWENN': 'AVERAGEIF', 'HEUTE': 'TODAY', 'JETZT': 'NOW', 'VERKETTEN': 'CONCATENATE', 'TEXTKETTE': 'CONCAT',
  'UND': 'AND', 'ODER': 'OR', 'NICHT': 'NOT', 'LÄNGE': 'LEN', 'LINKS': 'LEFT', 'RECHTS': 'RIGHT', 'TEIL': 'MID',
  'GLÄTTEN': 'TRIM', 'PRODUKT': 'PRODUCT', 'MONAT': 'MONTH', 'JAHR': 'YEAR', 'TAG': 'DAY', 'DATUM': 'DATE',
  'GANZZAHL': 'INT', 'REST': 'MOD', 'POTENZ': 'POWER', 'WURZEL': 'SQRT', 'INDEX': 'INDEX', 'VERGLEICH': 'MATCH',
  'GROSS': 'UPPER', 'KLEIN': 'LOWER', 'ERSETZEN': 'REPLACE', 'WECHSELN': 'SUBSTITUTE', 'ISTLEER': 'ISBLANK',
};

/// Formel ins Excel-Dateiformat: englische Funktionsnamen, Komma als Trenner, Punkt als Dezimalzeichen.
String excelFormula(String f) {
  final parts = f.split('"'); // ungerade Indizes = Text in Anführungszeichen
  for (var i = 0; i < parts.length; i += 2) {
    var p = parts[i];
    p = p.replaceAllMapped(RegExp(r'([A-Za-zÄÖÜäöü][A-Za-zÄÖÜäöü0-9.]*)\s*\('), (m) {
      final name = m.group(1)!.toUpperCase();
      return '${_deFunctions[name] ?? name}(';
    });
    if (f.contains(';')) {
      p = p.replaceAllMapped(RegExp(r'(\d),(\d)'), (m) => '${m.group(1)}.${m.group(2)}').replaceAll(';', ',');
    }
    parts[i] = p;
  }
  return parts.join('"');
}

// ---------------------------------------------------------------------------------------------
// Zellbezüge und Vorab-Berechnung

String colName(int c) {
  var n = c + 1, s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

int colIndex(String letters) {
  var n = 0;
  for (final ch in letters.toUpperCase().codeUnits) {
    n = n * 26 + (ch - 64);
  }
  return n - 1;
}

/// „B12“ → (Spalte 1, Zeile 11), 0-basiert
(int, int)? parseRef(String ref) {
  final m = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d+)$').firstMatch(ref.trim());
  if (m == null) return null;
  return (colIndex(m.group(1)!), int.parse(m.group(2)!) - 1);
}

/// Rechnet einfache Formeln (Grundrechenarten, SUM/AVERAGE/MIN/MAX/COUNT/ROUND/ABS/PRODUCT) –
/// null, wenn sie mehr braucht (dann rechnet Excel beim Öffnen).
class FormulaEval {
  FormulaEval(this.value);

  /// Zellwert (Zahl, Text oder null) nach (Spalte, Zeile)
  final Object? Function(int col, int row) value;

  late String _s;
  var _i = 0;

  double? eval(String formula) {
    if (formula.contains('!') || formula.contains('"')) return null;
    _s = formula.replaceAll(' ', '');
    _i = 0;
    try {
      final v = _expr();
      if (_i != _s.length || v is! double || v.isNaN || v.isInfinite) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  Object _expr() {
    var a = _term();
    while (_i < _s.length && (_s[_i] == '+' || _s[_i] == '-')) {
      final op = _s[_i++];
      final b = _term();
      a = op == '+' ? _num(a) + _num(b) : _num(a) - _num(b);
    }
    return a;
  }

  Object _term() {
    var a = _power();
    while (_i < _s.length && (_s[_i] == '*' || _s[_i] == '/')) {
      final op = _s[_i++];
      final b = _power();
      if (op == '/' && _num(b) == 0) throw const FormatException('div0');
      a = op == '*' ? _num(a) * _num(b) : _num(a) / _num(b);
    }
    return a;
  }

  Object _power() {
    var a = _factor();
    while (_i < _s.length && _s[_i] == '^') {
      _i++;
      a = math.pow(_num(a), _num(_factor())).toDouble();
    }
    return a;
  }

  double _num(Object v) {
    if (v is double) return v;
    if (v is List<double>) return v.isEmpty ? 0 : v.first;
    throw const FormatException('kein Wert');
  }

  Object _factor() {
    if (_s[_i] == '-') {
      _i++;
      return -_num(_factor());
    }
    if (_s[_i] == '+') {
      _i++;
      return _factor();
    }
    if (_s[_i] == '(') {
      _i++;
      final v = _expr();
      if (_s[_i++] != ')') throw const FormatException(')');
      return v;
    }
    final numM = RegExp(r'\d+(\.\d+)?(%)?').matchAsPrefix(_s, _i);
    if (numM != null) {
      _i = numM.end;
      final n = double.parse(numM.group(0)!.replaceAll('%', ''));
      return numM.group(2) != null ? n / 100 : n;
    }
    final fn = RegExp(r'([A-Z]+)\(').matchAsPrefix(_s, _i);
    if (fn != null) {
      _i = fn.end;
      final args = <Object>[];
      if (_s[_i] != ')') {
        args.add(_arg());
        while (_s[_i] == ',') {
          _i++;
          args.add(_arg());
        }
      }
      if (_s[_i++] != ')') throw const FormatException(')');
      final flat = [for (final a in args) ...(a is List<double> ? a : [_num(a)])];
      switch (fn.group(1)) {
        case 'SUM':
          return flat.fold<double>(0, (a, b) => a + b);
        case 'PRODUCT':
          return flat.fold<double>(1, (a, b) => a * b);
        case 'AVERAGE':
          if (flat.isEmpty) throw const FormatException('leer');
          return flat.fold<double>(0, (a, b) => a + b) / flat.length;
        case 'MIN':
          return flat.isEmpty ? 0.0 : flat.reduce(math.min);
        case 'MAX':
          return flat.isEmpty ? 0.0 : flat.reduce(math.max);
        case 'COUNT':
          return flat.length.toDouble();
        case 'ABS':
          return _num(args.first).abs();
        case 'ROUND':
          final d = args.length > 1 ? _num(args[1]).toInt() : 0;
          final f = math.pow(10, d);
          return (_num(args.first) * f).roundToDouble() / f;
        default:
          throw const FormatException('Funktion');
      }
    }
    final ref = RegExp(r'\$?([A-Z]{1,3})\$?(\d+)(?::\$?([A-Z]{1,3})\$?(\d+))?').matchAsPrefix(_s, _i);
    if (ref != null) {
      _i = ref.end;
      final c1 = colIndex(ref.group(1)!), r1 = int.parse(ref.group(2)!) - 1;
      if (ref.group(3) == null) {
        final v = value(c1, r1);
        if (v == null) return 0.0;
        if (v is num) return v.toDouble();
        throw const FormatException('Text');
      }
      final c2 = colIndex(ref.group(3)!), r2 = int.parse(ref.group(4)!) - 1;
      return <double>[
        for (var r = math.min(r1, r2); r <= math.max(r1, r2); r++)
          for (var c = math.min(c1, c2); c <= math.max(c1, c2); c++)
            if (value(c, r) case final num n) n.toDouble(),
      ];
    }
    throw const FormatException('unbekannt');
  }

  Object _arg() {
    final save = _i;
    final range = RegExp(r'\$?[A-Z]{1,3}\$?\d+:\$?[A-Z]{1,3}\$?\d+').matchAsPrefix(_s, _i);
    if (range != null && (range.end == _s.length || ',)'.contains(_s[range.end]))) return _factor();
    _i = save;
    return _expr();
  }
}

/// Werte aller Zellen eines Blatts vorab berechnen (mehrere Durchgänge für Abhängigkeiten).
Map<(int, int), double> precompute(Map<(int, int), Object> values, Map<(int, int), String> formulas) {
  final done = <(int, int), double>{};
  for (var pass = 0; pass < 6 && done.length < formulas.length; pass++) {
    var progress = false;
    for (final e in formulas.entries) {
      if (done.containsKey(e.key)) continue;
      var pending = false;
      final v = FormulaEval((c, r) {
        if (formulas.containsKey((c, r)) && !done.containsKey((c, r))) pending = true;
        return done[(c, r)] ?? values[(c, r)];
      }).eval(e.value);
      if (v != null && !pending) {
        done[e.key] = v;
        progress = true;
      }
    }
    if (!progress) break;
  }
  return done;
}

String _numText(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  return v.toString();
}

// ---------------------------------------------------------------------------------------------
// Neue Mappe

/// Stil-Index je Zellart (cellXfs in styles.xml unten)
int _styleOf(CellKind k) => switch (k) {
      CellKind.date => 2,
      CellKind.number => 3,
      CellKind.integer => 4,
      CellKind.percent => 5,
      CellKind.currency => 6,
      _ => 0,
    };

String _cellXml(String ref, CellValue v, {int? style, double? cached}) {
  final s = style ?? _styleOf(v.kind);
  final sa = s == 0 ? '' : ' s="$s"';
  return switch (v.kind) {
    CellKind.text => v.text.isEmpty ? '' : '<c r="$ref" t="inlineStr"$sa><is><t xml:space="preserve">${xmlEscape(v.text)}</t></is></c>',
    CellKind.bool => '<c r="$ref" t="b"$sa><v>${v.number.toInt()}</v></c>',
    CellKind.formula => '<c r="$ref"$sa><f>${xmlEscape(v.formula)}</f>${cached != null ? '<v>${_numText(cached)}</v>' : ''}</c>',
    _ => '<c r="$ref"$sa><v>${_numText(v.number)}</v></c>',
  };
}

String _sheetXml(SheetSpec sheet) {
  final rows = sheet.rows;
  final cols = rows.fold<int>(0, (a, r) => math.max(a, r.length));
  final parsed = [for (final r in rows) [for (final c in r) parseCell(c)]];
  final values = <(int, int), Object>{};
  final formulas = <(int, int), String>{};
  for (var r = 0; r < parsed.length; r++) {
    for (var c = 0; c < parsed[r].length; c++) {
      final v = parsed[r][c];
      if (v.kind == CellKind.formula) {
        formulas[(c, r)] = v.formula;
      } else if (v.kind == CellKind.text) {
        if (v.text.isNotEmpty) values[(c, r)] = v.text;
      } else {
        values[(c, r)] = v.number;
      }
    }
  }
  final cached = precompute(values, formulas);
  // Spaltenbreiten aus dem längsten Inhalt
  final widths = List<double>.filled(cols, 8);
  for (final r in rows) {
    for (var c = 0; c < r.length; c++) {
      final len = r[c].startsWith('=') ? 12 : r[c].split('\n').map((l) => l.length).fold<int>(0, math.max);
      widths[c] = math.max(widths[c], math.min(60, len * 1.15 + 2));
    }
  }
  // Format einer Formelspalte von den Werten darüber übernehmen (z. B. Summe von Euro-Beträgen)
  int formulaStyle(int c, int r) {
    for (var k = r - 1; k >= 1; k--) {
      if (c < parsed[k].length && parsed[k][c].kind != CellKind.formula && parsed[k][c].kind != CellKind.text) {
        return _styleOf(parsed[k][c].kind);
      }
    }
    return 3;
  }

  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<dimension ref="A1:${colName(math.max(cols, 1) - 1)}${math.max(rows.length, 1)}"/>');
  if (rows.length > 1) {
    b.write('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>');
  }
  b.write('<sheetFormatPr defaultRowHeight="15"/>');
  if (cols > 0) {
    b.write('<cols>${[for (var c = 0; c < cols; c++) '<col min="${c + 1}" max="${c + 1}" width="${widths[c].toStringAsFixed(1)}" customWidth="1"/>'].join()}</cols>');
  }
  b.write('<sheetData>');
  for (var r = 0; r < rows.length; r++) {
    b.write('<row r="${r + 1}">');
    for (var c = 0; c < parsed[r].length; c++) {
      final v = parsed[r][c];
      final ref = '${colName(c)}${r + 1}';
      if (r == 0 && rows.length > 1) {
        b.write(_cellXml(ref, v.kind == CellKind.formula ? v : CellValue(CellKind.text, text: rows[0][c].trim()), style: 1));
      } else {
        b.write(_cellXml(ref, v, style: v.kind == CellKind.formula ? formulaStyle(c, r) : null, cached: cached[(c, r)]));
      }
    }
    b.write('</row>');
  }
  b.write('</sheetData>');
  if (rows.length > 1 && cols > 0) b.write('<autoFilter ref="A1:${colName(cols - 1)}${rows.length}"/>');
  b.write('<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>'
      '<pageSetup paperSize="9" orientation="${cols > 6 ? 'landscape' : 'portrait'}"/></worksheet>');
  return b.toString();
}

String _xlsxStyles(SlideDesign d) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="3"><numFmt numFmtId="164" formatCode="DD.MM.YYYY"/><numFmt numFmtId="165" formatCode="0.0%"/>'
    '<numFmt numFmtId="166" formatCode="#,##0.00\\ &quot;€&quot;"/></numFmts>'
    '<fonts count="2"><font><sz val="11"/><name val="${xmlEscape(d.font)}"/></font>'
    '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="${xmlEscape(d.font)}"/></font></fonts>'
    '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FF${d.primary}"/><bgColor indexed="64"/></patternFill></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="7">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"><alignment vertical="center"/></xf>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '</cellXfs><cellStyles count="1"><cellStyle name="Standard" xfId="0" builtinId="0"/></cellStyles></styleSheet>';

/// Neue Excel-Mappe aus Blättern.
Uint8List buildXlsx(List<SheetSpec> sheets, {String title = '', SlideDesign? design}) {
  final d = design ?? designById('klar');
  final list = _uniqueNames(sheets.isEmpty ? [SheetSpec('Tabelle1', [])] : sheets);
  final zip = ZipWriter();
  final now = DateTime.now().toUtc().toIso8601String().split('.').first;
  zip
    ..addString('[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '${[for (var i = 0; i < list.length; i++) '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>')
    ..addString('_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>')
    ..addString('docProps/core.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${xmlEscape(title)}</dc:title><dc:creator>Junels (KI)</dc:creator><dc:description>Mit KI erzeugt (Junels) – bitte prüfen.</dc:description>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">${now}Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">${now}Z</dcterms:modified></cp:coreProperties>')
    ..addString('docProps/app.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Junels</Application></Properties>')
    ..addString('xl/workbook.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>'
        '${[for (var i = 0; i < list.length; i++) '<sheet name="${xmlEscape(list[i].name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
        '</sheets>'
        '<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>')
    ..addString('xl/_rels/workbook.xml.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var i = 0; i < list.length; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join()}'
        '<Relationship Id="rId${list.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>')
    ..addString('xl/styles.xml', _xlsxStyles(d));
  for (var i = 0; i < list.length; i++) {
    zip.addString('xl/worksheets/sheet${i + 1}.xml', _sheetXml(list[i]));
  }
  return zip.build();
}

// ---------------------------------------------------------------------------------------------
// Bestehende Mappe ändern (auch fremde Dateien: Formatierung bleibt, nur betroffene Zellen ändern sich)

class XlsxBook {
  XlsxBook._(this.files);

  /// Öffnet eine .xlsx-Datei.
  factory XlsxBook.open(Uint8List bytes) {
    final z = readZip(bytes);
    if (!z.containsKey('xl/workbook.xml')) throw const FormatException('Keine Excel-Datei');
    return XlsxBook._(z);
  }

  final Map<String, Uint8List> files;

  String _s(String p) => files[p] == null ? '' : utf8.decode(files[p]!, allowMalformed: true);
  void _put(String p, String xml) => files[p] = Uint8List.fromList(utf8.encode(xml));

  static String _unxml(String x) =>
      x.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');

  /// Blattnamen in Reihenfolge → Pfad
  List<(String, String)> get sheets {
    final wb = _s('xl/workbook.xml');
    final rels = _s('xl/_rels/workbook.xml.rels');
    final out = <(String, String)>[];
    for (final m in RegExp(r'<sheet\b[^>]*>').allMatches(wb)) {
      final tag = m.group(0)!;
      final name = _unxml(RegExp(r'name="([^"]*)"').firstMatch(tag)?.group(1) ?? '');
      final rid = RegExp(r'r:id="([^"]*)"').firstMatch(tag)?.group(1);
      final target = RegExp('<Relationship\\b[^>]*Id="$rid"[^>]*>').firstMatch(rels)?.group(0);
      var path = RegExp(r'Target="([^"]*)"').firstMatch(target ?? '')?.group(1) ?? '';
      path = path.startsWith('/') ? path.substring(1) : 'xl/$path';
      out.add((name, path));
    }
    return out;
  }

  /// Blatt nach Name (ohne Groß/Klein) oder Nummer (1-basiert); leer = erstes
  (String, String) sheet(String which) {
    final list = sheets;
    if (list.isEmpty) throw const FormatException('Mappe ohne Blätter');
    final w = which.trim();
    if (w.isEmpty) return list.first;
    final n = int.tryParse(w);
    if (n != null && n >= 1 && n <= list.length) return list[n - 1];
    return list.where((s) => s.$1.toLowerCase() == w.toLowerCase()).firstOrNull ??
        list.where((s) => s.$1.toLowerCase().contains(w.toLowerCase())).firstOrNull ??
        (throw FormatException('Blatt „$w“ gibt es nicht. Blätter: ${list.map((s) => s.$1).join(', ')}'));
  }

  List<String>? _shared;
  List<String> get shared => _shared ??= [
        for (final si in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(_s('xl/sharedStrings.xml')))
          _unxml(RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(si.group(1)!).map((m) => m.group(1)!).join()),
      ];

  /// Zellwerte eines Blatts: (Spalte, Zeile) → Zahl oder Text; formeln: Formeltext
  (Map<(int, int), Object>, Map<(int, int), String>) cells(String path) {
    final xml = _s(path);
    final values = <(int, int), Object>{};
    final formulas = <(int, int), String>{};
    for (final m in RegExp(r'<c\b([^>]*?)(?:/>|>(.*?)</c>)', dotAll: true).allMatches(xml)) {
      final attrs = m.group(1)!;
      final inner = m.group(2) ?? '';
      final ref = parseRef(RegExp(r'\br="([^"]+)"').firstMatch(attrs)?.group(1) ?? '');
      if (ref == null) continue;
      final t = RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?.group(1);
      final f = RegExp(r'<f[^>]*>(.*?)</f>', dotAll: true).firstMatch(inner)?.group(1);
      if (f != null) formulas[ref] = _unxml(f);
      final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(inner)?.group(1);
      if (t == 's' && v != null) {
        final i = int.tryParse(v);
        if (i != null && i < shared.length) values[ref] = shared[i];
      } else if (t == 'inlineStr') {
        values[ref] = _unxml(RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(inner).map((x) => x.group(1)!).join());
      } else if (t == 'str' || t == 'e') {
        if (v != null) values[ref] = _unxml(v);
      } else if (v != null) {
        final n = double.tryParse(v);
        if (n != null) values[ref] = n;
      }
    }
    return (values, formulas);
  }

  /// Blatt als Markdown-Tabelle mit Spaltenbuchstaben und Zeilennummern (für das Modell)
  String preview(String which, {int maxRows = 60, int maxCols = 15}) {
    final (name, path) = sheet(which);
    final (values, formulas) = cells(path);
    if (values.isEmpty && formulas.isEmpty) return 'Blatt „$name“ ist leer.';
    final keys = {...values.keys, ...formulas.keys};
    final maxR = keys.map((k) => k.$2).reduce(math.max), maxC = keys.map((k) => k.$1).reduce(math.max);
    final rows = math.min(maxR + 1, maxRows), cols = math.min(maxC + 1, maxCols);
    String fmt(Object? v) => v is double ? _numText(v) : (v?.toString() ?? '');
    final b = StringBuffer('Blatt „$name“ (${maxR + 1} Zeilen × ${maxC + 1} Spalten)\n\n| | ${[for (var c = 0; c < cols; c++) colName(c)].join(' | ')} |\n'
        '|---|${'---|' * cols}\n');
    for (var r = 0; r < rows; r++) {
      b.write('| ${r + 1} | ${[
        for (var c = 0; c < cols; c++) formulas[(c, r)] != null ? '=${formulas[(c, r)]}' : fmt(values[(c, r)]).replaceAll('|', '/').replaceAll('\n', ' ')
      ].join(' | ')} |\n');
    }
    if (maxR + 1 > rows) b.write('… ${maxR + 1 - rows} weitere Zeilen\n');
    return b.toString();
  }

  int? _dateXf, _pctXf, _numXf, _curXf;

  /// Stil mit Zahlenformat anhängen (fremde Mappen haben eigene Stile) → Index
  int _ensureXf(int numFmtId, {String? code}) {
    var st = _s('xl/styles.xml');
    if (st.isEmpty) return 0;
    if (code != null) {
      if (!st.contains('<numFmts')) {
        st = st.replaceFirst(RegExp(r'(<styleSheet\b[^>]*>)'), r'$1<numFmts count="0"></numFmts>');
      }
      if (!st.contains('numFmtId="$numFmtId"')) {
        st = st.replaceFirstMapped(RegExp(r'<numFmts count="(\d+)"\s*(/>|>)'), (m) {
          final n = int.parse(m.group(1)!) + 1;
          final open = '<numFmts count="$n">';
          final add = '<numFmt numFmtId="$numFmtId" formatCode="${xmlEscape(code)}"/>';
          return m.group(2) == '/>' ? '$open$add</numFmts>' : '$open$add';
        });
      }
    }
    final m = RegExp(r'<cellXfs count="(\d+)"\s*>').firstMatch(st);
    if (m == null) return 0;
    final n = int.parse(m.group(1)!);
    st = st.replaceFirst(m.group(0)!, '<cellXfs count="${n + 1}">');
    st = st.replaceFirst('</cellXfs>', '<xf numFmtId="$numFmtId" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>');
    _put('xl/styles.xml', st);
    return n;
  }

  int? _styleFor(CellKind k) => switch (k) {
        CellKind.date => _dateXf ??= _ensureXf(170, code: 'DD.MM.YYYY'),
        CellKind.percent => _pctXf ??= _ensureXf(10),
        CellKind.number => _numXf ??= _ensureXf(4),
        CellKind.currency => _curXf ??= _ensureXf(171, code: '#,##0.00\\ "€"'),
        _ => null,
      };

  /// Zellen setzen: {„B3“: „42“, „C3“: „=SUMME(B1:B3)“}. Leerer Wert löscht die Zelle.
  void setCells(String which, Map<String, String> updates) {
    final (_, path) = sheet(which);
    var xml = _s(path);
    if (!xml.contains('<sheetData')) throw const FormatException('Blatt ohne Daten');
    xml = xml.replaceFirst('<sheetData/>', '<sheetData></sheetData>');
    final parsed = <(int, int), CellValue>{};
    for (final e in updates.entries) {
      final ref = parseRef(e.key);
      if (ref == null) throw FormatException('Zelle „${e.key}“ ist ungültig (Beispiel: B3)');
      parsed[ref] = parseCell(e.value);
    }
    // Vorab-Werte für Formeln
    final (values, formulas) = cells(path);
    for (final e in parsed.entries) {
      values.remove(e.key);
      formulas.remove(e.key);
      if (e.value.kind == CellKind.formula) {
        formulas[e.key] = e.value.formula;
      } else if (e.value.kind == CellKind.text) {
        if (e.value.text.isNotEmpty) values[e.key] = e.value.text;
      } else {
        values[e.key] = e.value.number;
      }
    }
    final cached = precompute(values, formulas);
    for (final e in parsed.entries) {
      final (c, r) = e.key;
      final ref = '${colName(c)}${r + 1}';
      // Stil der alten Zelle behalten, sonst Zahlenformat setzen
      final old = RegExp('<c r="$ref"(?=[\\s>/])[^>]*?(?:/>|>.*?</c>)', dotAll: true).firstMatch(xml);
      final oldStyle = old == null ? null : int.tryParse(RegExp(r'\bs="(\d+)"').firstMatch(old.group(0)!)?.group(1) ?? '');
      final style = (oldStyle != null && oldStyle != 0) ? oldStyle : (_styleFor(e.value.kind) ?? 0);
      final cell = _cellXml(ref, e.value, style: style, cached: cached[e.key]);
      if (old != null) {
        xml = xml.replaceRange(old.start, old.end, cell);
        continue;
      }
      if (cell.isEmpty) continue;
      final row = RegExp('<row r="${r + 1}"(?=[\\s>/])[^>]*?(/>|>(.*?)</row>)', dotAll: true).firstMatch(xml);
      if (row != null) {
        final tag = row.group(0)!;
        if (row.group(1) == '/>') {
          xml = xml.replaceRange(row.start, row.end, '${tag.substring(0, tag.length - 2)}>$cell</row>');
        } else {
          // nach Spalte einsortieren
          final inner = row.group(2)!;
          final cellsIn = RegExp(r'<c r="([A-Z]+)\d+"[^>]*?(?:/>|>.*?</c>)', dotAll: true).allMatches(inner).toList();
          var insertAt = inner.length;
          for (final cm in cellsIn) {
            if (colIndex(cm.group(1)!) > c) {
              insertAt = cm.start;
              break;
            }
          }
          final newInner = inner.replaceRange(insertAt, insertAt, cell);
          final innerStart = row.start + tag.indexOf('>') + 1;
          xml = xml.replaceRange(innerStart, innerStart + inner.length, newInner);
        }
      } else {
        // neue Zeile einsortieren
        final rowsIn = RegExp(r'<row r="(\d+)"').allMatches(xml).toList();
        final next = rowsIn.where((m) => int.parse(m.group(1)!) > r + 1).firstOrNull;
        final at = next?.start ?? xml.indexOf('</sheetData>');
        xml = xml.replaceRange(at, at, '<row r="${r + 1}">$cell</row>');
      }
    }
    xml = _fixDimension(xml);
    _put(path, xml);
    _refreshCached(path);
    _recalcOnOpen();
  }

  /// Ergebnisse ALLER Formeln im Blatt neu vorrechnen (sonst zeigen Vorschau-Programme alte Summen);
  /// was Junels nicht rechnen kann, verliert seinen alten Wert und wird beim Öffnen berechnet.
  void _refreshCached(String path) {
    final (values, formulas) = cells(path);
    if (formulas.isEmpty) return;
    for (final k in formulas.keys) {
      values.remove(k);
    }
    final cached = precompute(values, formulas);
    var xml = _s(path);
    xml = xml.replaceAllMapped(RegExp(r'<c r="([A-Z]+)(\d+)"([^>]*)>(<f[^>]*>.*?</f>|<f[^>]*/>)(<v>.*?</v>)?</c>', dotAll: true), (m) {
      final key = (colIndex(m.group(1)!), int.parse(m.group(2)!) - 1);
      final v = cached[key];
      final attrs = m.group(3)!.replaceAll(RegExp(r'\s+t="(str|e|n)"'), '');
      return '<c r="${m.group(1)}${m.group(2)}"$attrs>${m.group(4)}${v == null ? '' : '<v>${_numText(v)}</v>'}</c>';
    });
    _put(path, xml);
  }

  /// Zeilen unten anfügen
  int appendRows(String which, List<List<String>> rows) {
    final (_, path) = sheet(which);
    final (values, formulas) = cells(path);
    final keys = {...values.keys, ...formulas.keys};
    final start = keys.isEmpty ? 0 : keys.map((k) => k.$2).reduce(math.max) + 1;
    final updates = <String, String>{};
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        if (rows[r][c].trim().isNotEmpty) updates['${colName(c)}${start + r + 1}'] = rows[r][c];
      }
    }
    if (updates.isNotEmpty) setCells(which, updates);
    return start + 1;
  }

  /// Blatt-Inhalt komplett ersetzen (Spaltenbreiten und Blatt-Einstellungen bleiben)
  void replaceSheet(String which, List<List<String>> rows) {
    final (_, path) = sheet(which);
    final xml = _s(path).replaceFirst(RegExp(r'<sheetData\b[^>]*?(/>|>.*?</sheetData>)', dotAll: true), '<sheetData></sheetData>');
    _put(path, xml.replaceFirst(RegExp(r'<autoFilter\b[^>]*?(/>|>.*?</autoFilter>)', dotAll: true), ''));
    final updates = <String, String>{};
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        if (rows[r][c].trim().isNotEmpty) updates['${colName(c)}${r + 1}'] = rows[r][c];
      }
    }
    if (updates.isNotEmpty) setCells(which, updates);
  }

  /// Neues Blatt am Ende
  String addSheet(String name, List<List<String>> rows) {
    final existing = sheets.map((s) => s.$1.toLowerCase()).toSet();
    var n = sheetName(name);
    for (var i = 2; existing.contains(n.toLowerCase()); i++) {
      n = sheetName('$name ($i)');
    }
    var idx = 1;
    while (files.containsKey('xl/worksheets/sheet$idx.xml')) {
      idx++;
    }
    final path = 'xl/worksheets/sheet$idx.xml';
    _put(path, _sheetXml(SheetSpec(n, rows)).replaceAll(RegExp(r' s="\d+"'), ''));
    var rels = _s('xl/_rels/workbook.xml.rels');
    var rid = 1;
    while (rels.contains('Id="rId$rid"')) {
      rid++;
    }
    rels = rels.replaceFirst('</Relationships>',
        '<Relationship Id="rId$rid" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$idx.xml"/></Relationships>');
    _put('xl/_rels/workbook.xml.rels', rels);
    var wb = _s('xl/workbook.xml');
    final ids = RegExp(r'sheetId="(\d+)"').allMatches(wb).map((m) => int.parse(m.group(1)!));
    final sid = (ids.isEmpty ? 0 : ids.reduce(math.max)) + 1;
    wb = wb.replaceFirst('</sheets>', '<sheet name="${xmlEscape(n)}" sheetId="$sid" r:id="rId$rid"/></sheets>');
    if (!wb.contains('xmlns:r=')) {
      wb = wb.replaceFirst('<workbook ', '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ');
    }
    _put('xl/workbook.xml', wb);
    var ct = _s('[Content_Types].xml');
    ct = ct.replaceFirst('</Types>',
        '<Override PartName="/$path" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>');
    _put('[Content_Types].xml', ct);
    // Kopfzeile fett, wenn die Mappe unsere Stile nicht kennt: Werte reichen
    _recalcOnOpen();
    return n;
  }

  String _fixDimension(String xml) {
    final refs = RegExp(r'<c r="([A-Z]+)(\d+)"').allMatches(xml).toList();
    if (refs.isEmpty) return xml;
    final maxC = refs.map((m) => colIndex(m.group(1)!)).reduce(math.max);
    final maxR = refs.map((m) => int.parse(m.group(2)!)).reduce(math.max);
    return xml.replaceFirst(RegExp(r'<dimension ref="[^"]*"/>'), '<dimension ref="A1:${colName(maxC)}$maxR"/>');
  }

  /// Excel soll beim Öffnen neu rechnen; veraltete Rechenkette entfernen (sonst „Reparatur“-Meldung)
  void _recalcOnOpen() {
    if (files.remove('xl/calcChain.xml') != null) {
      _put('[Content_Types].xml', _s('[Content_Types].xml').replaceAll(RegExp(r'<Override PartName="/xl/calcChain.xml"[^>]*/>'), ''));
      _put('xl/_rels/workbook.xml.rels', _s('xl/_rels/workbook.xml.rels').replaceAll(RegExp(r'<Relationship [^>]*Target="calcChain.xml"[^>]*/>'), ''));
    }
    var wb = _s('xl/workbook.xml');
    if (wb.contains('<calcPr')) {
      if (!wb.contains('fullCalcOnLoad')) wb = wb.replaceFirst('<calcPr', '<calcPr fullCalcOnLoad="1"');
    } else {
      wb = wb.replaceFirst('</workbook>', '<calcPr fullCalcOnLoad="1"/></workbook>');
    }
    _put('xl/workbook.xml', wb);
  }

  Uint8List save() {
    final z = ZipWriter();
    // [Content_Types].xml zuerst
    final keys = files.keys.toList()..sort((a, b) => a == '[Content_Types].xml' ? -1 : (b == '[Content_Types].xml' ? 1 : 0));
    for (final k in keys) {
      z.add(k, files[k]!);
    }
    return z.build();
  }
}
