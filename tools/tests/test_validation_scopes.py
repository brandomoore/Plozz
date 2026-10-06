import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import l10n_freshness as freshness


class ValidationScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", self.root], check=True)
        self.manifest = {
            "name": "Plozz",
            "products": [{"name": name, "targets": [name]} for name in ("Shared", "TV", "Mobile")],
            "targets": [
                {"name": "Shared", "type": "regular"},
                {"name": "TV", "type": "regular", "dependencies": [{"byName": ["Shared", None]}]},
                {"name": "Mobile", "type": "regular", "dependencies": [{"byName": ["Shared", None]}]},
                {"name": "SharedTests", "type": "test", "dependencies": [{"byName": ["Shared", None]}]},
            ],
        }
        self.spec = {"targets": {
            "Plozz": self.target("App/TV", product="TV"),
            "PlozziOS": self.target("App/Mobile", product="Mobile"),
            "PlozzFocusTests": self.target("Tests/TV", product="TV", extra="Tests/Support"),
            "PlozziOSPresentationTests": self.target("Tests/Mobile", product="Mobile", extra="Tests/Support"),
        }}
        self.spec["schemes"] = {
            name: {"build": {"targets": {name: "all"}}} for name in self.spec["targets"]
        }
        original = freshness.command
        def command(root, *args):
            if args[:3] == ("swift", "package", "dump-package"):
                return json.dumps(self.manifest).encode()
            if args[0] == "ruby":
                return json.dumps(self.spec).encode()
            return original(root, *args)
        mock = patch.object(freshness, "command", side_effect=command)
        mock.start()
        self.addCleanup(mock.stop)
        for name in (
            "Sources/Shared/Code.swift", "Sources/TV/Code.swift", "Sources/Mobile/Code.swift",
            "Tests/SharedTests/Test.swift", "Tests/TV/Test.swift", "Tests/Mobile/Test.swift",
            "Tests/Support/Fixture.swift", "App/TV/App.swift", "App/Mobile/App.swift",
            "Config/Local.xcconfig", "project.yml", "Package.resolved", "tools/guard.py",
        ):
            self.write(name)

    @staticmethod
    def target(path, *, product, extra=None):
        return {
            "sources": [{"path": path}, *([{"path": extra}] if extra else [])],
            "dependencies": [{"package": "Plozz", "product": product}],
        }

    def write(self, name, text="before"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def fingerprints(self):
        return {scope: freshness.source_fingerprint(self.root, scope=scope) for scope in (
            "package", "tvos-hosted", "ios-hosted", "tvos-build", "ios-build", "extraction"
        )}

    def changed(self, name):
        before = self.fingerprints()
        self.write(name, "after")
        return {scope for scope, value in self.fingerprints().items() if value != before[scope]}

    def test_hosted_fixture_changes_do_not_repeat_unaffected_phases(self):
        self.assertEqual(self.changed("Tests/TV/Test.swift"), {"tvos-hosted"})
        self.assertEqual(self.changed("Tests/Mobile/Test.swift"), {"ios-hosted"})
        self.assertEqual(self.changed("Tests/Support/Fixture.swift"), {"tvos-hosted", "ios-hosted"})
        self.assertEqual(self.changed("Tests/SharedTests/Test.swift"), {"package"})

    def test_shared_source_revalidates_every_consumer(self):
        self.assertEqual(self.changed("Sources/Shared/Code.swift"), set(self.fingerprints()))

    def test_platform_sources_follow_real_dependencies(self):
        self.assertEqual(self.changed("Sources/TV/Code.swift"), {"tvos-hosted", "tvos-build", "extraction"})
        self.assertEqual(self.changed("Sources/Mobile/Code.swift"), {"ios-hosted", "ios-build", "extraction"})

    def test_unknown_paths_and_configuration_fail_closed(self):
        for name in ("new-build-input", "Config/Local.xcconfig", "project.yml", "Package.resolved", "tools/guard.py"):
            with self.subTest(name=name):
                self.assertEqual(self.changed(name), set(self.fingerprints()))

    def test_added_and_deleted_owned_files_invalidate_their_phase(self):
        self.assertEqual(self.changed("Tests/TV/New.swift"), {"tvos-hosted"})
        before = self.fingerprints()
        (self.root / "Tests/TV/New.swift").unlink()
        self.assertNotEqual(before["tvos-hosted"], self.fingerprints()["tvos-hosted"])

    def test_graph_change_adds_new_shared_test_owner(self):
        self.spec["targets"]["PlozzFocusTests"]["sources"].append({"path": "Tests/Mobile"})
        self.assertEqual(self.changed("Tests/Mobile/Test.swift"), {"tvos-hosted", "ios-hosted"})

    def test_scheme_added_target_is_part_of_the_consumed_graph(self):
        self.spec["targets"]["Additional"] = self.target("Tests/Additional", product="Shared")
        self.spec["schemes"]["PlozzFocusTests"]["test"] = {"targets": [{"name": "Additional"}]}
        self.assertEqual(self.changed("Tests/Additional/New.swift"), {"tvos-hosted"})

    def test_unexpanded_target_templates_fail_closed(self):
        self.spec["include"] = "extra-targets.yml"
        with self.assertRaises(freshness.FreshnessError):
            self.fingerprints()

    def test_docs_and_completed_snapshot_do_not_repeat_compilation(self):
        for name in ("README.md", "docs/testing-policy.md", "tools/l10n-source-snapshot.json"):
            self.assertEqual(self.changed(name), set())

    def test_document_consumed_as_a_target_resource_still_invalidates(self):
        self.spec["targets"]["PlozzFocusTests"]["sources"].append({"path": "docs/fixture.md"})
        self.assertEqual(self.changed("docs/fixture.md"), {"tvos-hosted"})

    def test_bad_graph_and_external_paths_do_not_reuse_evidence(self):
        self.spec["targets"]["PlozzFocusTests"]["dependencies"].append({"target": "Missing"})
        with self.assertRaises(freshness.FreshnessError):
            self.fingerprints()
        self.spec["targets"]["PlozzFocusTests"]["dependencies"].pop()
        self.spec["targets"]["PlozzFocusTests"]["sources"].append({"path": "../outside"})
        with self.assertRaises(freshness.FreshnessError):
            self.fingerprints()

    def test_operational_device_ids_do_not_hide_build_changes(self):
        before = freshness.environment_fingerprint()
        with patch.dict("os.environ", {"PLOZZ_IPHONE_CORE_ID": "another-device", "PLOZZ_MAIN_LANDING_FD": "99"}):
            self.assertEqual(before, freshness.environment_fingerprint())
        with patch.dict("os.environ", {"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "NEW"}):
            self.assertNotEqual(before, freshness.environment_fingerprint())
