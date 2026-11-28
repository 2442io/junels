# baut lib/l10n_en.dart aus core.json + *_en.txt
import json,sys,glob
app='/home/claude/junels/app/lib'
de=[]; en={}; seenraw=set()
for name in ['core']+[p.split('/')[-1][:-5] for p in sorted(glob.glob('/home/claude/i18n/*.json')) if not p.endswith('core.json')]:
    src=json.load(open(f'/home/claude/i18n/{name}.json'))
    try: lines=open(f'/home/claude/i18n/{name}_en.txt').read().splitlines()
    except FileNotFoundError: continue
    for l in lines:
        if '|' not in l: continue
        i,t=l.split('|',1); i=int(i)
        if i<len(src) and t.strip(): en[src[i]]=t; seenraw.add(src[i])
for l in open('/home/claude/i18n/extra_en.tsv').read().splitlines():
    if '\t' in l:
        a,b=l.split('\t',1); en[a]=b
def esc_en(t):
    # Englisch: \n bleibt Escape, Rest escapen
    t=t.replace('\\n','\x00')
    t=t.replace('\\','\\\\').replace("'","\\'").replace('$','\\$')
    return t.replace('\x00','\\n')
out=['// Englische Texte der Oberfläche (Schlüssel = deutscher Text wie im Quelltext). Erzeugt von scripts/i18n.','// ignore_for_file: lines_longer_than_80_chars','','const enStrings = <String, String>{']
for k,v in en.items():
    kk=k if k in seenraw else k.replace('\\','\\\\').replace("'","\\'").replace('$','\\$')
    out.append(f"  '{kk}': '{esc_en(v)}',")
out.append('};')
open(f'{app}/l10n_en.dart','w').write('\n'.join(out)+'\n')
json.dump(list(en.keys()),open('/home/claude/i18n/keys.json','w'),ensure_ascii=False)
print(len(en))
