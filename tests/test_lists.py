"""The data lists keep their promises: nothing a person uses is on a cleanup list,
and nothing the TV needs to work is on any list that removes things.

Run: python3 -m unittest discover -s tests -v
"""
from pathlib import Path
import unittest

DATA = Path(__file__).resolve().parents[1] / "data"


def entries(path):
    out = []
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line.split()[0])
    return out


class ListsTest(unittest.TestCase):
    def test_lists_do_not_overlap(self):
        for platform in ("fireos", "fireos6"):
            cleanup = set(entries(DATA / platform / "packages.txt"))
            never = set(entries(DATA / platform / "never-disable.txt"))
            alexa = set(entries(DATA / "fireos" / "alexa.txt"))
            apps = set(entries(DATA / "fireos" / "user-apps.txt"))
            with self.subTest(platform=platform):
                self.assertEqual(cleanup & apps, set())
                self.assertEqual(cleanup & alexa, set())
                self.assertEqual(alexa & apps, set())
                self.assertEqual((cleanup | alexa | apps) & never, set())

    def test_no_duplicates(self):
        for path in sorted(DATA.rglob("*.txt")):
            if path.name in {"apps.txt", "sources.txt"} or path.name.startswith("settings"):
                continue
            with self.subTest(path=path.name):
                found = entries(path)
                self.assertEqual(len(found), len(set(found)))

    def test_people_apps_are_never_cleanup(self):
        cleanup = set(entries(DATA / "fireos" / "packages.txt")) | set(entries(DATA / "fireos6" / "packages.txt"))
        for app in ("com.amazon.firetv.youtube", "com.netflix.ninja", "com.amazon.avod",
                    "com.amazon.firebat", "com.amazon.cloud9", "com.amazon.bueller.music",
                    "com.amazon.minitv.android.app", "com.amazon.ftv.screensaver",
                    "com.amazon.tv.livetv", "com.ivona.tts.oem", "com.amazon.tahoe",
                    "com.amazon.spiderpork"):
            self.assertNotIn(app, cleanup)


if __name__ == "__main__":
    unittest.main()
