import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, MagicMock
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("playback_runner", ROOT / "tools/run-provider-playback-tests.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ProviderPlaybackRunnerTests(unittest.TestCase):
    def fixture(self, folder):
        token = folder / "token"
        token.write_text("private-test-token")
        token.chmod(0o600)
        config = folder / "config.json"
        data = {
            "startupTimeoutSeconds": 45, "playbackSeconds": 10, "seekSeconds": 30, "resumeSeconds": 12,
            "servers": {"emby": {
                "baseURL": "http://127.0.0.1:8096", "serverID": "fixture", "userID": "fixture",
                "itemID": "fixture", "tokenKeychainService": "PlozzPlaybackTests",
                "tokenKeychainAccount": "emby", "codecs": ["h264"],
            }},
        }
        config.write_text(json.dumps(data))
        config.chmod(0o600)
        return config, token, data

    def test_missing_required_server_cannot_be_a_partial_green(self):
        with tempfile.TemporaryDirectory() as directory:
            path, _, _ = self.fixture(Path(directory))
            self.assertEqual(runner.validate_config(path, ["emby"])[0], path.resolve())
            with self.assertRaises(runner.ConfigurationError):
                runner.validate_config(path, ["emby", "plex", "jellyfin"])

    def test_config_and_credentials_must_be_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path, token, _ = self.fixture(Path(directory))
            token.chmod(0o644)
            with self.assertRaises(runner.ConfigurationError):
                runner.private_file(token)
            token.chmod(0o600)
            path.chmod(0o644)
            with self.assertRaises(runner.ConfigurationError):
                runner.validate_config(path, ["emby"])

    def test_silo_h264_is_supported_but_hevc_and_shares_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path, _, data = self.fixture(Path(directory))
            data["servers"]["silo"] = data["servers"].pop("emby")
            path.write_text(json.dumps(data))
            runner.validate_config(path, ["silo"])
            data["servers"]["silo"]["codecs"] = ["hevc"]
            path.write_text(json.dumps(data))
            with self.assertRaises(runner.ConfigurationError):
                runner.validate_config(path, ["silo"])
            data["servers"]["mediaShare"] = data["servers"].pop("silo")
            path.write_text(json.dumps(data))
            with self.assertRaises(runner.ConfigurationError):
                runner.validate_config(path, ["mediaShare"])

    def test_silo_legacy_server_codec_alias_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            path, _, data = self.fixture(Path(directory))
            silo = data["servers"].pop("emby")
            silo["codecs"] = ["server"]
            data["servers"]["silo"] = silo
            path.write_text(json.dumps(data))
            self.assertEqual(runner.validate_config(path, ["silo"])[1]["servers"]["silo"]["codecs"], ["server"])

    def test_no_credential_bearing_endpoint_or_invalid_codec(self):
        with tempfile.TemporaryDirectory() as directory:
            path, _, data = self.fixture(Path(directory))
            for url in ("http://u:secret@127.0.0.1", "file:///tmp/video", "https://server.test/?token=secret"):
                data["servers"]["emby"]["baseURL"] = url
                path.write_text(json.dumps(data))
                with self.assertRaises(runner.ConfigurationError):
                    runner.validate_config(path, ["emby"])

    def test_scheme_contains_paths_not_tokens_and_valid_xml(self):
        xml = runner.scheme_xml("/private/a&b/config.json", "/private/run/leases")
        root = ElementTree.fromstring(xml)
        values = [e.attrib["value"] for e in root.findall(".//EnvironmentVariable")]
        self.assertIn("/private/a&b/config.json", values)
        self.assertNotIn("private-test-token", xml)
        self.assertNotIn("PLOZZ_PLAYBACK_E2E_CONFIG", runner.scheme_xml(None, "/unused"))

    def test_crashes_skips_and_missing_cases_are_never_passes(self):
        summary = dict(result="Passed", failedTests=0, skippedTests=0, expectedFailures=0, passedTests=3, totalTestCount=3)
        self.assertTrue(runner.verified(summary, 3))
        for field, value in [("result", "Failed"), ("failedTests", 1), ("skippedTests", 1),
                             ("expectedFailures", 1), ("passedTests", 2), ("totalTestCount", 4)]:
            with self.subTest(field=field):
                self.assertFalse(runner.verified(dict(summary, **{field: value}), 3))
        self.assertFalse(runner.verified({}, 3))

    def test_keychain_tokens_are_staged_privately_and_never_embedded_in_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, _, config = self.fixture(root)
            staged_path, staged = runner.stage_credentials(config, root, lambda service, account: b"test-secret")
            token = Path(staged["servers"]["emby"]["tokenFile"])
            self.assertEqual(token.read_bytes(), b"test-secret")
            self.assertEqual(token.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("test-secret", staged_path.read_text())

    def test_cleanup_uses_only_the_owned_session_and_device_with_token_in_header(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, _, config = self.fixture(root)
            _, staged = runner.stage_credentials(config, root, lambda *_: b"test-secret")
            leases = root / "leases"
            leases.mkdir()
            lease = leases / "one.json"
            value = dict(provider="emby", sessionID="owned-session", deviceID="plozz-playback-test-owned",
                         serverID="fixture", userID="fixture", baseURL="http://127.0.0.1:8096")
            lease.write_text(json.dumps(value))
            response = MagicMock()
            response.__enter__.return_value.status = 204
            with patch.object(runner.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                result = runner.cleanup_owned(leases, staged)
                request = opener.return_value.open.call_args.args[0]
                self.assertEqual(request.get_method(), "DELETE")
                self.assertIn("playSessionId=owned-session", request.full_url)
                self.assertIn("deviceId=plozz-playback-test-owned", request.full_url)
                self.assertNotIn("test-secret", request.full_url)
                self.assertEqual(request.get_header("X-emby-token"), "test-secret")
            self.assertEqual(result, [{"provider": "emby", "status": "acknowledged"}])
            self.assertFalse(lease.exists())

            value["serverID"] = "another-server"
            lease.write_text(json.dumps(value))
            with patch.object(runner.urllib.request, "build_opener") as opener:
                result = runner.cleanup_owned(leases, staged)
                opener.assert_not_called()
            self.assertEqual(result[0]["status"], "failed")
            self.assertTrue(lease.exists())

    def test_silo_cleanup_uses_native_installation_and_idempotent_stop_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, _, config = self.fixture(root)
            server = config["servers"].pop("emby")
            server["codecs"] = ["server"]
            config["servers"]["silo"] = server
            credential = json.dumps({
                "accessToken": "silo-test-bearer", "profileID": "profile",
                "profileToken": "silo-test-proof", "expiresAt": 4102444800 - 978307200
            }).encode()
            _, staged = runner.stage_credentials(config, root, lambda *_: credential)
            leases = root / "leases"
            leases.mkdir()
            lease = leases / "owned.json"
            lease.write_text(json.dumps({
                "provider": "silo", "sessionID": "owned/session", "deviceID": "plozz-playback-test-owned",
                "serverID": "fixture", "userID": "fixture", "baseURL": "http://127.0.0.1:8096",
                "installationID": "installation", "stopID": "stop",
            }))
            response = MagicMock()
            response.__enter__.return_value.status = 200
            response.__enter__.return_value.read.return_value = b'{"outcome":"stopped"}'
            with patch.object(runner.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                result = runner.cleanup_owned(leases, staged)
                request = opener.return_value.open.call_args.args[0]
                self.assertIn("/api/v2/playback/owned%2Fsession", request.full_url)
                self.assertNotIn("silo-test", request.full_url)
                self.assertEqual(json.loads(request.data), {"installation_id": "installation", "stop_id": "stop"})
                self.assertEqual(request.get_header("Authorization"), "Bearer silo-test-bearer")
                self.assertEqual(request.get_header("X-profile-id"), "profile")
            self.assertEqual(result, [{"provider": "silo", "status": "acknowledged"}])
            self.assertFalse(lease.exists())


if __name__ == "__main__":
    unittest.main()
