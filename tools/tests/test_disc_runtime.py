import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("embed_disc_runtime", ROOT / "tools/embed-disc-runtime.py")
EMBED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EMBED)
VALIDATE_SPEC = importlib.util.spec_from_file_location("validate_disc_runtime", ROOT / "tools/validate-disc-runtime.py")
VALIDATE = importlib.util.module_from_spec(VALIDATE_SPEC)
VALIDATE_SPEC.loader.exec_module(VALIDATE)


class DiscRuntimeEmbeddingTests(unittest.TestCase):
    def test_primary_openjdk_legal_texts_are_required_beyond_component_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("java.base", "java.desktop", "libbluray", "asm", "dejavu", "libffi", "openjdk"):
                (root / "legal" / name).mkdir(parents=True)
            names = ("LICENSE", "ADDITIONAL_LICENSE_INFO", "ASSEMBLY_EXCEPTION")
            for name in names:
                (root / "legal/openjdk" / name).write_text("Original test notice")
            VALIDATE.validate_notices(root)
            for name in names:
                path = root / "legal/openjdk" / name
                path.write_text("")
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "primary OpenJDK"):
                    VALIDATE.validate_notices(root)
                path.write_text("Original test notice")

    def test_framework_names_preserve_native_module_identity(self):
        self.assertEqual(EMBED.framework_install_name("libmlib_image.dylib"),
                         "@rpath/PlozzBDJmlib_image.framework/PlozzBDJmlib_image")
        for invalid in ("../libjava.dylib", "java.dylib", "libjava.so", "lib.dylib"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                EMBED.framework_name(invalid)

    def test_framework_embedding_relinks_dependencies_and_signs_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "runtime"
            (source / "lib/zero").mkdir(parents=True)
            (source / "lib/zero/libjvm.dylib").write_bytes(b"jvm")
            (source / "lib/libjava.dylib").write_bytes(b"java")
            def dependencies(command, **_):
                return (f"{command[-1]}:\n"
                        "\t@rpath/libjava.dylib (compatibility version 1.0.0)\n"
                        "\t@rpath/libjvm.dylib (compatibility version 1.0.0)\n"
                        "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n")
            with patch.object(EMBED.subprocess, "check_output", side_effect=dependencies), \
                    patch.object(EMBED.subprocess, "run") as run:
                EMBED.embed_libraries(source, root / "Frameworks", "appletvos", "18.0",
                                      "com.example.player", "identity")
            framework = root / "Frameworks/PlozzBDJjava.framework"
            metadata = plistlib.loads((framework / "Info.plist").read_bytes())
            self.assertEqual(metadata["CFBundleExecutable"], "PlozzBDJjava")
            self.assertEqual(metadata["CFBundleIdentifier"], "com.example.player.bdj.java")
            self.assertEqual(metadata["CFBundleSupportedPlatforms"], ["AppleTVOS"])
            self.assertEqual(metadata["MinimumOSVersion"], "18.0")
            self.assertEqual((framework / "PlozzBDJjava").stat().st_mode & 0o777, 0o755)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertIn(["install_name_tool", "-id", EMBED.framework_install_name("libjava.dylib"),
                           "-change", "@rpath/libjvm.dylib", EMBED.framework_install_name("libjvm.dylib"),
                           str(framework / "PlozzBDJjava")], commands)
            self.assertIn(["codesign", "--force", "--sign", "identity", "--timestamp=none",
                           str(framework)], commands)

    def test_conflicting_native_copies_are_rejected_before_embedding(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "lib/zero").mkdir(parents=True)
            (root / "lib/libjsig.dylib").write_bytes(b"one")
            (root / "lib/zero/libjsig.dylib").write_bytes(b"two")
            with self.assertRaisesRegex(ValueError, "Conflicting"):
                EMBED.embed_libraries(root, root / "Frameworks", "iphoneos", "18.0", "test", None)

    def test_unknown_non_system_dependency_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "lib").mkdir()
            (root / "lib/libjvm.dylib").write_bytes(b"jvm")
            output = "binary:\n\tlibjvm.dylib (version 1)\n\t/elsewhere/libother.dylib (version 1)\n"
            with patch.object(EMBED.subprocess, "check_output", return_value=output), \
                    self.assertRaisesRegex(ValueError, "Unbundled runtime dependency"):
                EMBED.embed_libraries(root, root / "Frameworks", "iphoneos", "18.0", "test", None)

    def test_incremental_embedding_replaces_read_only_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            destination = root / "destination"
            source.write_bytes(b"current runtime")
            source.chmod(0o444)
            destination.write_bytes(b"previous runtime")
            destination.chmod(0o444)
            EMBED.replace_file(source, destination)
            self.assertEqual(destination.read_bytes(), b"current runtime")
            self.assertEqual(destination.stat().st_mode & 0o777, 0o444)
            self.assertEqual(sorted(path.name for path in root.iterdir()), ["destination", "source"])


if __name__ == "__main__":
    unittest.main()
