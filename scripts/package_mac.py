#!/usr/bin/env python3
"""Package an already-built macOS application; verify ZIP and extracted signature."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
version = plistlib.loads((ROOT / 'config/Mac-Info.plist').read_bytes())['CFBundleShortVersionString']
app = ROOT / 'outputs' / ('BridgeDrop-Mac-v' + version) / '轻传.app'
release = Path(os.environ.get('BRIDGEDROP_RELEASE_DIR', str(ROOT / 'outputs/release')))
release.mkdir(parents=True, exist_ok=True)
archive = release / f'BridgeDrop-{version}-macOS-Apple-Silicon.zip'
if archive.exists():
    raise SystemExit('Refusing to overwrite an existing release archive.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
with tempfile.TemporaryDirectory(prefix='bridgedrop-package-') as directory:
    staging = Path(directory) / 'BridgeDrop'
    staging.mkdir()
    subprocess.run(['ditto', str(app), str(staging / '轻传.app')], check=True)
    shutil.copy2(ROOT / 'LICENSE', staging / 'LICENSE.txt')
    (staging / 'READ ME.txt').write_text(
        'BridgeDrop / 轻传 ' + version + '\n\nApple silicon Mac, macOS 13 or later. Unzip and move 轻传.app to Applications.\n'
        '适用于 Apple 芯片 Mac，macOS 13 或更新版本。解压后将轻传.app 移入应用程序目录。\n'
        'For iPhone installation and limitations, see the README in the source package.\n', encoding='utf-8')
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(staging), str(archive)], check=True)
    with zipfile.ZipFile(archive) as value:
        if value.testzip():
            raise RuntimeError('ZIP integrity check failed')
        if 'BridgeDrop/LICENSE.txt' not in value.namelist():
            raise RuntimeError('License missing from package')
    extract = Path(directory) / 'extracted'
    subprocess.run(['ditto', '-x', '-k', str(archive), str(extract)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(extract / 'BridgeDrop/轻传.app')], check=True)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(release / 'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n', encoding='ascii')
print(f'Verified package: {archive.name}; SHA-256 {digest}')
