#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Packaging never builds or signs: the input must already be accepted.
exec /usr/bin/python3 - "$ROOT_DIR" "$@" <<'PY'
import argparse, hashlib, os, pathlib, plistlib, re, stat, subprocess, sys, tempfile, zipfile
p = argparse.ArgumentParser(description='Package an already verified app without changing it')
p.add_argument('--app', required=True, type=pathlib.Path)
p.add_argument('--output-dir', type=pathlib.Path, default=pathlib.Path(sys.argv[1]) / 'dist')
a = p.parse_args(sys.argv[2:])
APP = 'CodexPetHungerMeter.app'
EXE = 'Contents/MacOS/codex-pet-hunger-meter'
FILES = {'Contents/Info.plist', EXE, 'Contents/Resources/AppIcon.icns',
         'Contents/Resources/food_bowl_meter.png', 'Contents/_CodeSignature/CodeResources'}
DIRS = {'Contents', 'Contents/MacOS', 'Contents/Resources', 'Contents/_CodeSignature'}
def run(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def manifest(app):
    if app.is_symlink() or not app.is_dir() or app.name != APP:
        raise ValueError('Expected a real CodexPetHungerMeter.app directory')
    result = {}
    directories = set()
    for f in app.rglob('*'):
        rel = f.relative_to(app).as_posix()
        if f.is_symlink():
            raise ValueError('Symlinks are not allowed: ' + rel)
        if f.is_dir():
            directories.add(rel)
        elif f.is_file() and rel in FILES:
            result[rel] = (hashlib.sha256(f.read_bytes()).hexdigest(), stat.S_IMODE(f.stat().st_mode))
        else:
            raise ValueError('Unexpected bundle entry: ' + rel)
    if set(result) != FILES or directories != DIRS or not os.access(app / EXE, os.X_OK):
        raise ValueError('Bundle contents or executable permissions do not match the allowlist')
    return result

def validate(app):
    contents = manifest(app)
    run('codesign', '--verify', '--deep', '--strict', str(app))
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d+', build):
        raise ValueError('Invalid version or build')
    if info.get('CFBundleIdentifier') != 'com.codex-pet.hunger-meter' or info.get('CFBundleExecutable') != pathlib.Path(EXE).name:
        raise ValueError('Unexpected bundle identity')
    arch = run('lipo', '-archs', str(app / EXE)).strip()
    if arch not in ('arm64', 'x86_64'):
        raise ValueError('Expected a single supported architecture')
    platform = run('xcrun', 'vtool', '-show-build', str(app / EXE))
    if info.get('LSMinimumSystemVersion') != '13.0' or re.findall(r'\bminos\s+(\S+)', platform) != ['13.0']:
        raise ValueError('Both plist and executable must target macOS 13.0')
    strings = run('strings', '-a', str(app / EXE))
    if any(marker in strings for marker in ('/Users/', '/Volumes/', '/private/tmp/')):
        raise ValueError('Executable contains a local build path; rebuild and revalidate before packaging')
    return contents, version, build, arch

try:
    app = a.app.absolute()
    original, version, build, arch = validate(app)
    out = a.output_dir.absolute()
    out.mkdir(parents=True, exist_ok=True)
    name = f'codex-pet-meter-{version}-macos-{arch}.zip'
    destination, checksum = out / name, out / (name + '.sha256')
    if destination.exists() or destination.is_symlink() or checksum.exists() or checksum.is_symlink():
        raise FileExistsError('Release output already exists; refusing to overwrite it')
    with tempfile.TemporaryDirectory(prefix='.package-', dir=out) as temp:
        stage = pathlib.Path(temp)
        copied = stage / APP
        run('ditto', '--norsrc', '--noextattr', '--noqtn', str(app), str(copied))
        if validate(copied) != (original, version, build, arch):
            raise ValueError('Staging changed the accepted bundle')
        archive = stage / name
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', '--noqtn', str(copied), str(archive))
        run('unzip', '-t', str(archive))
        with zipfile.ZipFile(archive) as z:
            names = z.namelist()
            expected = {APP + '/' + f for f in FILES}
            allowed_dirs = {APP + '/', *(APP + '/' + d + '/' for d in DIRS)}
            if len(names) != len(set(names)) or {n for n in names if not n.endswith('/')} != expected or any(n.endswith('/') and n not in allowed_dirs for n in names):
                raise ValueError('ZIP contents do not match the bundle allowlist')
            if any(stat.S_ISLNK(i.external_attr >> 16) for i in z.infolist()):
                raise ValueError('ZIP contains a symlink')
        extracted = stage / 'extracted'
        run('ditto', '-x', '-k', '--norsrc', '--noextattr', '--noqtn', str(archive), str(extracted))
        if validate(extracted / APP) != (original, version, build, arch) or manifest(app) != original:
            raise ValueError('Roundtrip or input bundle mismatch')
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        sha = stage / checksum.name
        sha.write_text(f'{digest}  {name}\n')
        subprocess.run(['shasum', '-a', '256', '-c', sha.name], cwd=stage, check=True)
        # Atomic no-clobber publication. Keep every previous dist file intact.
        os.link(archive, destination)
        try:
            os.link(sha, checksum)
        except Exception:
            destination.unlink()
            raise
    print(f'Packaged: {destination}\nSHA256: {digest}\nVersion: {version} ({build}); macOS 13.0; {arch}')
except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as e:
    print(f'Packaging failed: {e}', file=sys.stderr)
    sys.exit(1)
PY
