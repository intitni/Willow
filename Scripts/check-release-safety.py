#!/usr/bin/env python3
"""检查可提交文件和未签名发布包；报告路径与规则，不输出匹配到的敏感内容。"""
import argparse
import pathlib
import re
import subprocess
import sys

CERTIFICATE_SUFFIXES = {'.p12', '.pfx', '.p8', '.pem', '.key', '.cer', '.der', '.mobileprovision', '.provisionprofile', '.keychain', '.keychain-db'}
PRIVATE_MATERIAL = re.compile(rb'-----BEGIN (?:[A-Z0-9 ]*PRIVATE KEY|CERTIFICATE)-----')
SIGNING_SETTING = re.compile(r'^[ \t]*(?:DEVELOPMENT_TEAM|PROVISIONING_PROFILE_SPECIFIER|PROVISIONING_PROFILE)[ \t]*=[ \t]*([^;\n]*)(?:;|$)', re.M)


def file_issues(path):
    issues = []
    if path.suffix.lower() in CERTIFICATE_SUFFIXES or path.name.endswith('.local.xcconfig'):
        issues.append('signing material or local signing configuration')
    if path.name == '.env' or path.name.startswith('.env.'):
        issues.append('environment configuration')
    data = path.read_bytes()
    if PRIVATE_MATERIAL.search(data):
        issues.append('PEM certificate or private key')
    if path.suffix in {'.pbxproj', '.xcconfig'} and path.name != 'Signing.example.xcconfig':
        for value in SIGNING_SETTING.findall(data.decode('utf-8', errors='replace')):
            value = value.strip().strip('"')
            if value and not value.startswith('$('):
                issues.append('hardcoded personal signing setting')
    return issues


def check_source(root):
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).split(b'\0')
    failures = []
    for raw in sorted(set(paths)):
        if not raw:
            continue
        relative = pathlib.Path(raw.decode())
        path = root / relative
        if path.is_file():
            failures.extend(f'{relative}: {issue}' for issue in file_issues(path))
    return failures


def check_app(app):
    failures = []
    for path in app.rglob('*'):
        relative = path.relative_to(app)
        if path.name == '_CodeSignature' or path.suffix.lower() in CERTIFICATE_SUFFIXES:
            failures.append(f'{relative}: signing material in release artifact')
        if path.is_file():
            # 每个 Mach-O 都必须未签名，包括嵌套 framework 或扩展。
            kind = subprocess.check_output(['file', '-b', str(path)], text=True)
            if 'Mach-O' in kind:
                result = subprocess.run(['codesign', '-d', str(path)], capture_output=True)
                if result.returncode == 0:
                    failures.append(f'{relative}: signed Mach-O in unsigned artifact')
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=pathlib.Path)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    failures = check_app(args.app) if args.app else check_source(root)
    for failure in failures:
        print(f'ERROR: {failure}', file=sys.stderr)
    if failures:
        return 1
    print('Release safety checks passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
