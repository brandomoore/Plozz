"""Offline symbol-upload checks; never contact Sentry or inspect real archives."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.parse
from unittest.mock import Mock, patch


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

    @staticmethod
    def server_record(debug_id):
        return {"debugId": debug_id, "symbolType": "macho", "data": {"features": ["debug", "symtab", "unwind"]}}

    def server_response(self, request, timeout):
        debug_id = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["debug_id"][0]
        return io.BytesIO(json.dumps([self.server_record(debug_id)]).encode())

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
        opener = Mock()
        opener.open.side_effect = self.server_response
        with patch.object(SYMBOLS, "debug_ids", side_effect=self.ids), \
             patch.object(SYMBOLS.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "")) as run, \
             patch.object(SYMBOLS.urllib.request, "build_opener", return_value=opener), \
             contextlib.redirect_stdout(io.StringIO()):
            SYMBOLS.upload(archive, "sentry-cli", self.env)
        command = run.call_args.args[0]
        for option in ("--wait", "--no-sources", "--no-zips"):
            self.assertIn(option, command)
        self.assertNotIn("--require-all", command)
        self.assertNotIn("--include-sources", command)
        self.assertNotIn("private-test-token", command)
        self.assertEqual(command.count("--id"), 2)
        self.assertNotIn("SENTRY_ALLOW_FAILURE", run.call_args.kwargs["env"])
        self.assertTrue(all("/Contents/Resources/DWARF/" in path for path in command[-2:]))
        self.assertEqual(opener.open.call_count, 2)
        for call, debug_id in zip(opener.open.call_args_list, sorted({APP_ID, EXTENSION_ID})):
            request = call.args[0]
            self.assertEqual(request.full_url, "https://sentry.io/api/0/projects/fixture/fixture/files/dsyms/?debug_id=" + debug_id)
            self.assertEqual(request.get_header("Authorization"), "Bearer private-test-token")
            self.assertEqual(call.kwargs["timeout"], 30)

    def testAlreadyUploadedDependenciesStillRequireEveryServerUuid(self):
        archive = self.archive()
        dependency_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        opener = Mock()
        opener.open.side_effect = self.server_response
        with patch.object(SYMBOLS, "archive_symbols", return_value=(
                 [archive / "dSYMs/dependency"], {APP_ID, EXTENSION_ID, dependency_id}
             )), patch.object(SYMBOLS.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, "Nothing to upload, all files are on the server"
             )), patch.object(SYMBOLS.urllib.request, "build_opener", return_value=opener), \
             contextlib.redirect_stdout(io.StringIO()):
            SYMBOLS.upload(archive, "sentry-cli", self.env)
        self.assertEqual(opener.open.call_count, 3)

    def testSuccessfulCliCannotHideMissingOrUnprocessedSymbols(self):
        archive = self.archive()
        for rows in (
            [], [self.server_record(EXTENSION_ID)],
            [{"debugId": APP_ID, "symbolType": "macho", "data": {"features": ["symtab", "unwind"]}}],
            [None], [{"debugId": APP_ID, "symbolType": "macho", "data": None}],
            {"error": "private-test-token"},
        ):
            with self.subTest(rows=rows):
                opener = Mock()
                opener.open.side_effect = lambda *args, **kwargs: io.BytesIO(json.dumps(rows).encode())
                with patch.object(SYMBOLS, "debug_ids", side_effect=self.ids), \
                     patch.object(SYMBOLS.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "")), \
                     patch.object(SYMBOLS.urllib.request, "build_opener", return_value=opener), \
                     contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(ValueError, "must not proceed") as raised:
                        SYMBOLS.upload(archive, "sentry-cli", self.env)
                self.assertNotIn("private-test-token", str(raised.exception))

    def testServerErrorsFailClosedWithoutPrintingSensitiveResponses(self):
        for error in (
            urllib.error.HTTPError("https://sentry.io", 403, "private-test-token", {}, None),
            urllib.error.URLError("private-test-token"),
            TimeoutError("private-test-token"),
        ):
            with self.subTest(error=type(error)):
                opener = Mock()
                opener.open.side_effect = error
                with patch.object(SYMBOLS.urllib.request, "build_opener", return_value=opener):
                    with self.assertRaisesRegex(ValueError, "must not proceed") as raised:
                        SYMBOLS.verify_processed_symbols({APP_ID}, self.env)
                self.assertNotIn("private-test-token", str(raised.exception))
        opener = Mock()
        opener.open.return_value = io.BytesIO(b"private-test-token, not JSON")
        with patch.object(SYMBOLS.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(ValueError, "must not proceed") as raised:
                SYMBOLS.verify_processed_symbols({APP_ID}, self.env)
        self.assertNotIn("private-test-token", str(raised.exception))

    def testApiNeverForwardsCredentialsToRedirectsOrUnsafeUrls(self):
        self.assertIsNone(SYMBOLS.NoRedirect().redirect_request(None, None, 302, "", {}, "https://foreign.example"))
        for url in ("http://sentry.io", "https://user:password@sentry.io", "https://sentry.io?token=value",
                    "https://sentry.io#fragment", "https:///missing-host"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                SYMBOLS.symbol_api_url({**self.env, "SENTRY_URL": url})
        self.assertEqual(SYMBOLS.symbol_api_url({
            **self.env, "SENTRY_URL": "https://self-hosted.example/sentry/",
            "SENTRY_ORG": "org/name", "SENTRY_PROJECT": "project/name",
        }), "https://self-hosted.example/sentry/api/0/projects/org%2Fname/project%2Fname/files/dsyms/")

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
