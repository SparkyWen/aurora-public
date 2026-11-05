#!/usr/bin/env python3
"""A restrictive build umask must not make the installed sysext unreadable."""
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / 'normalize_bundle_permissions.sh'


class BundlePermissionsTest(unittest.TestCase):
    def test_symlink_root_is_rejected_without_changing_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            real = root / 'real.app'
            real.mkdir(mode=0o700)
            link = root / 'alias.app'
            link.symlink_to(real, target_is_directory=True)
            for argument in (str(link), str(link) + '/', str(link) + '///'):
                with self.subTest(argument=argument):
                    result = subprocess.run(['bash', str(HELPER), argument], capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(stat.S_IMODE(real.stat().st_mode), 0o700)

    def test_private_build_becomes_readable_without_exposing_contract_or_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / 'Aurora test.app'
            extension = app / 'Contents' / 'Library' / 'SystemExtensions' / 'Tunnel.systemextension'
            extension.mkdir(parents=True)
            info = extension / 'Info.plist'
            binary = extension / 'Tunnel'
            contract = app / 'aurora-contract.json'
            outside = root / 'private-outside'
            for path in (info, binary, contract, outside):
                path.write_bytes(b'unchanged')
                path.chmod(0o600)
            binary.chmod(0o700)
            for path in [app, *[p for p in app.rglob('*') if p.is_dir()]]:
                path.chmod(0o700)
            (app / 'outside-link').symlink_to(outside)
            outside_dir = root / 'outside-dir'
            outside_dir.mkdir(mode=0o700)
            (app / 'outside-dir-link').symlink_to(outside_dir, target_is_directory=True)

            subprocess.run(['bash', str(HELPER), str(app)], check=True)

            for path in (app, extension, app / 'Contents'):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755)
            self.assertEqual(stat.S_IMODE(info.stat().st_mode), 0o644)
            self.assertEqual(stat.S_IMODE(binary.stat().st_mode), 0o755)
            for path in (contract, outside):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertEqual(path.read_bytes(), b'unchanged')
            self.assertEqual(stat.S_IMODE(outside_dir.stat().st_mode), 0o700)
            self.assertTrue((app / 'outside-link').is_symlink())
            self.assertTrue((app / 'outside-dir-link').is_symlink())


if __name__ == '__main__':
    unittest.main()
