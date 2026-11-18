// Erzeugt eine GBNF-Grammatik aus den aktiven Tools. Damit kann auch ein
// 1B–3B-Modell nur gültiges JSON mit existierenden Tool-Namen und
// passenden Argumenten erzeugen.

import 'tool.dart';

class AgentGrammar {
  /// Grammatik für einen Agenten-Schritt: entweder Tool-Aufruf oder Endantwort.
  /// [allowTools] = false erzwingt eine Endantwort (z. B. nach dem Schrittlimit).
  static String build(List<AgentTool> tools, {bool allowTools = true}) {
    final b = StringBuffer();
    final useTools = allowTools && tools.isNotEmpty;
    b.writeln(r'root ::= "{" ws "\"thought\":" ws str "," ws step ws "}"');
    b.writeln(useTools ? 'step ::= final | call' : 'step ::= final');
    b.writeln(r'final ::= "\"final_answer\":" ws str');
    if (useTools) {
      final names = [for (final t in tools) 'tool-${_rule(t.name)}'];
      b.writeln('call ::= "\\"action\\":" ws ( ${names.join(' | ')} )');
      for (final t in tools) {
        b.writeln('tool-${_rule(t.name)} ::= ${_lit('"${t.name}"')} "," ws "\\"args\\":" ws ${_args(t)}');
      }
    }
    // Strings ohne Steuerzeichen; Escapes erlaubt
    b.writeln(r'str ::= "\"" chr* "\""');
    b.writeln(r'chr ::= [^"\\\x7F\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] )');
    b.writeln(r'int ::= "-"? [0-9] [0-9]{0,11}');
    b.writeln(r'num ::= "-"? [0-9] [0-9]{0,15} ( "." [0-9] [0-9]{0,9} )?');
    b.writeln(r'bool ::= "true" | "false"');
    // begrenzter Whitespace verhindert Endlosschleifen aus Leerzeichen
    b.writeln(r'ws ::= ( " " | "\n" )?');
    return b.toString();
  }

  static String _args(AgentTool t) {
    if (t.params.isEmpty) return r'"{" ws "}"';
    final parts = <String>[];
    for (var i = 0; i < t.params.length; i++) {
      final p = t.params[i];
      final value = switch (p.type) {
        ParamType.string => 'str',
        ParamType.integer => 'int',
        ParamType.number => 'num',
        ParamType.boolean => 'bool',
        ParamType.enumeration => '( ${p.values.map((v) => _lit('"$v"')).join(' | ')} )',
      };
      parts.add('${i > 0 ? '"," ws ' : ''}${_lit('"${p.name}"')} ":" ws $value');
    }
    return '"{" ws ${parts.join(' ')} ws "}"';
  }

  static String _rule(String name) => name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '-');

  /// GBNF-Literal für einen festen Text (Anführungszeichen und Backslashes escapen).
  static String _lit(String text) =>
      '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// Liest ein (eventuell unvollständiges) JSON-String-Feld aus gestreamtem Text.
/// Gibt null zurück, solange der Schlüssel noch nicht erschienen ist.
String? extractPartialJsonString(String raw, String key) {
  final m = RegExp('"${RegExp.escape(key)}"\\s*:\\s*"').firstMatch(raw);
  if (m == null) return null;
  final out = StringBuffer();
  var i = m.end;
  while (i < raw.length) {
    final c = raw[i];
    if (c == '"') break;
    if (c == r'\') {
      if (i + 1 >= raw.length) break;
      final n = raw[i + 1];
      switch (n) {
        case 'n':
          out.write('\n');
        case 't':
          out.write('\t');
        case 'r':
          out.write('\r');
        case 'b':
          out.write('\b');
        case 'f':
          out.write('\f');
        case 'u':
          if (i + 6 > raw.length) return out.toString();
          final code = int.tryParse(raw.substring(i + 2, i + 6), radix: 16);
          if (code != null) out.writeCharCode(code);
          i += 6;
          continue;
        default:
          out.write(n);
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
