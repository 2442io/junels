"""Wickelt übersetzte Texte in tr('…') und repariert danach const-Fehler (per dart analyze)."""
import json, re, subprocess, sys, os

APP = '/home/claude/junels/app'
LIB = APP + '/lib'
DART = '/home/claude/testkit/dartsdk/bin/dart'
keys = set(json.load(open('/home/claude/i18n/keys.json')))
files = sys.argv[1:]

LIT = re.compile(r"'((?:[^'\\\n]|\\.)*)'")


def wrap_file(path):
    s = open(path).read()
    out = []
    i = 0
    n = 0
    # Zeilen mit import/part/RegExp überspringen wir über Kontextprüfung
    while True:
        m = LIT.search(s, i)
        if not m:
            out.append(s[i:])
            break
        # Gruppe benachbarter Literale (implizite Verkettung) einsammeln
        group = [m]
        j = m.end()
        while True:
            ws = re.match(r'\s*', s[j:]).end()
            m2 = LIT.match(s, j + ws)
            if m2 and not s[j:j + ws].strip():
                group.append(m2)
                j = m2.end()
            else:
                break
        start, end = group[0].start(), group[-1].end()
        pre = s[max(0, start - 40):start]
        post = s[end:end + 6]
        line_start = s.rfind('\n', 0, start) + 1
        line = s[line_start:start]
        skip = (
            re.search(r'(import|part|export)\s*$', pre) or line.lstrip().startswith(('import', 'export', 'part'))
            or re.search(r'(RegExp\(|case\s|==\s*|!=\s*|\.contains\(|startsWith\(|endsWith\(|tr\(|Key\(|ValueKey\(|r)$', pre)
            or re.match(r'\s*(=>|:(?!\s*\'))', post) and not re.search(r'[?]\s*$', pre)
            or line.lstrip().startswith('//')
        )
        hits = [g for g in group if g.group(1) in keys]
        if skip or not hits:
            out.append(s[i:end])
            i = end
            continue
        out.append(s[i:start])
        parts = [f"tr('{g.group(1)}')" if g.group(1) in keys else f"'{g.group(1)}'" for g in group]
        out.append(parts[0] if len(parts) == 1 else '(' + ' + '.join(parts) + ')')
        n += len(hits)
        i = end
    s = ''.join(out)
    if n and "l10n.dart'" not in s:
        rel = os.path.relpath(LIB + '/l10n.dart', os.path.dirname(path))
        # nach dem letzten import einfügen
        k = [mm.end() for mm in re.finditer(r"^import [^\n]+;\n", s, re.M)]
        pos = k[-1] if k else 0
        s = s[:pos] + f"import '{rel}';\n" + s[pos:]
    open(path, 'w').write(s)
    return n


def matching(s, k):
    """Index nach dem Ausdruck, der bei k beginnt (Klammern ausbalanciert)."""
    depth = 0
    i = k
    in_str = None
    while i < len(s):
        c = s[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in "'\"":
            in_str = c
        elif c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return i + 1
            if depth < 0:
                return i
        elif c in ',;' and depth == 0:
            return i
        i += 1
    return i


def fix_round():
    r = subprocess.run([DART, 'analyze', '--format=machine', 'lib'], cwd=APP, capture_output=True, text=True)
    errs = []
    for l in (r.stdout + r.stderr).splitlines():
        p = l.split('|')
        if len(p) < 8 or p[0] != 'ERROR':
            continue
        code, f, line, col = p[2], p[3], int(p[4]), int(p[5])
        if 'voice_service' in f:
            continue
        errs.append((code, f, line, col, p[7]))
    fixed = 0
    by_file = {}
    for e in errs:
        by_file.setdefault(e[1], []).append(e)
    other = []
    for f, es in by_file.items():
        s = open(f).read()
        lines = s.split('\n')
        offs = [0]
        for L in lines:
            offs.append(offs[-1] + len(L) + 1)
        # von hinten, damit Positionen stimmen
        for code, _, line, col, msg in sorted(es, key=lambda e: (e[2], e[3]), reverse=True):
            pos = offs[line - 1] + col - 1
            c = code.lower()
            if c in ('non_constant_default_value', 'non_constant_case_expression', 'non_constant_map_key',
                     'const_eval_type_bool_num_string', 'invalid_annotation_constant_value_from_deferred_library',
                     'non_constant_annotation_constructor', 'enum_constant_with_non_const_constructor',
                     'const_constructor_param_type_mismatch') or 'enum' in msg.lower():
                # tr(...) an dieser Stelle zurücknehmen
                m = re.compile(r"tr\(('(?:[^'\\]|\\.)*')\)").search(s, max(0, pos - 2))
                if m and m.start() <= pos + 5:
                    s = s[:m.start()] + m.group(1) + s[m.end():]
                    fixed += 1
                continue
            if 'const' not in c and 'constant' not in c:
                other.append((code, f, line, col, msg))
                continue
            # umschließendes const suchen
            best = None
            for mm in re.finditer(r'\bconst\b', s[:pos + 1]):
                k = mm.start()
                after = mm.end()
                ws = re.match(r'\s*', s[after:]).end()
                e_end = matching(s, after + ws) if s[after + ws:after + ws + 1] not in '' else after
                # Deklaration (const x = …;  static const List<X> y = …)
                decl = re.match(r'\s*(?:[A-Za-z_<>, ?]+\s+)?[A-Za-z_]\w*\s*=', s[after:])
                if decl:
                    semi = s.find(';', after)
                    if k < pos <= semi:
                        best = (k, 'decl')
                    continue
                if k <= pos < e_end:
                    best = (k, 'expr')
            if best is None:
                other.append((code, f, line, col, msg))
                continue
            k, kind = best
            if kind == 'decl':
                s = s[:k] + 'final' + s[k + 5:]
            else:
                s = s[:k] + s[k + 5:].lstrip(' ')
            fixed += 1
        open(f, 'w').write(s)
    return fixed, other


if __name__ == '__main__':
    total = 0
    for f in files:
        total += wrap_file(f)
    print('eingewickelt', total)
    for rnd in range(15):
        fixed, other = fix_round()
        print('Runde', rnd, 'behoben', fixed, 'übrig', len(other))
        if not fixed:
            for o in other[:30]:
                print(o)
            break
