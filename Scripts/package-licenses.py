#!/usr/bin/env python3
"""Generate bundled notices and a source archive from the locked iOS dependency graph."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'Core/Sources/CoreStorage/Resources/ThirdPartyLicenses.json'
# Published crates sometimes omit their license file. Select an explicitly offered
# license; keep upstream authors and the full matching standard text alongside it.
FALLBACKS = {
    'ferrous-opencc': 'Apache-2.0', 'ferrous-opencc-compiler': 'Apache-2.0',
    'intl_pluralrules': 'Apache-2.0', 'selectors': 'MPL-2.0', 'libwebp-sys': 'MIT',
}
ALIASES = {'srcmap-scopes': 'srcmap-codec', 'srcmap-sourcemap': 'srcmap-codec'}


def metadata():
    result = subprocess.check_output([
        'sh', str(ROOT / 'Scripts/cargo-bridge.sh'), 'metadata', '--locked', '--offline',
        '--manifest-path', str(ROOT / 'Bridge/Cargo.toml'), '--format-version', '1',
        '--filter-platform', 'aarch64-apple-ios',
    ], cwd=ROOT)
    graph = json.loads(result)
    nodes = {n['id']: n for n in graph['resolve']['nodes']}
    seen = set()
    def visit(identifier):
        if identifier in seen:
            return
        seen.add(identifier)
        for dependency in nodes[identifier]['dependencies']:
            visit(dependency)
    visit(graph['resolve']['root'])
    return sorted((p for p in graph['packages'] if p['id'] in seen), key=lambda p: (p['name'], p['version']))


def revision():
    return subprocess.check_output(['git', '-C', str(ROOT / 'Vendor/Breeze'), 'rev-parse', 'HEAD'], text=True).strip()


def license_files(directory):
    for path in sorted(directory.rglob('*')):
        if not path.is_file() or {'.git', 'target'}.intersection(path.relative_to(directory).parts):
            continue
        name = path.name.lower()
        if name.startswith(('license', 'licence', 'copying', 'notice', 'copyright', 'unlicense', 'authors')) or name.endswith(('.license', '.license.txt')):
            # License-related source code is not a legal notice.
            if path.suffix not in {'.rs', '.c', '.h', '.py', '.sh', '.go', '.toml', '.json'}:
                yield path


def document(packages):
    rev = revision()
    entries = [{
        'id': 'Breeze', 'name': 'Breeze', 'version': rev, 'license': 'MPL-2.0',
        'source': f'https://github.com/breeze-project-org/Breeze/tree/{rev}',
        'text': (ROOT / 'Vendor/Breeze/LICENSE').read_text(),
    }]
    for package in packages:
        name, version = package['name'], package['version']
        if name == 'willow_bridge':
            continue
        directory = Path(package['manifest_path']).parent
        paths = list(license_files(directory))
        override = ROOT / 'Licenses/Overrides' / f'{ALIASES.get(name, name)}-{version}'
        paths += list(license_files(override)) if override.exists() else []
        declared = package['license'] or ('MPL-2.0' if name == 'rquickjs_playground' else '')
        if name == 'rquickjs_playground':
            paths.insert(0, ROOT / 'Vendor/Breeze/LICENSE')
        if name in FALLBACKS:
            paths.insert(0, ROOT / f'Licenses/Standard/{FALLBACKS[name]}.txt')
        if package['license_file']:
            paths.append(directory / package['license_file'])
        if not paths or not declared:
            raise ValueError(f'Missing license review: {name} {version}')
        texts, seen = [], set()
        for path in paths:
            text = path.read_text(encoding='utf-8', errors='replace').strip()
            digest = hashlib.sha256(text.encode()).hexdigest()
            if digest in seen:
                continue
            seen.add(digest)
            label = str(path.relative_to(directory)) if path.is_relative_to(directory) else path.name
            texts.append(label + '\n\n' + text)
        source = f'https://crates.io/api/v1/crates/{name}/{version}/download'
        if name == 'rquickjs_playground':
            source = entries[0]['source'] + '/rust/rquickjs_playground'
        elif package['source'] and package['source'].startswith('git+'):
            repository, commit = package['source'][4:].split('#')
            source = repository.split('?')[0].removesuffix('.git') + '/tree/' + commit
        authors = ', '.join(package['authors'])
        note = f'Authors (upstream package metadata): {authors}\n\n' if authors else ''
        if name in FALLBACKS:
            note += f'This package declares {declared}; the {FALLBACKS[name]} option is used. Its published archive omits the root license text; the standard text is reproduced below.\n\n'
        entries.append({'id': name + '-' + version, 'name': name, 'version': version,
                        'license': declared, 'source': source, 'text': note + '\n\n---\n\n'.join(texts)})
    return {'breezeRevision': rev, 'cargoLockSHA256': hashlib.sha256((ROOT / 'Bridge/Cargo.lock').read_bytes()).hexdigest(), 'entries': entries}


def source_archive(path, packages):
    # Explicit project allowlist: never include Signing.local.xcconfig, .git,
    # Keychain material, application data, build products, or developer environment files.
    with tarfile.open(path, 'w:gz') as archive:
        def add_tree(directory, destination):
            for file in sorted(directory.rglob('*')):
                if file.is_symlink() or not file.is_file() or any(p in {'.git', 'target'} for p in file.relative_to(directory).parts):
                    continue
                archive.add(file, arcname=destination + '/' + file.relative_to(directory).as_posix(), recursive=False)
        for name in ['LICENSE', 'Bridge/Cargo.toml', 'Bridge/Cargo.lock', 'Bridge/patches/breeze-system-dns.patch',
                     'THIRD_PARTY_NOTICES.md', 'Scripts/package-licenses.py']:
            archive.add(ROOT / name, arcname='Willow-Sources/' + name)
        add_tree(ROOT / 'Bridge/src', 'Willow-Sources/Bridge/src')
        add_tree(ROOT / 'Licenses', 'Willow-Sources/Licenses')
        # Include the actual working source used by the compiler, including any modifications.
        archive.add(ROOT / 'Vendor/Breeze/LICENSE', arcname='Willow-Sources/Vendor/Breeze/LICENSE')
        runtime = next(package for package in packages if package['name'] == 'rquickjs_playground')
        add_tree(Path(runtime['manifest_path']).parent, 'Willow-Sources/Vendor/Breeze/rust/rquickjs_playground')
        add_tree(ROOT / 'Vendor/Breeze/rust/src/decode', 'Willow-Sources/Vendor/Breeze/rust/src/decode')
        for package in packages:
            if package['name'] in {'willow_bridge', 'rquickjs_playground'}:
                continue
            add_tree(Path(package['manifest_path']).parent, f"Willow-Sources/dependencies/{package['name']}-{package['version']}")
        contents = ('Corresponding source for the Rust components in Willow.\n'
                    'Breeze sources are under MPL-2.0; dependency licenses remain applicable.\n'
                    'Bridge/src contains the Willow integration source under MPL-2.0. See LICENSE.\n'
                    'Bridge/Cargo.lock records the exact dependency versions and sources.\n'
                    'Dependencies include build-time components as well as runtime components.\n'
                    'Full source locations, license texts and authors are listed in ThirdPartyLicenses.json.\n').encode()
        info = tarfile.TarInfo('Willow-Sources/README.txt'); info.size = len(contents)
        archive.addfile(info, io.BytesIO(contents))
        archive.add(OUTPUT, arcname='Willow-Sources/ThirdPartyLicenses.json')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--source-archive', type=Path)
    args = parser.parse_args()
    packages = metadata()
    data = json.dumps(document(packages), ensure_ascii=False, indent=2) + '\n'
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != data:
            raise SystemExit('Third-party notices are stale. Run python3 Scripts/package-licenses.py.')
    else:
        OUTPUT.write_text(data)
    if args.source_archive:
        source_archive(args.source_archive, packages)
    print(f'Verified notices for {len(packages)} locked packages and Breeze.')

if __name__ == '__main__':
    main()
