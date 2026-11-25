"""scripts/appdata.sh: the adb restore archive, and answering the TV's confirmation.

Run: python3 -m unittest discover -s tests -v
"""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HEADER = b'ANDROID BACKUP\n5\n0\nnone\n'


class ArchiveTest(unittest.TestCase):
    def test_android_can_read_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            src = tmp / 'data'
            src.mkdir()
            (src / 'dnsfilter.conf').write_text('detectDNS = false\n')
            (src / 'VERSION.TXT').write_text('1506103')
            out = tmp / 'out.ab'
            subprocess.run(['bash', '-c', 'source "$1"; app_data_archive "$2" dnsfilter.android 1506103 30 abcdef "$3" PersonalDNSFilter',
                            'bash', str(ROOT / 'scripts' / 'appdata.sh'), str(out), str(src)], check=True)
            raw = out.read_bytes()
            self.assertTrue(raw.startswith(HEADER))
            tar = tarfile.open(fileobj=io.BytesIO(raw[len(HEADER):]))
            members = tar.getmembers()
            self.assertEqual(members[0].name, 'apps/dnsfilter.android/_manifest')
            self.assertEqual(tar.extractfile(members[0]).read().decode(),
                             '1\ndnsfilter.android\n1506103\n30\n\n0\n1\nabcdef\n')
            # Android's reader stops or fails on anything but plain files and directories.
            self.assertTrue(all(m.type in (tarfile.REGTYPE, tarfile.DIRTYPE) for m in members))
            names = {m.name for m in members}
            base = 'apps/dnsfilter.android/ef/PersonalDNSFilter/'
            self.assertLessEqual({base + 'dnsfilter.conf', base + 'VERSION.TXT'}, names)
            self.assertFalse(any('/._' in n for n in names))
            self.assertEqual(tar.extractfile(base + 'VERSION.TXT').read(), b'1506103')


class ConfirmTest(unittest.TestCase):
    def restore(self, *switches):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, ADB=str(ROOT / 'tests' / 'fake_restore_adb.py'),
                       ADB_SERIAL='test-tv', FAKE_DIR=tmp)
            env.update({s: '1' for s in switches})
            # dnsfilter.sh runs with pipefail, which breaks `dev ... | grep -q` checks.
            script = ('set -uo pipefail; source "$1/scripts/lib.sh"; source "$1/scripts/appdata.sh"; '
                      'restore_app_data /dev/null; echo "rc=$?"')
            result = subprocess.run(['bash', '-c', script, 'bash', str(ROOT)], env=env,
                                    capture_output=True, text=True, timeout=120)
            keys = Path(tmp, 'keys')
            return result, keys.read_text().splitlines() if keys.exists() else []

    def test_restore_my_data_is_tapped(self):
        result, keys = self.restore()
        self.assertIn('rc=0', result.stdout, result.stderr)
        self.assertEqual(keys, ['ALLOW by tap'])

    def test_keys_are_the_second_try_and_ok_lands_on_restore_my_data_only(self):
        result, keys = self.restore('TAP_IGNORED')
        self.assertIn('rc=0', result.stdout, result.stderr)
        self.assertEqual(keys, ['KEYCODE_TAB enc_password', 'KEYCODE_TAB button_deny',
                                'KEYCODE_DPAD_CENTER button_allow', 'ALLOW by OK key'])

    def test_a_restore_android_refuses_is_a_failure(self):
        result, _ = self.restore('REFUSED')
        self.assertIn('rc=1', result.stdout, result.stderr)

    def test_a_request_left_unanswered_is_a_failure(self):
        result, keys = self.restore('TAP_IGNORED', 'TAB_IGNORED')
        self.assertIn('rc=1', result.stdout, result.stderr)
        self.assertNotIn('KEYCODE_DPAD_CENTER', ' '.join(keys))
        self.assertIn('RESTORE MY DATA', result.stderr)


if __name__ == '__main__':
    unittest.main()
