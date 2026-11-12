"""Source coverage must reject omissions, not merely compare two hand-written lists."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("settings_search_guard", ROOT / "tools/settings-search-guard.py")
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


def component(name="SettingsRoot", file="Sources/FeatureSettings/SettingsRoot.swift"):
    return {
        "name": name, "file": file, "calls": [], "controls": [],
        "anchors": [], "anchorResolutions": {}, "registrations": [],
    }


def control(label='"Show hero"', anchors=None):
    return {"context": "body", "kind": "Toggle", "line": 3, "label": label, "anchors": anchors or []}


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.root = component()
        self.root["controls"] = [control(anchors=['"hero-enabled"'])]
        self.root["anchors"] = ['"hero-enabled"']
        self.catalog = component("SettingsSearchCatalog", "Sources/CoreModels/SettingsSearch.swift")
        self.catalog["registrations"] = [{"id": '"hero-enabled"', "anchor": '"hero-enabled"', "page": ".hero"}]
        self.inventory = [self.root, self.catalog]
        self.policy = {
            "roots": ["SettingsRoot"], "directories": ["Sources/FeatureSettings/"],
            "traversable_directories": ["Sources/"], "input_types": [],
            "boundaries": {}, "exclusions": {},
        }

    def test_registered_control_passes(self):
        self.assertEqual(GUARD.check(self.inventory, self.policy), [])

    def test_new_unregistered_control_fails(self):
        self.root["controls"].append(control('"New preference"'))
        self.assertTrue(any("unregistered" in error for error in GUARD.check(self.inventory, self.policy)))

    def test_an_arbitrary_anchor_cannot_hide_an_omission(self):
        self.root["controls"].append(control('"New preference"', ['"uncatalogued"']))
        self.assertTrue(any("uncatalogued anchors" in error for error in GUARD.check(self.inventory, self.policy)))

    def test_new_settings_file_is_discovered_outside_the_original_roots(self):
        new_page = component("NewPage", "Sources/NewFeature/AdvancedSettings.swift")
        new_page["controls"] = [control()]
        self.inventory.append(new_page)
        self.assertTrue(any("NewPage" in error for error in GUARD.check(self.inventory, self.policy)))

    def test_stale_and_widened_exclusions_fail(self):
        missing = control('"Preview sample"')
        key = GUARD.control_key(self.root, missing)
        self.policy["exclusions"][key] = {"reason": "Transient preview.", "count": 1}
        self.assertTrue(any("Stale or widened" in error for error in GUARD.check(self.inventory, self.policy)))
        self.root["controls"].extend([missing, copy.deepcopy(missing)])
        self.assertTrue(any("Stale or widened" in error for error in GUARD.check(self.inventory, self.policy)))

    def test_renderer_boundary_changes_fail(self):
        renderer = component("SettingsInput")
        renderer["controls"] = [control()]
        self.inventory.append(renderer)
        self.policy["boundaries"]["SettingsInput"] = {
            "reason": "Configured inputs are checked at call sites.",
            "controls": {GUARD.control_key(renderer, renderer["controls"][0]): 1},
        }
        self.assertEqual(GUARD.check(self.inventory, self.policy), [])
        renderer["controls"].append(control('"New renderer preference"'))
        self.assertTrue(any("boundary changed" in error for error in GUARD.check(self.inventory, self.policy)))

    def test_removed_root_and_renderer_boundary_fail(self):
        self.policy["roots"].append("RemovedSettings")
        self.policy["boundaries"]["RemovedInput"] = {
            "reason": "Previously reviewed input.", "controls": {},
        }
        errors = GUARD.check(self.inventory, self.policy)
        self.assertIn("Settings root no longer exists: RemovedSettings", errors)
        self.assertIn("Stale or undocumented component boundary: RemovedInput", errors)

    def test_moving_or_relabeling_an_excluded_control_requires_review(self):
        action = control('"Add Server"')
        action["kind"] = "Button"
        self.root["controls"].append(action)
        key = GUARD.control_key(self.root, action)
        self.policy["exclusions"][key] = {"reason": "Explicit connection setup.", "count": 1}
        self.assertEqual(GUARD.check(self.inventory, self.policy), [])
        for field, value in (
            ("context", "connectionContent"),
            ("label", 'Label { Text(SettingsCopy.addSource) } icon: { Image(systemName: "plus") }'),
        ):
            with self.subTest(field=field):
                original = action[field]
                action[field] = value
                errors = GUARD.check(self.inventory, self.policy)
                self.assertTrue(any("unregistered" in error for error in errors))
                self.assertTrue(any("Stale or widened" in error for error in errors))
                action[field] = original

    def test_extracted_onboarding_file_remains_checked_through_its_call_site(self):
        child = component("ServerProviderChoices", "Sources/AppShelliOS/ServerOnboardingViews.swift")
        child["controls"] = [control('"Provider"')]
        self.root["calls"] = [child["name"]]
        self.inventory.append(child)
        self.policy["traversable_directories"] = ["Sources/FeatureSettings/"]
        self.policy["files"] = [child["file"]]
        errors = GUARD.check(self.inventory, self.policy)
        self.assertTrue(any("unregistered ServerProviderChoices" in error for error in errors))

    def test_removed_anchor_fails(self):
        self.root["anchors"] = []
        self.assertTrue(any("no source anchor" in error for error in GUARD.check(self.inventory, self.policy)))

    def test_unresolved_catalog_family_fails(self):
        self.catalog["registrations"][0]["anchor"] = "unreviewedMapping"
        self.assertTrue(any("Unresolved catalog anchor" in error for error in GUARD.check(self.inventory, self.policy)))

    def test_generic_interpolated_anchor_is_not_universal_coverage(self):
        self.root["anchors"] = ['"\\(anything)"']
        self.assertTrue(any("no source anchor" in error for error in GUARD.check(self.inventory, self.policy)))

    def test_choice_coverage_cannot_reference_a_removed_setting(self):
        choice = control('"Choice"')
        self.root["controls"].append(choice)
        self.policy["exclusions"][GUARD.control_key(self.root, choice)] = {
            "reason": "Choice inside an indexed editor.", "count": 1, "covered_by": ["removed-setting"],
        }
        self.assertTrue(any("missing setting" in error for error in GUARD.check(self.inventory, self.policy)))


@unittest.skipUnless(os.environ.get("PLOZZ_SETTINGS_SEARCH_INVENTORY"), "Run tools/check-settings-search.sh for parser integration")
class InventoryTests(unittest.TestCase):
    def parse(self, source, inputs=()):
        with tempfile.TemporaryDirectory(prefix="plozz-search-inventory-") as directory:
            root = Path(directory)
            (root / "Sources").mkdir()
            (root / "Sources/Settings.swift").write_text(source)
            policy = root / "policy.json"
            policy.write_text(json.dumps({"input_types": list(inputs)}))
            result = subprocess.run(
                [os.environ["PLOZZ_SETTINGS_SEARCH_INVENTORY"], str(root), str(policy)],
                capture_output=True, text=True, timeout=30, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def test_nested_menu_preferences_are_not_skipped(self):
        inventory = self.parse('''
            struct Settings: View {
                var body: some View {
                    Menu("Options") { Toggle("New preference", isOn: $flag) }
                        .settingsSearchAnchor("options")
                }
            }
        ''')
        controls = inventory[0]["controls"]
        self.assertEqual([item["kind"] for item in controls], ["Menu", "Toggle"])
        self.assertEqual(controls[1]["anchors"], [])

    def test_reusable_inputs_are_discovered_at_call_sites(self):
        inventory = self.parse('''
            struct Settings: View {
                var body: some View { CustomInput(selection: $value) }
            }
        ''', inputs=["CustomInput"])
        self.assertEqual(inventory[0]["controls"][0]["kind"], "CustomInput")

    def test_finite_prefix_definitions_resolve_without_universal_wildcards(self):
        inventory = self.parse('''
            struct Settings: View {
                var prefix: String { flag ? "hero" : "detail" }
                var body: some View {
                    Toggle("Size", isOn: $flag).settingsSearchAnchor("\\(prefix)-size")
                }
            }
        ''')
        self.assertIn('"hero-size"', inventory[0]["anchors"])
        self.assertIn('"detail-size"', inventory[0]["anchors"])

    def test_inline_renderer_anchor_is_discovered(self):
        inventory = self.parse('''
            struct Settings: View {
                var body: some View {
                    CustomInput(searchAnchorID: "hero-enabled")
                }
            }
        ''', inputs=["CustomInput"])
        self.assertEqual(inventory[0]["controls"][0]["anchors"], ['"hero-enabled"'])

    def test_top_level_view_factories_cannot_hide_controls(self):
        inventory = self.parse('''
            func makeSettings() -> some View {
                Toggle("Missing preference", isOn: $flag)
            }
        ''')
        self.assertEqual(inventory[0]["name"], "makeSettings")
        self.assertEqual(inventory[0]["controls"][0]["kind"], "Toggle")


@unittest.skipUnless(os.environ.get("PLOZZ_SETTINGS_SEARCH_INVENTORY"), "Run tools/check-settings-search.sh for repository coverage")
class RepositoryCoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        policy_path = ROOT / "tools/settings-search-coverage.json"
        cls.policy = json.loads(policy_path.read_text())
        result = subprocess.run(
            [os.environ["PLOZZ_SETTINGS_SEARCH_INVENTORY"], str(ROOT), str(policy_path)],
            capture_output=True, text=True, timeout=120, check=True,
        )
        cls.inventory = json.loads(result.stdout)

    def test_current_settings_controls_have_reviewed_coverage(self):
        self.assertEqual(GUARD.check(self.inventory, self.policy), [])

    def test_refactored_editors_still_reject_new_unregistered_preferences(self):
        names = {
            "PlozziOSAppearanceSettingsView", "TrailersAndMusicSettingsView",
            "PlozziOSMyLibrariesContent", "MyLibrariesContentView",
            "HomeEditorAutosavingNameInput", "HomeEditorSaveAction", "HomeRowNameEditor",
            "HomeRowRemoveAction", "NavigationNameEditor", "ServerProviderChoices",
            "CollectionSectionSettingsView", "CardCaptionCustomizationContent",
        }
        discovered = {item["name"] for item in GUARD.discover(self.inventory, self.policy)}
        self.assertEqual(names - discovered, set())
        changed = copy.deepcopy(self.inventory)
        for item in changed:
            if item["name"] in names:
                item["controls"].append(control('"Unreviewed preference"'))
        errors = GUARD.check(changed, self.policy)
        for name in sorted(names):
            with self.subTest(component=name):
                self.assertTrue(any(
                    f'unregistered {name}.body Toggle "Unreviewed preference"' in error
                    for error in errors
                ))

    def test_reviewed_inner_controls_cannot_outlive_their_row_anchors(self):
        anchors = {
            "disc-playback", "subtitle-language", "external-template",
            "trailer-sources", "detail-background", "seerr-profile-user",
        }
        def matches_reviewed_anchor(expression):
            pattern = GUARD.string_pattern(expression)
            return pattern is not None and any(
                GUARD.patterns_overlap(pattern, anchor) for anchor in anchors
            )

        changed = copy.deepcopy(self.inventory)
        for item in changed:
            item["anchors"] = [
                anchor for anchor in item.get("anchors", [])
                if not matches_reviewed_anchor(anchor)
            ]
        errors = GUARD.check(changed, self.policy)
        for anchor in sorted(anchors):
            with self.subTest(anchor=anchor):
                self.assertIn(f'Catalog destination has no source anchor: "{anchor}"', errors)


if __name__ == "__main__":
    unittest.main()
