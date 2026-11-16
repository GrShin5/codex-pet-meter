#!/usr/bin/env python3
"""Isolated installer mocks and real signed-bundle packaging acceptance checks."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'build/CodexPetHungerMeter.app'
NAME = APP.name
EXE = Path('Contents/MacOS/codex-pet-hunger-meter')

class ReleaseTools(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pet-release-tests-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def installer(self, scenario, fail_signature=''):
        root = self.base / scenario
        root.mkdir()
        mocks = root / 'mocks'
        mocks.mkdir()
        state = root / 'state'
        calls = root / 'calls'
        target = root / 'Applications' / NAME
        target.mkdir(parents=True)
        (target / 'previous-marker').write_text('previous app')
        plist = root / 'Library/LaunchAgents/com.codex-pet.hunger-meter.plist'
        plist.parent.mkdir(parents=True)
        previous_plist = b'previous login item'
        plist.write_bytes(previous_plist)
        prefs = root / 'Library/Preferences/com.codex-pet.hunger-meter.plist'
        prefs.parent.mkdir(parents=True)
        prefs.write_bytes(b'preferences must survive')
        if scenario in ('registered', 'foreign', 'kickstart-failure'):
            state.write_text('foreign' if scenario == 'foreign' else 'expected')
        (mocks / 'launchctl').write_text('''#!/usr/bin/env python3
import os, pathlib, sys
state=pathlib.Path(os.environ['TEST_STATE']); scenario=os.environ['TEST_SCENARIO']
with open(os.environ['TEST_CALLS'],'a') as f: f.write(' '.join(sys.argv[1:])+'\\n')
command=sys.argv[1]
if command=='print':
 if not state.exists(): sys.exit(113)
 print('    program = '+('/foreign/app' if state.read_text()=='foreign' else os.environ['TEST_EXECUTABLE']))
elif command=='bootstrap':
 if scenario=='bootstrap-failure': sys.exit(5)
 state.write_text('foreign' if scenario=='foreign-race' else 'expected')
 if scenario in ('bootstrap-race','foreign-race'): sys.exit(5)
elif command=='kickstart':
 if scenario=='kickstart-failure': sys.exit(5)
elif command=='bootout':
 state.unlink(missing_ok=True)
else: sys.exit(99)
''')
        (mocks / 'codesign').write_text('''#!/usr/bin/env bash
if [[ "$TEST_FAIL_SIGNATURE" == source || ( "$TEST_FAIL_SIGNATURE" == stage && "$*" == *'.pet-meter-install.'* ) ]]; then exit 1; fi
exec /usr/bin/codesign "$@"
''')
        for f in mocks.iterdir():
            f.chmod(0o755)
        env = dict(os.environ, PATH=str(mocks) + ':' + os.environ['PATH'],
                   CODEX_PET_INSTALL_TESTING='1', TEST_STATE=str(state), TEST_CALLS=str(calls),
                   TEST_SCENARIO=scenario, TEST_EXECUTABLE=str(target / EXE), TEST_FAIL_SIGNATURE=fail_signature)
        result = subprocess.run(['bash', str(ROOT / 'tools/install-hunger-meter.sh'), '--app', str(APP), '--test-root', str(root)], env=env, text=True, capture_output=True)
        succeeded = scenario in ('registered', 'unregistered', 'bootstrap-race') and not fail_signature
        self.assertEqual(result.returncode == 0, succeeded, result.stdout + result.stderr)
        history = calls.read_text() if calls.exists() else ''
        self.assertEqual(prefs.read_bytes(), b'preferences must survive')
        if succeeded:
            self.assertEqual((target / EXE).read_bytes(), (APP / EXE).read_bytes())
            self.assertEqual(plistlib.loads(plist.read_bytes())['ProgramArguments'], [str(target / EXE)])
            self.assertIn('kickstart -k', history)
            self.assertEqual('bootstrap gui/' in history, scenario != 'registered')
            self.assertNotIn('bootout', history)
        else:
            self.assertEqual((target / 'previous-marker').read_text(), 'previous app')
            self.assertEqual(plist.read_bytes(), previous_plist)
            if fail_signature:
                self.assertNotIn('bootstrap', history)
                self.assertNotIn('kickstart', history)
        self.assertEqual(list((root / 'Applications').glob('.pet-meter-install.*')), [])

    def test_registered(self): self.installer('registered')
    def test_unregistered(self): self.installer('unregistered')
    def test_bootstrap_race(self): self.installer('bootstrap-race')
    def test_bootstrap_failure_rollback(self): self.installer('bootstrap-failure')
    def test_foreign_registration_preserved(self): self.installer('foreign')
    def test_foreign_bootstrap_race_rollback(self): self.installer('foreign-race')
    def test_kickstart_failure_rollback(self): self.installer('kickstart-failure')
    def test_source_signature_gate(self): self.installer('signature-source', 'source')
    def test_staged_signature_gate(self): self.installer('signature-stage', 'stage')

    def package(self, app, output):
        return subprocess.run(['bash', str(ROOT / 'scripts/package-release.sh'), '--app', str(app), '--output-dir', str(output)], text=True, capture_output=True)

    def test_package_roundtrip_collision_and_previous_dist(self):
        out = self.base / 'dist'
        out.mkdir()
        old = out / 'codex-pet-meter-0.1.0.zip'
        old.write_bytes(b'protected earlier release')
        before = {str(f.relative_to(APP)): hashlib.sha256(f.read_bytes()).hexdigest() for f in APP.rglob('*') if f.is_file()}
        result = self.package(APP, out)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive, = out.glob('*0.1.1*.zip')
        sha = Path(str(archive) + '.sha256')
        archive_hash, checksum_bytes = hashlib.sha256(archive.read_bytes()).hexdigest(), sha.read_bytes()
        self.assertIn(archive_hash, sha.read_text())
        repeated = self.package(APP, out)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertIn('already exists', repeated.stderr)
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), archive_hash)
        self.assertEqual(sha.read_bytes(), checksum_bytes)
        self.assertEqual(old.read_bytes(), b'protected earlier release')
        self.assertEqual(before, {str(f.relative_to(APP)): hashlib.sha256(f.read_bytes()).hexdigest() for f in APP.rglob('*') if f.is_file()})
        self.assertEqual(list(out.glob('.package-*')), [])

    def test_package_rejects_extra_file(self):
        app = self.base / NAME
        shutil.copytree(APP, app)
        (app / 'Contents/.DS_Store').write_bytes(b'unwanted')
        result = self.package(app, self.base / 'out')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unexpected bundle entry', result.stderr)
        self.assertFalse((self.base / 'out').exists())

    def test_package_rejects_symlink(self):
        app = self.base / NAME
        shutil.copytree(APP, app)
        (app / 'Contents/log').symlink_to('/tmp')
        result = self.package(app, self.base / 'out')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Symlinks', result.stderr)

    def test_packager_requires_explicit_app(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/package-release.sh')], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--app', result.stderr)

if __name__ == '__main__':
    unittest.main(verbosity=2)
