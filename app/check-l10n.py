#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
"""Checks the menu bar app's translations: every L("…") key has a Russian string, nothing is unused or malformed."""
import re, sys, os
from pathlib import Path

root = os.path.dirname(os.path.abspath(__file__))
src = "\n".join(path.read_text(encoding="utf-8") for path in Path(root).rglob("*.swift"))
strings = open(os.path.join(root, "Netleash/Resources/ru.lproj/Localizable.strings"), encoding="utf-8").read()

def unesc(t): return t.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')
keys = {unesc(m) for m in re.findall(r'\bL\("((?:[^"\\]|\\.)*)"', src)}
tr = {unesc(k): unesc(v) for k, v in re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$', strings, re.M)}
verbs = lambda s: re.findall(r'%[-+# 0-9.]*@', s)
bad = []
for k in sorted(keys - tr.keys()): bad.append(f"missing Russian translation: {k!r}")
for k in sorted(tr.keys() - keys): bad.append(f"unused translation: {k!r}")
for k, v in tr.items():
    if verbs(k) != verbs(v): bad.append(f"format verbs differ: {k!r} / {v!r}")
    if not v.strip(): bad.append(f"empty translation: {k!r}")
print("\n".join(bad) if bad else f"OK: {len(keys)} strings, all translated")
sys.exit(1 if bad else 0)
