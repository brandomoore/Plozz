"""Exercise the real version baker with isolated XcodeGen and lease fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "Project generator uses macOS sed")
class ReleaseIdentityGenerationTests(unittest.TestCase):
    def test_selected_identity_and_local_reset_use_the_catalog_not_the_clock(self):
        with tempfile.TemporaryDirectory(prefix="plozz-release-identity-") as directory:
            root = Path(directory)
            for path in ["tools/lib", "App/Resources", "Sources", "Tests", "TopShelf", "bin"]:
                (root / path).mkdir(parents=True)
            for filename in ["project.yml", "Package.swift", "Package.resolved"]:
                (root / filename).write_text("fixture\n")
            for filename in ["generate-project.sh", "release-notes.py"]:
                shutil.copyfile(ROOT / "tools" / filename, root / "tools" / filename)
            (root / "tools/lib/apple-build-lease.sh").write_text(
                "acquire_apple_build_shared_lease() { :; }\n"
                "install_apple_build_lease_traps() { :; }\n"
            )
            (root / "App/Resources/ReleaseNotes.json").write_text(json.dumps({
                "schemaVersion": 1, "releases": [{
                    "id": "release/045", "version": "2026.9.29",
                    "marketingVersion": "2026.9.25", "build": 45,
                    "releasedAt": "2026-09-29",
                    "sections": [{"category": "New", "items": ["Fixture"]}],
                }]
            }))
            generator = root / "bin/xcodegen"
            generator.write_text("""#!/bin/sh
mkdir -p Plozz.xcodeproj
cat > Plozz.xcodeproj/project.pbxproj <<'EOF'
MARKETING_VERSION = 0.1;
CURRENT_PROJECT_VERSION = 1;
PLOZZ_RELEASE_CHANNEL = "";
PLOZZ_RELEASE_ID = "";
PLOZZ_RELEASE_VERSION = "";
MARKETING_VERSION = 0.1;
CURRENT_PROJECT_VERSION = 1;
EOF
""")
            generator.chmod(0o755)
            environment = {
                key: value for key, value in os.environ.items()
                if not key.startswith(("PLOZZ_", "APPLE_BUILD_LEASE_"))
            }
            environment.update(
                HOME=str(root), XDG_CONFIG_HOME=str(root / "config"),
                PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'",
            )

            def bake(**identity):
                return subprocess.run(
                    ["/bin/sh", str(root / "tools/generate-project.sh"), "--bake-only"],
                    env={**environment, **identity}, cwd=root,
                    capture_output=True, text=True, timeout=30,
                )

            # First full generation establishes the signature; subsequent calls
            # exercise the actual bake-only distribution-to-local transition.
            subprocess.run(
                ["/bin/sh", str(root / "tools/generate-project.sh")],
                env={**environment, "PLOZZ_BUILD_NUMBER": "4000"},
                cwd=root, capture_output=True, text=True, check=True, timeout=30,
            )
            selected = dict(PLOZZ_RELEASE_ID="release/045", PLOZZ_BUILD_NUMBER="45",
                            PLOZZ_RELEASE_CHANNEL="testflight")
            result = bake(**selected)
            self.assertEqual(result.returncode, 0, result.stderr)
            project = root / "Plozz.xcodeproj/project.pbxproj"
            self.assertEqual(project.read_text().count("MARKETING_VERSION = 2026.9.25;"), 2)
            self.assertIn('PLOZZ_RELEASE_VERSION = "2026.9.29";', project.read_text())
            self.assertIn('PLOZZ_RELEASE_ID = "release/045";', project.read_text())

            result = bake(PLOZZ_BUILD_NUMBER="4001.2")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(project.read_text().count("MARKETING_VERSION = 2026.9.25;"), 2)
            for setting in ["PLOZZ_RELEASE_VERSION", "PLOZZ_RELEASE_ID", "PLOZZ_RELEASE_CHANNEL"]:
                self.assertIn(f'{setting} = "";', project.read_text())

            for changes in (
                {"PLOZZ_BUILD_NUMBER": "46"},
                {"PLOZZ_MARKETING_VERSION": "2026.9.29.1"},
                {"PLOZZ_MARKETING_VERSION": "2026.9.29"},
                {"PLOZZ_RELEASE_ID": ""},
            ):
                with self.subTest(changes=changes):
                    result = bake(**{**selected, **changes})
                    self.assertNotEqual(result.returncode, 0)

            catalog_path = root / "App/Resources/ReleaseNotes.json"
            catalog = json.loads(catalog_path.read_text())
            catalog["releases"].insert(0, {
                **catalog["releases"][0], "id": "release/045.1", "build": "45.1"
            })
            catalog_path.write_text(json.dumps(catalog))
            result = bake(PLOZZ_RELEASE_ID="release/045.1", PLOZZ_BUILD_NUMBER="45.1",
                          PLOZZ_RELEASE_CHANNEL="testflight")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(project.read_text().count("CURRENT_PROJECT_VERSION = 45.1;"), 2)
            self.assertIn('PLOZZ_RELEASE_ID = "release/045.1";', project.read_text())
            self.assertIn('PLOZZ_RELEASE_VERSION = "2026.9.29";', project.read_text())
            result = bake(PLOZZ_RELEASE_ID="release/045.1", PLOZZ_BUILD_NUMBER="45",
                          PLOZZ_RELEASE_CHANNEL="testflight")
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
