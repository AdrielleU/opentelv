"""Starting dumbtv home at the end of an install, on a TV that may be asleep.

`am start -W` waits until the activity draws, and a sleeping TV never draws it, so
launcher/install.sh hung for ever when the TV fell asleep during an install.

Run: python3 -m unittest discover -s tests -v
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

# A TV that is asleep until it gets a wake key (unless it ignores it), and whose
# `am start -W` blocks while it sleeps, as a real one does.
SLEEPY_ADB = r'''#!/usr/bin/env bash
case "$*" in
  *"input keyevent KEYCODE_WAKEUP"*) [[ -f "$IGNORES_WAKE" ]] || touch "$AWAKE"; echo "$*" >> "$LOG" ;;
  *"am start -W -n tv.dumbtv.home/.Home"*) echo "$*" >> "$LOG"
     while [[ ! -f "$AWAKE" ]]; do sleep 0.2; done; echo "Status: ok" ;;
  *) exit 92 ;;
esac
'''


class StartHomeTest(unittest.TestCase):
    def start(self, ignores_wake=False, bound="20"):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            adb = tmp / "adb"
            adb.write_text(SLEEPY_ADB)
            adb.chmod(0o755)
            if ignores_wake:
                (tmp / "ignores").touch()
            env = dict(os.environ, AWAKE=str(tmp / "awake"), IGNORES_WAKE=str(tmp / "ignores"),
                       LOG=str(tmp / "log"))
            script = ('sh_() { "$ADB" shell "$@" </dev/null; }; ADB=$1; source "$2"; '
                      'start_home tv.dumbtv.home/.Home "$3"; echo "exit $?"')
            began = time.monotonic()
            result = subprocess.run(["bash", "-c", script, "bash", str(adb),
                                     str(ROOT / "scripts" / "home.sh"), bound],
                                    env=env, capture_output=True, text=True, timeout=60)
            took = time.monotonic() - began
            log = (tmp / "log").read_text().splitlines() if (tmp / "log").exists() else []
            return result, took, log

    def test_a_sleeping_tv_is_woken_first(self):
        result, took, log = self.start()
        self.assertIn("exit 0", result.stdout, result.stderr)
        self.assertLess(took, 10)
        self.assertTrue(log and "KEYCODE_WAKEUP" in log[0], log)

    def test_a_tv_that_stays_asleep_cannot_hang_the_install(self):
        result, took, _ = self.start(ignores_wake=True, bound="2")
        self.assertIn("exit 0", result.stdout, result.stderr)
        self.assertLess(took, 10)
        self.assertIn("did not draw", result.stdout)


if __name__ == "__main__":
    unittest.main()
