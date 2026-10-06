"""First-run builds must never inherit canonical storage, discovery, or signing."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, call, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("first_run", ROOT / "tools/first-run.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
CASE = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"


class FirstRunTests(unittest.TestCase):
    def fixture(self):
        identity = MODULE.case_identity(CASE)
        app_id = "TEAM." + identity["bundle"]
        info = {
            "CFBundleIdentifier": identity["bundle"],
            "NSBonjourServices": [identity["pairingService"]],
            "CFBundleURLTypes": [{"CFBundleURLSchemes": [identity["urlScheme"]]}],
        }
        signed = MODULE.entitlements(identity, "tvos")
        signed.update({
            "application-identifier": app_id,
            "com.apple.developer.team-identifier": "TEAM",
            "com.apple.developer.ubiquity-kvstore-identifier": app_id,
            "keychain-access-groups": [app_id],
            "get-task-allow": True,
        })
        return identity, info, signed

    def test_requires_exact_uuid_not_a_branch_or_real_app_identifier(self):
        for case in ["", "main", "com.thatcube.Plozz", CASE.upper(), CASE + ".extra"]:
            with self.subTest(case=case), self.assertRaises(ValueError):
                MODULE.case_identity(case)
        self.assertEqual(MODULE.case_identity(CASE)["bundle"], MODULE.PREFIX + CASE)

    def test_signed_lab_identity_retains_real_cloud_and_tv_household_capabilities(self):
        identity, info, signed = self.fixture()
        MODULE.verify_identity(info, signed, identity, "tvos")
        self.assertNotIn("com.apple.security.application-groups", signed)
        self.assertNotIn("com.apple.developer.associated-domains", signed)
        self.assertLessEqual(len(identity["pairingService"].split(".")[0].lstrip("_")), 15)
        self.assertNotIn("com.apple.developer.user-management", MODULE.entitlements(identity, "ios"))

    def test_wrong_or_shared_signing_capabilities_fail_closed(self):
        identity, info, signed = self.fixture()
        invalid = {
            "application-identifier": "TEAM.com.thatcube.Plozz",
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.thatcube.Plozz"],
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.icloud-services": [],
            "com.apple.developer.ubiquity-kvstore-identifier": "TEAM.com.thatcube.Plozz",
            "keychain-access-groups": ["TEAM.com.thatcube.Plozz"],
            "com.apple.security.application-groups": ["group.com.thatcube.Plozz"],
            "com.apple.developer.associated-domains": ["applinks:plozz.app"],
            "com.apple.developer.user-management": [],
            "get-task-allow": False,
        }
        for key, value in invalid.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                MODULE.verify_identity(info, {**signed, key: value}, identity, "tvos")
        with self.assertRaises(ValueError):
            MODULE.verify_identity(info, {**signed, "com.apple.developer.icloud-container-identifiers": [
                MODULE.CONTAINER, "iCloud.com.thatcube.Plozz",
            ]}, identity, "tvos")

    def test_normal_app_and_pairing_routes_cannot_be_installed_as_a_test(self):
        identity, info, signed = self.fixture()
        variants = [
            {**info, "CFBundleIdentifier": "com.thatcube.Plozz"},
            {**info, "NSBonjourServices": [identity["pairingService"], "_plozz-pair._tcp"]},
            {**info, "CFBundleURLTypes": [{"CFBundleURLSchemes": ["plozz"]}]},
        ]
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                MODULE.verify_identity(variant, signed, identity, "tvos")

    def test_provisioning_config_is_parsed_as_data_not_executed(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(MODULE, "ROOT", Path(directory)):
            root = Path(directory)
            key = root / "fixture.p8"
            key.write_text("fixture-not-a-key")
            (root / ".env.fastlane").write_text(
                f'ASC_KEY_PATH="{key}"\nASC_KEY_ID=fixture\nASC_ISSUER_ID=fixture-issuer\n'
                'UNRELATED=$(touch SHOULD_NOT_EXIST)\n'
            )
            result = MODULE.signing_arguments({})
            self.assertEqual(result[result.index("-authenticationKeyPath") + 1], str(key))
            self.assertFalse((root / "SHOULD_NOT_EXIST").exists())
            with self.assertRaises(ValueError):
                MODULE.signing_arguments({"ASC_KEY_PATH": str(root / "missing")})

    def test_timeout_stops_owned_descendants_even_when_parent_exits_after_term(self):
        process = MagicMock()
        process.__enter__.return_value = process
        process.pid = 424242
        process.communicate.side_effect = [
            subprocess.TimeoutExpired(["fixture"], 1), (None, None), (None, None),
        ]
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(MODULE.runpy, "run_path", return_value={"inherited_lease_fds": lambda: ()}), \
                patch.object(MODULE.subprocess, "Popen", return_value=process), \
                patch.object(MODULE.os, "killpg") as killpg:
            with self.assertRaises(subprocess.TimeoutExpired):
                MODULE.command(["fixture"], os.environ.copy(), timeout=1, output=Path(directory) / "build.log")
        self.assertEqual(killpg.call_args_list, [
            call(process.pid, signal.SIGTERM), call(process.pid, signal.SIGKILL),
        ])
        self.assertEqual(process.communicate.call_count, 3)


if __name__ == "__main__":
    unittest.main()
