#!/usr/bin/env python3
"""Stage the patched QuickJS crate for Cargo without modifying the Breeze checkout."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


root = Path(__file__).resolve().parent.parent
vendor = root / 'Vendor/Breeze'
source = vendor / 'rust/rquickjs_playground'
patch = root / 'Bridge/patches/breeze-system-dns.patch'
revision = subprocess.check_output(['git', '-C', str(vendor), 'rev-parse', 'HEAD'], text=True).strip()
digest = hashlib.sha256(patch.read_bytes()).hexdigest()
staging = root / 'Bridge/target/breeze-runtime'
staging.mkdir(parents=True, exist_ok=True)
runtime = staging / f'{revision}-{digest}'

if not runtime.is_dir():
    with tempfile.TemporaryDirectory(dir=staging) as temporary:
        copy = Path(temporary) / 'rquickjs_playground'
        shutil.copytree(source, copy, ignore=shutil.ignore_patterns('.git', 'target', 'node_modules'))
        subprocess.run(['patch', '--batch', '--forward', '-p1', '-i', str(patch)], cwd=copy, stdout=subprocess.DEVNULL, check=True)
        try:
            copy.rename(runtime)
        except OSError:
            if not runtime.is_dir():
                raise

print('paths=' + json.dumps([str(runtime)]))
