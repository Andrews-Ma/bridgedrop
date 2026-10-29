#!/usr/bin/env python3
"""Generate Apple icon containers and asset catalogs from the original project icon."""
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets'
CATALOG = ASSETS / 'Assets.xcassets'

def clean_png(path):
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Expected PNG')
    kept = [data[:8]]
    offset = 8
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        chunk = data[offset:offset + 12 + size]
        if kind in {b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'sRGB', b'gAMA', b'cHRM'}:
            kept.append(chunk)
        offset += 12 + size
    path.write_bytes(b''.join(kept))

def resize(source, destination, size):
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['sips', '-z', str(size), str(size), str(source), '--out', str(destination)],
                   check=True, stdout=subprocess.DEVNULL)
    clean_png(destination)

master = ASSETS / 'app-icon.png'
resize(ASSETS / 'app-icon-original.png' if (ASSETS / 'app-icon-original.png').exists() else master, master, 1024)
CATALOG.mkdir(exist_ok=True)
(CATALOG / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
icons = CATALOG / 'AppIcon.appiconset'
icons.mkdir(exist_ok=True)
resize(master, icons / 'ios-1024.png', 1024)
entries = [{'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024', 'filename': 'ios-1024.png'}]
iconset = ASSETS / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
        resize(master, iconset / name, size * scale)
        resize(master, icons / name, size * scale)
        entries.append({'idiom': 'mac', 'size': f'{size}x{size}', 'scale': f'{scale}x', 'filename': name})
(icons / 'Contents.json').write_text(json.dumps({'images': entries, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
brand = CATALOG / 'BrandIcon.imageset'
resize(master, brand / 'BrandIcon.png', 256)
(brand / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'BrandIcon.png', 'idiom': 'universal'}],
                                              'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(ASSETS / 'AppIcon.icns')], check=True)
print('Generated macOS ICNS and iOS/macOS AppIcon asset catalog.')
