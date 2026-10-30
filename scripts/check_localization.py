#!/usr/bin/env python3
"""Check coverage of explicit UI translations and run presentation behavior tests."""
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'App/Localization.swift').read_text(encoding='utf-8')
literal = r'"(?:\\.|[^"\\])*"'
keys = {json.loads(item) for item in re.findall(r'(' + literal + r')\s*:', source)}
for path in [root / 'App/ContentView.swift', root / 'App/QRScanner.swift']:
    text = path.read_text(encoding='utf-8')
    for item in re.findall(r'(?:tr|BridgeLocalization\.current)\((' + literal + r')\)', text):
        if '\\(' in item:  # Covered by runtime interpolation tests.
            continue
        value = json.loads(item)
        if re.search(r'[\u4e00-\u9fff]', value) and value not in keys:
            raise SystemExit('Missing English translation in ' + path.name + ': ' + value)
with tempfile.TemporaryDirectory(prefix='bridgedrop-i18n-check-') as directory:
    binary = str(Path(directory) / 'BridgeDrop-localization-check')
    subprocess.run(['swiftc', '-parse-as-library', str(root / 'App/Localization.swift'),
                    str(root / 'scripts/check_localization.swift'), '-o', binary], check=True)
    subprocess.run([binary], check=True)
print('PASS: all explicit interface and scanner strings have English translations')
