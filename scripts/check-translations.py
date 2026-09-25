#!/usr/bin/env python3
"""Lists texts of the code (L("…")) that Sources/WinEx/Localization/English.swift doesn't translate,
and translations whose text is gone from the code. Run after adding interface texts."""
import re, glob, os, sys
os.chdir(os.path.join(os.path.dirname(__file__), '..'))

def literals(src, start):
    # L("…" — the key literal, escapes and all (keys don't contain interpolations)
    out = []
    for m in re.finditer(r'\bL\("', src):
        i = m.end(); key = ''
        while src[i] != '"':
            key += src[i:i+2] if src[i] == '\\' else src[i]
            i += 2 if src[i] == '\\' else 1
        out.append(key)
    return out

used = set()
for f in glob.glob('Sources/WinEx/**/*.swift', recursive=True):
    if '/Debug/' in f or f.endswith('English.swift'): continue
    used.update(literals(open(f).read(), 0))
english = open('Sources/WinEx/Localization/English.swift').read()
translated = set(re.findall(r'^\s*"((?:[^"\\]|\\.)*)":', english, flags=re.M))
missing = sorted(used - translated)
unused = sorted(translated - used)
for k in missing: print('missing:', k)
for k in unused: print('unused: ', k)
print(f'{len(used)} texts, {len(missing)} missing, {len(unused)} unused')
sys.exit(1 if missing else 0)
