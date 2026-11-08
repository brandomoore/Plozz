import importlib.util
from pathlib import Path
import tempfile
import unittest
import plistlib
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "disc_artifact", Path(__file__).resolve().parents[1] / "validate-disc-runtime.py")
ARTIFACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ARTIFACT)


class DiscArtifactTests(unittest.TestCase):
    def test_native_device_app_does_not_require_a_java_runtime(self):
        for platform, load_command in (("iPhoneOS", "IOS"), ("AppleTVOS", "TVOS")):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                app = Path(directory)
                (app / "App").write_bytes(b"\xcf\xfa\xed\xfe")
                (app / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleExecutable": "App", "CFBundleSupportedPlatforms": [platform]
                }))
                def command(*args):
                    if args[0] == "lipo": return "arm64"
                    if args[:2] == ("otool", "-l"): return f"  platform {load_command}\n"
                    if args[:2] == ("otool", "-L"): return "App:\n /usr/lib/libSystem.B.dylib (version 1)\n"
                    if args[:2] == ("nm", "-g"): return "000 T _bdj_open\n"
                    if args[:2] == ("nm", "-u"): return " U _malloc\n"
                    if args[:4] == ("codesign", "--verify", "--deep", "--strict"): return ""
                    self.fail(f"Unexpected validation command: {args}")
                with patch.object(ARTIFACT, "command", side_effect=command):
                    self.assertEqual(ARTIFACT.validate(app), 1)

    def test_distribution_rejects_java_anywhere_including_extensions(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            ARTIFACT.validate_no_java(app)
            for name in ("DiscRuntime", "Frameworks/PlozzBDJjvm.framework",
                         "PlugIns/Shelf.appex/DiscRuntime",
                         "Resources/renamed.jar", "Resources/Menu.class", "Resources/java.base.jmod",
                         "Frameworks/libjvm.dylib"):
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture")
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "prohibited"):
                    ARTIFACT.validate_no_java(app)
                path.unlink()

    def test_java_symbol_scan_includes_exports_and_imports_not_generic_disc_stubs(self):
        self.assertEqual(ARTIFACT.java_symbols(
            " U _JNI_CreateJavaVM\n000 T _JVM_FindClass\n000 T _Java_org_videolan_test\n"
            "000 T _bdj_open\n000 T _some_Java_title\n"),
            ["_JNI_CreateJavaVM", "_JVM_FindClass", "_Java_org_videolan_test"])

    def test_import_scan_matches_exact_symbols_not_substrings(self):
        self.assertEqual(ARTIFACT.process_imports(" U _posix_spawnp\n U _fork\n U _fork_reader\n"),
                         ["_fork", "_posix_spawnp"])

    def test_dependency_resolution_rejects_missing_external_and_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "App.app"
            framework = app / "Frameworks/Example.framework"
            framework.mkdir(parents=True)
            binary = framework / "Example"
            binary.write_bytes(b"fixture")
            self.assertEqual(ARTIFACT.dependency_path("@rpath/Example.framework/Example", binary, app), binary.resolve())
            self.assertIsNone(ARTIFACT.dependency_path("/usr/lib/libSystem.B.dylib", binary, app))
            for invalid in ("@rpath/Missing.framework/Missing", "/tmp/libjava.dylib",
                            "@loader_path/../../../outside", "@rpath/../../outside"):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    ARTIFACT.dependency_path(invalid, binary, app)

    def test_swift_system_library_exception_is_narrow(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            self.assertIsNone(ARTIFACT.dependency_path("@rpath/libswiftCore.dylib", app / "App", app))
            with self.assertRaises(ValueError):
                ARTIFACT.dependency_path("@rpath/libjava.dylib", app / "App", app)
            with self.assertRaises(ValueError):
                ARTIFACT.dependency_path("@rpath/unknown/libswiftCore.dylib", app / "App", app)

    def test_os_versions_are_normalized_and_validated(self):
        self.assertEqual(ARTIFACT.os_version("18"), ARTIFACT.os_version("18.0.0"))
        self.assertLess(ARTIFACT.os_version("18.0"), ARTIFACT.os_version("18.1"))
        for value in ("", "18.beta", "-1", "18.0.0.1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                ARTIFACT.os_version(value)

    def test_executable_paths_cannot_escape_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ("../App", "/tmp/App", "", ".", ".."):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    ARTIFACT.bundle_executable(Path(directory), {"CFBundleExecutable": name})

    def test_extensions_are_scanned_and_versions_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "App.app"
            extension = app / "PlugIns/Shelf.appex"
            extension.mkdir(parents=True)
            info = {"CFBundleExecutable": "App", "CFBundleVersion": "1",
                    "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "18.0",
                    "CFBundleSupportedPlatforms": ["AppleTVOS"]}
            (app / "App").write_bytes(b"\xcf\xfa\xed\xfe")
            (extension / "Shelf").write_bytes(b"\xcf\xfa\xed\xfe")
            extension_info = {**info, "CFBundleExecutable": "Shelf"}
            (extension / "Info.plist").write_bytes(plistlib.dumps(extension_info))
            self.assertEqual(ARTIFACT.bundled_binaries(app, info),
                             [(app / "App", app), (extension / "Shelf", extension)])
            extension_info["CFBundleVersion"] = "2"
            (extension / "Info.plist").write_bytes(plistlib.dumps(extension_info))
            with self.assertRaisesRegex(ValueError, "version differs"):
                ARTIFACT.bundled_binaries(app, info)

    def test_unlisted_native_code_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / "App").write_bytes(b"\xcf\xfa\xed\xfe")
            (app / "hidden").write_bytes(b"\xcf\xfa\xed\xfe")
            with self.assertRaisesRegex(ValueError, "Unexpected native"):
                ARTIFACT.bundled_binaries(app, {"CFBundleExecutable": "App",
                                               "CFBundleSupportedPlatforms": ["AppleTVOS"]})

    def test_extension_dependencies_use_own_executable_root(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "App.app"
            extension = app / "PlugIns/Shelf.appex"
            framework = extension / "Frameworks/Example.framework"
            framework.mkdir(parents=True)
            binary = framework / "Example"
            binary.write_bytes(b"fixture")
            self.assertEqual(ARTIFACT.dependency_path("@executable_path/Frameworks/Example.framework/Example",
                                                    extension / "Shelf", app, extension), binary.resolve())


if __name__ == "__main__":
    unittest.main()
