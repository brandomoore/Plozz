"""Offline symbol-upload checks; never contact Sentry or inspect real archives."""

import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("sentry_symbols", ROOT / "tools/upload-sentry-symbols.py")
SYMBOLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYMBOLS)
APP_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
EXTENSION_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"


class SentrySymbolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {
            "HOME": str(self.root), "PATH": "/fixture",
            "SENTRY_AUTH_TOKEN": "private-test-token", "SENTRY_ORG": "fixture",
            "SENTRY_PROJECT": "fixture", "SENTRY_ALLOW_FAILURE": "1",
        }

    def archive(self):
        archive = self.root / "Plozz.xcarchive"
        app = archive / "Products/Applications/Plozz.app"
        extension = app / "PlugIns/PlozzTopShelf.appex"
        for bundle, executable in [(app, "Plozz"), (extension, "PlozzTopShelf")]:
            bundle.mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": executable}))
            (bundle / executable).write_bytes(b"fixture")
            dwarf = archive / "dSYMs" / (bundle.name + ".dSYM") / "Contents/Resources/DWARF" / executable
            dwarf.parent.mkdir(parents=True)
            dwarf.write_bytes(b"fixture")
        (archive / "Info.plist").write_bytes(plistlib.dumps({
            "ApplicationProperties": {"ApplicationPath": "Applications/Plozz.app"}
        }))
        return archive

    @staticmethod
    def ids(path):
        return {EXTENSION_ID if path.name == "PlozzTopShelf" else APP_ID}

    def testRequiresPrivateTokenAndCli(self):
        with patch.object(SYMBOLS.shutil, "which", return_value="/fixture/sentry-cli"):
            cli, env = SYMBOLS.configuration(self.env, self.root)
            self.assertEqual(cli, "/fixture/sentry-cli")
            self.assertEqual(env["SENTRY_AUTH_TOKEN"], "private-test-token")
            missing = {k: v for k, v in self.env.items() if k != "SENTRY_AUTH_TOKEN"}
            with self.assertRaisesRegex(ValueError, "SENTRY_AUTH_TOKEN"):
                SYMBOLS.configuration(missing, self.root)
        with patch.object(SYMBOLS.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "Install sentry-cli"):
                SYMBOLS.configuration(self.env, self.root)

    def testPrivateFilePrecedenceAndNoShellExecution(self):
        machine = self.root / ".config/plozz/env"
        machine.parent.mkdir(parents=True)
        machine.write_text("SENTRY_AUTH_TOKEN='machine'\nSENTRY_ORG=machine\nSENTRY_PROJECT=machine\n")
        (self.root / ".env.fastlane").write_text("SENTRY_AUTH_TOKEN='$(not-executed)'\nSENTRY_ORG=worktree\n")
        explicit = self.root / "explicit.env"
        explicit.write_text("SENTRY_ORG=explicit\n")
        env = {"HOME": str(self.root), "PLOZZ_ENV_FILE": str(explicit), "SENTRY_PROJECT": "environment"}
        with patch.object(SYMBOLS.shutil, "which", return_value="sentry-cli"):
            _, config = SYMBOLS.configuration(env, self.root)
        self.assertEqual(config["SENTRY_AUTH_TOKEN"], "$(not-executed)")
        self.assertEqual(config["SENTRY_ORG"], "explicit")
        self.assertEqual(config["SENTRY_PROJECT"], "environment")

    def testChecksEveryAppAndExtensionUuid(self):
        archive = self.archive()
        with patch.object(SYMBOLS, "debug_ids", side_effect=self.ids):
            symbols, ids = SYMBOLS.archive_symbols(archive)
        self.assertEqual(len(symbols), 2)
        self.assertEqual(ids, {APP_ID, EXTENSION_ID})
        with patch.object(SYMBOLS, "debug_ids", side_effect=lambda path: (
            {"cccccccc-cccc-cccc-cccc-cccccccccccc"}
            if "dSYMs" in path.parts else self.ids(path)
        )):
            with self.assertRaisesRegex(ValueError, "do not match"):
                SYMBOLS.archive_symbols(archive)

    def testUploadsOnlyDwarfsAndWaitsForAllUuidsWithoutFailureBypass(self):
        archive = self.archive()
        with patch.object(SYMBOLS, "debug_ids", side_effect=self.ids), \
             patch.object(SYMBOLS.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "")) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            SYMBOLS.upload(archive, "sentry-cli", self.env)
        command = run.call_args.args[0]
        for option in ("--wait", "--require-all", "--no-sources", "--no-zips"):
            self.assertIn(option, command)
        self.assertNotIn("--include-sources", command)
        self.assertNotIn("private-test-token", command)
        self.assertEqual(command.count("--id"), 2)
        self.assertNotIn("SENTRY_ALLOW_FAILURE", run.call_args.kwargs["env"])
        self.assertTrue(all("/Contents/Resources/DWARF/" in path for path in command[-2:]))

    def testProcessingFailureStopsDistributionAndRedactsToken(self):
        archive = self.archive()
        output = io.StringIO()
        with patch.object(SYMBOLS, "debug_ids", side_effect=self.ids), \
             patch.object(SYMBOLS.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 1, "failure private-test-token"
             )), contextlib.redirect_stdout(output):
            with self.assertRaisesRegex(ValueError, "must not proceed"):
                SYMBOLS.upload(archive, "sentry-cli", self.env)
        self.assertNotIn("private-test-token", output.getvalue())

    def testRejectsArchivePathEscapes(self):
        archive = self.archive()
        (archive / "Info.plist").write_bytes(plistlib.dumps({
            "ApplicationProperties": {"ApplicationPath": "../"}
        }))
        with self.assertRaisesRegex(ValueError, "path is invalid"):
            SYMBOLS.archive_symbols(archive)

    def testNoUuidIsNotSuccess(self):
        with patch.object(SYMBOLS.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "")):
            with self.assertRaisesRegex(ValueError, "No debug UUIDs"):
                SYMBOLS.debug_ids(self.root / "empty")


if __name__ == "__main__":
    unittest.main()
