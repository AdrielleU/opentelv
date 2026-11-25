"""install.sh's min_futurity setting, against a pretend Fire TV: Android 11 and older
read it from settings global alarm_manager_constants, Android 12 and later only from
DeviceConfig (issue #57).

Run: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FuturityTest(unittest.TestCase):
    def run_steps(self, sdk, settings, *steps, refused=False):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            state = tmp / "state.json"
            state.write_text(json.dumps({"packages": {}, "settings": settings,
                                         "device_config_refused": refused}))
            log = tmp / "commands.log"
            log.touch()
            env = dict(os.environ, FAKE_TV_STATE=str(state), FAKE_TV_LOG=str(log))
            script = ('set -euo pipefail; ADB=$1; sh_() { "$ADB" -s test-tv shell "$@" </dev/null; }; '
                      'source "$2"; dev_sdk=$3; shift 3; for s in "$@"; do set_futurity "$s"; done; echo done')
            result = subprocess.run(["bash", "-c", script, "bash", str(ROOT / "tests" / "fake_tv.py"),
                                     str(ROOT / "scripts" / "home.sh"), str(sdk), *steps],
                                    env=env, capture_output=True, text=True, timeout=60)
            self.assertIn("done", result.stdout, result.stderr)
            final = json.loads(state.read_text())
            self.assertNotIn("bad", final, "a malformed command reached the TV")
            return final["settings"], result.stderr

    def test_android11_writes_the_global_setting(self):
        settings, _ = self.run_steps(30, {"global/alarm_manager_constants": "other=1"}, "on")
        self.assertEqual(settings, {"global/alarm_manager_constants": "other=1,min_futurity=0"})

    def test_android12_writes_device_config_only(self):
        for sdk in (31, 34):
            with self.subTest(sdk=sdk):
                settings, _ = self.run_steps(sdk, {"global/alarm_manager_constants": "min_futurity=5000"}, "on")
                self.assertEqual(settings["config/alarm_manager/min_futurity"], "0")
                self.assertEqual(settings["global/alarm_manager_constants"], "min_futurity=5000")
                self.assertNotIn("global/dumbtv_min_futurity", settings)

    def test_an_earlier_value_is_kept_and_put_back(self):
        for sdk, key, before in ((28, "global/alarm_manager_constants", "min_futurity=3000"),
                                 (34, "config/alarm_manager/min_futurity", "3000")):
            with self.subTest(sdk=sdk):
                settings, _ = self.run_steps(sdk, {key: before}, "on", "on")
                self.assertEqual(settings["global/dumbtv_min_futurity"], "3000")
                settings, _ = self.run_steps(sdk, {key: before}, "on", "on", "off")
                self.assertEqual(settings, {key: before})

    def test_android12_undo_leaves_an_owners_global_value(self):
        settings, _ = self.run_steps(34, {"global/alarm_manager_constants": "min_futurity=5000"}, "on", "off")
        self.assertEqual(settings, {"global/alarm_manager_constants": "min_futurity=5000"})

    def test_a_refused_device_config_write_does_not_stop_the_install(self):
        settings, stderr = self.run_steps(34, {}, "on", refused=True)
        self.assertIn("could not set device_config alarm_manager min_futurity", stderr)
        self.assertNotIn("config/alarm_manager/min_futurity", settings)


if __name__ == "__main__":
    unittest.main()
