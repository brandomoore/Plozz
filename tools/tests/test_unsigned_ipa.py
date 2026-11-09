#!/usr/bin/env python3
"""Unsigned packaging isolation, identity, and embedded-binary regression tests."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("unsigned_ipa", ROOT / "tools/build-unsigned-ipa.py")
ipa = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ipa)


class UnsignedIPATests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="unsigned-tests-", dir=ROOT / ".build")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def info(self, platform="ios", extension=False):
        return {
            "CFBundleIdentifier": "com.thatcube.Plozz.selfbuild" + (".TopShelf" if extension else ""),
            "CFBundleExecutable": "TopShelf" if extension else "Plozz",
            "CFBundleSupportedPlatforms": [ipa.PLATFORMS[platform][2]],
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "123",
        }

    def test_snapshot_copies_working_edits_not_ignored_secrets(self):
        source = self.root / "source"
        source.mkdir()
        (source / "tracked").write_text("current working edit")
        (source / ".env.fastlane").write_text("DO_NOT_COPY=private")
        output = self.root / "snapshot"
        digest = ipa.snapshot(source, output, ["tracked", "deleted"])
        self.assertEqual((output / "tracked").read_text(), "current working edit")
        self.assertFalse((output / ".env.fastlane").exists())
        self.assertEqual(len(digest), 64)
        (source / "tracked").write_text("different")
        self.assertNotEqual(digest, ipa.snapshot(source, output, ["tracked"]))

    def test_snapshot_rejects_symlink_and_path_escape(self):
        (self.root / "outside").write_text("private")
        (self.root / "link").symlink_to(self.root / "outside")
        for path in ["link", "../outside", "/absolute"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                ipa.snapshot(self.root, self.root / "snapshot", [path])
        (self.root / "directory").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            ipa.snapshot(self.root, self.root / "snapshot", ["directory/outside"])

    def test_environment_drops_private_and_release_overrides(self):
        parent = dict(os.environ, PLOZZ_SENTRY_DSN="private", PLOZZ_ENV_FILE="private",
                      PLOZZ_RELEASE_ID="release/123", PLOZZ_RELEASE_CHANNEL="testflight",
                      PLOZZ_ID_SUFFIX=".official", XCODE_XCCONFIG_FILE="private",
                      TMDB_BEARER_TOKEN="private", GH_TOKEN="private",
                      APPLE_BUILD_LEASE_ID="owned")
        env = ipa.build_environment(parent, self.root, "123")
        for key in ["PLOZZ_SENTRY_DSN", "PLOZZ_ENV_FILE", "PLOZZ_RELEASE_ID",
                    "PLOZZ_RELEASE_CHANNEL", "XCODE_XCCONFIG_FILE", "TMDB_BEARER_TOKEN", "GH_TOKEN"]:
            self.assertNotIn(key, env)
        self.assertEqual(env["APPLE_BUILD_LEASE_ID"], "owned")
        self.assertEqual(env["PLOZZ_ID_SUFFIX"], ".selfbuild")
        self.assertEqual(env["XDG_CONFIG_HOME"], str(self.root / ".empty-config"))
        self.assertEqual(env["PLOZZ_BUILD_NUMBER"], "123")

    def test_command_failure_and_timeout_are_not_success(self):
        log = self.root / "failed.log"
        with self.assertRaisesRegex(RuntimeError, "failed \\(3\\)"):
            ipa.command(
                [ipa.sys.executable, "-c", "print('fixture failure'); raise SystemExit(3)"],
                cwd=self.root, env=os.environ, log=log,
            )
        self.assertIn("fixture failure", log.read_text())
        with self.assertRaises(subprocess.TimeoutExpired):
            ipa.command(
                [ipa.sys.executable, "-c", "import time; time.sleep(60)"],
                cwd=self.root, env=os.environ, timeout=0.1,
            )

    def test_public_config_blocks_automatic_secret_linking(self):
        (self.root / "Config").mkdir()
        defaults = self.root / "Config/Secrets.xcconfig"
        defaults.write_text('API_KEY =\n#include? "Secrets.local.xcconfig"\n')
        ipa.prepare_public_config(self.root)
        private = self.root / "Config/Secrets.local.xcconfig"
        self.assertTrue(private.is_file())
        self.assertFalse(private.is_symlink())
        with self.assertRaises(ValueError):
            ipa.prepare_public_config(self.root)
        private.unlink()
        defaults.write_text("API_KEY = accidentally-committed\n")
        with self.assertRaises(ValueError):
            ipa.prepare_public_config(self.root)

    def test_info_rejects_credentials_official_identity_and_wrong_platform(self):
        for key in ipa.EMPTY_INFO_KEYS:
            for value in ["private", "$(UNRESOLVED)"]:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    ipa.verify_info(dict(self.info(), **{key: value}), "ios")
        with self.assertRaises(ValueError):
            ipa.verify_info(dict(self.info(), CFBundleIdentifier="com.thatcube.Plozz"), "ios")
        with self.assertRaises(ValueError):
            ipa.verify_info(self.info("tvos"), "ios")
        with self.assertRaises(ValueError):
            ipa.verify_info(self.info("tvos", True), "tvos", extension=True, app_version=("1", "2"))
        self.assertEqual(ipa.verify_info(self.info(), "ios"), ("1.0", "123"))

    def make_app(self, platform="ios"):
        app = self.root / "Plozz.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps(self.info(platform)))
        (app / "Plozz").write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
        framework = app / "Frameworks/AetherEngine.framework"
        framework.mkdir(parents=True)
        (framework / "AetherEngine").write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
        if platform == "tvos":
            extension = app / "PlugIns/TopShelf.appex"
            extension.mkdir(parents=True)
            (extension / "Info.plist").write_bytes(plistlib.dumps(self.info(platform, True)))
            (extension / "TopShelf").write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
        return app

    def fake_run(self, *, platform="IOS", archs="arm64", link=None, signature=False):
        def run(args):
            if args[:3] == ["xcrun", "lipo", "-archs"]:
                return archs
            if args[:3] == ["xcrun", "vtool", "-show-build"]:
                return f"    platform {platform}\n" * len(archs.split())
            if args[:3] == ["xcrun", "otool", "-L"]:
                dependency = link or "@rpath/AetherEngine.framework/AetherEngine"
                return f"binary:\n\t{dependency} (compatibility version 1.0)\n"
            if args[:3] == ["xcrun", "otool", "-l"]:
                return "LC_CODE_SIGNATURE" if signature else "LC_BUILD_VERSION"
            if args[:2] == ["codesign", "--remove-signature"]:
                return ""
            self.fail(f"Unexpected command: {args}")
        return run

    def test_binary_verification_covers_device_architecture_links_and_signatures(self):
        app = self.make_app()
        receipt = ipa.verify_and_unsign(app, "ios", self.fake_run())
        self.assertEqual(len(receipt["binaries"]), 2)
        for arguments in [
            {"platform": "IOSSIMULATOR"}, {"archs": "arm64 x86_64"},
            {"link": "@rpath/Missing.framework/Missing"}, {"link": "/private/build/lib.dylib"},
            {"signature": True},
        ]:
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                ipa.verify_and_unsign(app, "ios", self.fake_run(**arguments))
        (app / "embedded.mobileprovision").write_bytes(b"private")
        with self.assertRaises(ValueError):
            ipa.verify_and_unsign(app, "ios", self.fake_run())

    def test_tvos_requires_matching_extension(self):
        app = self.make_app("tvos")
        receipt = ipa.verify_and_unsign(app, "tvos", self.fake_run(platform="TVOS"))
        self.assertEqual(len(receipt["binaries"]), 3)
        (app / "PlugIns/TopShelf.appex/TopShelf").unlink()
        with self.assertRaises(ValueError):
            ipa.verify_and_unsign(app, "tvos", self.fake_run(platform="TVOS"))

    def test_embedded_swift_runtime_is_resolved_as_a_dylib(self):
        app = self.make_app()
        link = "@rpath/libswiftCompatibilitySpan.dylib"
        with self.assertRaises(ValueError):
            ipa.verify_and_unsign(app, "ios", self.fake_run(link=link))
        (app / "Frameworks/libswiftCompatibilitySpan.dylib").write_bytes(b"\xcf\xfa\xed\xfe")
        self.assertEqual(len(ipa.verify_and_unsign(
            app, "ios", self.fake_run(link=link, archs="arm64 arm64e")
        )["binaries"]), 3)

    def test_workflow_runs_on_published_releases_and_uploads_only_exact_outputs(self):
        workflow = (ROOT / ".github/workflows/unsigned-ipa.yml").read_text()
        self.assertIn("release:\n    types: [published]", workflow)
        self.assertNotIn("workflow_dispatch:", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertNotIn("inputs.", workflow)
        self.assertNotIn("release_tag:", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn("runs-on: xcode-27", workflow)
        self.assertIn("platform: [ios, tvos]", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("${{ steps.build.outputs.ipa_path }}", workflow)
        self.assertIn("${{ steps.build.outputs.receipt_path }}", workflow)

    def test_workflow_always_attaches_unsigned_ipas_to_the_published_release(self):
        workflow = (ROOT / ".github/workflows/unsigned-ipa.yml").read_text()
        self.assertIn("RELEASE_TAG: ${{ github.event.release.tag_name }}", workflow)
        self.assertIn("permissions:\n      contents: write", workflow)
        self.assertIn("gh release upload \"$RELEASE_TAG\" \"${ipas[@]}\" --clobber", workflow)
        self.assertIn("find dist -type f -name '*.ipa'", workflow)
        self.assertIn("gh release view \"$RELEASE_TAG\"", workflow)

    def test_build_uses_snapshot_locked_packages_and_verified_payload(self):
        repository = self.root / "repository"
        (repository / "Config").mkdir(parents=True)
        (repository / "Config/Secrets.xcconfig").write_text("API_KEY =\n")
        (repository / "Package.resolved").write_text("{}")
        (repository / "untracked-secret").write_text("must not copy")
        template = self.make_app()
        calls = []

        def fake_command(args, *, cwd, env, **kwargs):
            calls.append(args)
            if args[:2] == ["git", "ls-files"]:
                return "Config/Secrets.xcconfig\0Package.resolved\0"
            if args[:2] == ["git", "rev-parse"]:
                return "source-revision\n"
            if args[:2] == ["git", "status"]:
                return " M staged-change\n"
            if args[:2] == ["git", "rev-list"]:
                return "123\n"
            self.assertNotIn("PLOZZ_SENTRY_DSN", env)
            if args == ["xcodebuild", "-version"]:
                return "Xcode 27.0\n"
            if args == ["tools/generate-project.sh"]:
                self.assertTrue((cwd / "Config/Secrets.local.xcconfig").is_file())
                self.assertFalse((cwd / "untracked-secret").exists())
                return ""
            if args[0] == "/bin/bash":
                self.assertIn("configure_plozz_package_resolution", args[2])
                return "-clonedSourcePackagesDirPath\0" + args[-1] + "\0"
            if args[0] == "xcodebuild":
                self.assertIn("CODE_SIGNING_ALLOWED=NO", args)
                self.assertIn("DEVELOPMENT_TEAM=", args)
                self.assertIn("-clonedSourcePackagesDirPath", args)
                derived = Path(args[args.index("-derivedDataPath") + 1])
                app = derived / "Build/Products/Release-iphoneos/Plozz.app"
                if args[-1] == "build":
                    shutil.copytree(template, app)
                    return ""
                self.assertEqual(args[-2:], ["-showBuildSettings", "-json"])
                return ipa.json.dumps([{"target": "PlozziOS", "buildSettings": {
                    "TARGET_BUILD_DIR": str(app.parent), "FULL_PRODUCT_NAME": app.name,
                }}])
            if args[:2] == ["ditto", "-c"]:
                payload, output = map(Path, args[-2:])
                with zipfile.ZipFile(output, "w") as archive:
                    for path in payload.rglob("*"):
                        if path.is_file():
                            archive.write(path, path.relative_to(payload.parent))
                return ""
            if args[0] == "ditto":
                shutil.copytree(args[1], args[2])
                return ""
            return self.fake_run()(args)

        github_output = self.root / "github-output"
        with patch.object(ipa, "command", side_effect=fake_command), \
                patch.dict(os.environ, GITHUB_OUTPUT=str(github_output)):
            ipa.build("ios", repository, dict(os.environ, PLOZZ_SENTRY_DSN="private"), ())
        evidence, = (repository / ".build/unsigned-ipa/ios").iterdir()
        receipt = ipa.json.loads((evidence / "receipt.json").read_text())
        self.assertFalse(receipt["signed"])
        self.assertTrue(receipt["workingTreeModified"])
        self.assertEqual(receipt["sourceRevision"], "source-revision")
        self.assertEqual(len(receipt["ipaSHA256"]), 64)
        self.assertIn("ipa_path=", github_output.read_text())
        self.assertTrue((evidence / "Plozz-ios-unsigned.ipa").is_file())
        self.assertNotIn("install", [arg for args in calls for arg in args])


if __name__ == "__main__":
    unittest.main()
