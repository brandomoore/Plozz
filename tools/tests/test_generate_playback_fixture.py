import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("playback_fixture", ROOT / "tools/generate-playback-fixture.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PlaybackFixtureTests(unittest.TestCase):
    def testExistingProviderFixtureKeepsItsDurationAndResolution(self):
        command = MODULE.command(Path("video.mp4"))
        self.assertIn("testsrc2=size=1920x1080:rate=24", command)
        self.assertEqual(command[command.index("-t") + 1], "90")
        self.assertIn("-n", command)

    def testOfflineFixtureHasTwoDistinctTaggedAudioInputs(self):
        command = MODULE.command(Path("media.mp4"), offline_downloads=True)
        self.assertEqual(command[command.index("-t") + 1], "24")
        self.assertIn("sine=frequency=440:sample_rate=48000", command)
        self.assertIn("sine=frequency=880:sample_rate=48000", command)
        self.assertIn("language=eng", command)
        self.assertIn("language=fra", command)
        self.assertEqual([command[i + 1] for i, value in enumerate(command) if value == "-map"],
                         ["0:v", "1:a", "2:a"])

    def testOfflineFixtureRefusesToOverwriteCompanion(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            companion = root / "alternate.m4a"
            companion.write_bytes(b"existing fixture")
            with patch("sys.argv", ["fixture", "--offline-downloads", "--output", str(root / "media.mp4")]), \
                    patch.object(MODULE.subprocess, "run") as run:
                with self.assertRaises(SystemExit) as result:
                    MODULE.main()
                self.assertEqual(result.exception.code, 2)
                run.assert_not_called()
            self.assertEqual(companion.read_bytes(), b"existing fixture")


if __name__ == "__main__":
    unittest.main()
