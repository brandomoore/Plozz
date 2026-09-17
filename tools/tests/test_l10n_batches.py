#!/usr/bin/env python3
"""Bounded planning, independent review, and transactional artifact assembly."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


TOOLS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("l10n_batches", TOOLS / "l10n-batches.py")
assert SPEC is not None and SPEC.loader is not None
BATCHES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BATCHES)
LANGUAGES = [
    "ar", "bg", "ca", "cs", "da", "de", "el", "es", "fa", "fi", "fr", "he",
    "hi", "hr", "hu", "id", "it", "ja", "ko", "ms", "nb", "nl", "pl", "pt-BR",
    "ro", "ru", "sk", "sl", "sr-Latn", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "needs_review", "value": value}}


def packets(languages: list[str], count: int = 19, *, permissions: bool = False) -> dict:
    return {
        language: {
            "sourceLanguage": "en",
            "catalogSHA256": "catalog-fingerprint",
            "missingFor": language,
            "entries": {
                f"New copy {index:02}": {
                    "sourceText": f"New copy {index:02}", "comment": "",
                    "englishLocalization": {}, "requiresRefresh": True,
                }
                for index in range(count)
            },
            "infoPlistEntries": {
                key: {"sourceText": "Permission description", "comment": "", "requiresRefresh": True}
                for key in (BATCHES.SOURCE.INFO_CATALOGS if permissions else [])
            },
        }
        for language in languages
    }


class LocalizationBatchTests(unittest.TestCase):
    def covered_units(self, manifest: dict, files: dict) -> list[tuple]:
        return [
            (language, kind, key)
            for batch in manifest["batches"]
            for language in batch["languages"]
            for kind in ("entries", "infoPlistEntries")
            for key in files[batch["sourcePacket"]][kind]
        ]

    def reviewed_plan(self, root: Path, source: dict, **limits) -> tuple[Path, Path, dict, dict]:
        manifest, files = BATCHES.plan_batches(source, **limits)
        plan = root / "plan"
        BATCHES.publish_plan(plan, manifest, files)
        artifacts = root / "original"
        artifacts.mkdir()
        for language in source:
            BATCHES.write(artifacts / f"{language}.json", {
                "language": language, "languageName": f"Name {language}",
                "translations": {"Existing": unit("Preserved")},
                "infoPlist": {key: "Preserved permission" for key in BATCHES.SOURCE.INFO_CATALOGS},
            })
        for batch in manifest["batches"]:
            template = copy.deepcopy(files[batch["draftTemplate"]])
            template["languages"] = {
                language: {key: unit(f"Translated {key}") for key in template["deltaKeys"]}
                for language in batch["languages"]
            }
            template["infoPlistLanguages"] = {
                language: {key: "Reviewed permission" for key in template["infoPlistKeys"]}
                for language in batch["languages"]
            }
            BATCHES.write(plan / batch["draftOutput"], template)
            BATCHES.write(plan / batch["reviewedOutput"], template)
            self.write_review(plan, batch, files[batch["sourcePacket"]])
        return plan, artifacts, manifest, files

    def write_review(self, root: Path, batch: dict, source: dict) -> None:
        BATCHES.write(root / batch["reviewEvidence"], {
            "batchID": batch["id"], "sourceCatalogSHA256": source["catalogSHA256"],
            "draftSHA256": BATCHES.digest(root / batch["draftOutput"]),
            "reviewedSHA256": BATCHES.digest(root / batch["reviewedOutput"]),
            "languages": batch["languages"], "deltaKeys": list(source["entries"]),
            "infoPlistKeys": list(source["infoPlistEntries"]), "unitCount": batch["unitCount"],
            "verdict": "approved",
            "author": {"agentID": "author-1", "model": "gpt-6-astra", "reasoningEffort": "high"},
            "reviewer": {"agentID": "reviewer-1", "model": "gpt-6-astra", "reasoningEffort": "high"},
        })

    def test_release_038_shape_needs_six_authors_and_six_reviewers_not_42_agents(self) -> None:
        source = packets(LANGUAGES)
        manifest, files = BATCHES.plan_batches(source)
        self.assertEqual(len(manifest["batches"]), 6)
        self.assertEqual(manifest["unitCount"], 684)
        covered = self.covered_units(manifest, files)
        self.assertEqual(len(covered), len(set(covered)))
        self.assertEqual(len(covered), 684)
        self.assertTrue(all(batch["unitCount"] == 114 for batch in manifest["batches"]))

    def test_plan_is_deterministic_across_language_and_key_insertion_order(self) -> None:
        source = packets(["fr", "de"])
        shuffled = copy.deepcopy(source)
        for value in shuffled.values():
            value["entries"] = dict(reversed(list(value["entries"].items())))
        self.assertEqual(BATCHES.plan_batches(source), BATCHES.plan_batches(dict(reversed(list(shuffled.items())))))

    def test_different_locale_gaps_do_not_overwrite_already_current_translations(self) -> None:
        source = packets(["de", "fr"], 2)
        source["de"]["entries"].pop("New copy 01")
        manifest, files = BATCHES.plan_batches(source)
        self.assertEqual(set(self.covered_units(manifest, files)), {
            ("de", "entries", "New copy 00"),
            ("fr", "entries", "New copy 00"),
            ("fr", "entries", "New copy 01"),
        })

    def test_large_deltas_split_keys_without_duplicate_or_missing_ownership(self) -> None:
        source = packets(["de", "fr", "es", "it"], 9, permissions=True)
        manifest, files = BATCHES.plan_batches(source, max_units=6, max_languages=3)
        covered = self.covered_units(manifest, files)
        self.assertEqual(len(covered), 48)
        self.assertEqual(len(covered), len(set(covered)))
        self.assertTrue(all(batch["unitCount"] <= 6 for batch in manifest["batches"]))

    def test_byte_budget_also_bounds_batches_and_rejects_an_indivisible_oversized_entry(self) -> None:
        source = packets(["de", "fr"], 3)
        manifest, files = BATCHES.plan_batches(source, max_source_bytes=400)
        for batch in manifest["batches"]:
            packet = files[batch["sourcePacket"]]
            size = sum(len(BATCHES.canonical([kind, key, value]))
                       for kind in ("entries", "infoPlistEntries") for key, value in packet[kind].items())
            self.assertLessEqual(size * len(batch["languages"]), 400)
        with self.assertRaisesRegex(ValueError, "exceeds"):
            BATCHES.plan_batches(source, max_source_bytes=1)

    def test_permission_only_delta_and_no_change_plan(self) -> None:
        source = packets(["de", "fr"], 0, permissions=True)
        manifest, files = BATCHES.plan_batches(source)
        self.assertEqual(manifest["unitCount"], 6)
        self.assertEqual(len(manifest["batches"]), 1)
        self.assertFalse(files[manifest["batches"][0]["sourcePacket"]]["entries"])
        empty, _ = BATCHES.plan_batches(packets(["de", "fr"], 0))
        self.assertEqual(empty["batches"], [])
        self.assertEqual(empty["unitCount"], 0)

    def test_invalid_limits_and_mixed_source_hashes_fail(self) -> None:
        for value in [0, -1, True, 1.5]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                BATCHES.plan_batches(packets(["de"]), max_units=value)
        source = packets(["de", "fr"])
        source["fr"]["catalogSHA256"] = "another catalog"
        with self.assertRaisesRegex(ValueError, "different catalogs"):
            BATCHES.plan_batches(source)

    def test_english_plural_errors_fail_before_translation_work_is_dispatched(self) -> None:
        catalog = {"sourceLanguage": "en", "strings": {"%lld items": {"localizations": {}}}}
        with patch.object(BATCHES.ARTIFACTS, "load", return_value=catalog):
            with self.assertRaisesRegex(ValueError, "Correct English plural structures"):
                BATCHES.current_packets(["de"], Path("unused-snapshot.json"))

    def test_plan_never_overwrites_existing_work(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest, files = BATCHES.plan_batches(packets(["de"]))
            BATCHES.publish_plan(root / "plan", manifest, files)
            with self.assertRaisesRegex(ValueError, "already exists"):
                BATCHES.publish_plan(root / "plan", manifest, files)
            self.assertEqual(BATCHES.ARTIFACTS.load(root / "plan/manifest.json"), manifest)

    def test_review_requires_independent_explicit_actor_identity_and_complete_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            plan, _, manifest, files = self.reviewed_plan(Path(temp), packets(["de"], 2))
            batch = manifest["batches"][0]
            evidence_path = plan / batch["reviewEvidence"]
            valid = BATCHES.ARTIFACTS.load(evidence_path)
            invalid = [
                {**valid, "reviewer": valid["author"]},
                {**valid, "reviewer": {"agentID": "reviewer-1"}},
                {**valid, "reviewer": {**valid["reviewer"], "model": "auto"}},
                {**valid, "unitCount": 1},
                {**valid, "deltaKeys": ["New copy 00"]},
                {**valid, "verdict": "pending"},
            ]
            for evidence in invalid:
                with self.subTest(evidence=evidence):
                    BATCHES.write(evidence_path, evidence)
                    with self.assertRaises(ValueError):
                        BATCHES.validate_review(plan, batch, files[batch["sourcePacket"]])

    def test_edit_after_review_or_extra_locale_invalidates_review(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            plan, _, manifest, files = self.reviewed_plan(Path(temp), packets(["de"], 1))
            batch = manifest["batches"][0]
            reviewed = BATCHES.ARTIFACTS.load(plan / batch["reviewedOutput"])
            reviewed["languages"]["fr"] = reviewed["languages"]["de"]
            BATCHES.write(plan / batch["reviewedOutput"], reviewed)
            with self.assertRaisesRegex(ValueError, "review reviewedSHA256"):
                BATCHES.validate_review(plan, batch, files[batch["sourcePacket"]])
            self.write_review(plan, batch, files[batch["sourcePacket"]])
            with self.assertRaisesRegex(ValueError, "exactly its assigned languages"):
                BATCHES.validate_review(plan, batch, files[batch["sourcePacket"]])

    def test_review_cannot_approve_a_dropped_format_argument(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source = packets(["de"], 0)
            source["de"]["entries"]["Count %@"] = {
                "sourceText": "Count %@", "comment": "", "englishLocalization": {}, "requiresRefresh": True,
            }
            plan, _, manifest, files = self.reviewed_plan(Path(temp), source)
            batch = manifest["batches"][0]
            reviewed = BATCHES.ARTIFACTS.load(plan / batch["reviewedOutput"])
            reviewed["languages"]["de"]["Count %@"] = unit("Anzahl")
            BATCHES.write(plan / batch["reviewedOutput"], reviewed)
            self.write_review(plan, batch, files[batch["sourcePacket"]])
            with self.assertRaises(BATCHES.IMPORTER.ImportErrorDetail):
                BATCHES.validate_review(plan, batch, files[batch["sourcePacket"]])

    def test_missing_review_stale_plan_and_changed_source_leave_artifacts_untouched(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = packets(["de"], 2)
            plan, artifacts, manifest, files = self.reviewed_plan(root, source)
            original = (artifacts / "de.json").read_bytes()
            batch = manifest["batches"][0]
            (plan / batch["reviewEvidence"]).unlink()
            with self.assertRaises(ValueError):
                BATCHES.merge_batches(plan / "manifest.json", artifacts, root / "output", source)
            self.write_review(plan, batch, files[batch["sourcePacket"]])
            changed = copy.deepcopy(source)
            changed["de"]["catalogSHA256"] = "new catalog"
            with self.assertRaisesRegex(ValueError, "stale or incomplete"):
                BATCHES.merge_batches(plan / "manifest.json", artifacts, root / "output", changed)
            altered = copy.deepcopy(files[batch["sourcePacket"]])
            altered["entries"]["New copy 00"]["sourceText"] = "tampered"
            BATCHES.write(plan / batch["sourcePacket"], altered)
            with self.assertRaisesRegex(ValueError, "source packet was changed"):
                BATCHES.merge_batches(plan / "manifest.json", artifacts, root / "output", source)
            self.assertEqual((artifacts / "de.json").read_bytes(), original)
            self.assertFalse((root / "output").exists())

    def test_batch_files_cannot_escape_through_paths_or_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            plan = root / "plan"
            plan.mkdir()
            (root / "external.json").write_text("{}")
            (plan / "link.json").symlink_to(root / "external.json")
            for name in ["../external.json", "link.json", str(root / "external.json")]:
                with self.subTest(name=name), self.assertRaises(ValueError):
                    BATCHES.batch_path(plan, name)

    def test_merge_reuses_delta_tool_and_full_validation_before_publishing(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = packets(["de"], 3, permissions=True)
            plan, artifacts, _, _ = self.reviewed_plan(root, source, max_units=2)
            original = (artifacts / "de.json").read_bytes()
            run = subprocess.run
            validations = []

            def validation_boundary(arguments, **kwargs):
                if Path(arguments[1]).name != "l10n-import.py":
                    return run(arguments, **kwargs, capture_output=True, text=True)
                validations.append(arguments)
                staged = Path(arguments[2]) / "de.json"
                entries = {"Existing": {}}
                entries.update({key: {} for key in source["de"]["entries"]})
                language, _, _ = BATCHES.IMPORTER.validate_language(staged, entries, True)
                BATCHES.IMPORTER.validate_info_plist(staged, BATCHES.ARTIFACTS.load(staged), language)
                return subprocess.CompletedProcess(arguments, 0)

            with patch.object(BATCHES.subprocess, "run", side_effect=validation_boundary):
                BATCHES.merge_batches(plan / "manifest.json", artifacts, root / "output", source)
            merged = BATCHES.ARTIFACTS.load(root / "output/de.json")
            self.assertEqual(merged["languageName"], "Name de")
            self.assertEqual(merged["translations"]["Existing"], unit("Preserved"))
            self.assertEqual(len(merged["translations"]), 4)
            self.assertEqual(set(merged["infoPlist"].values()), {"Reviewed permission"})
            self.assertEqual((artifacts / "de.json").read_bytes(), original)
            self.assertEqual(len(validations), 1)
            self.assertIn("--require-info-plist", validations[0])
            self.assertIn("--allow-translated-state", validations[0])
            self.assertNotIn("--apply", validations[0])

    def test_validation_failure_never_publishes_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = packets(["de"], 1)
            plan, artifacts, _, _ = self.reviewed_plan(root, source)
            original = (artifacts / "de.json").read_bytes()
            with patch.object(BATCHES.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "validator")):
                with self.assertRaises(subprocess.CalledProcessError):
                    BATCHES.merge_batches(plan / "manifest.json", artifacts, root / "output", source)
            self.assertFalse((root / "output").exists())
            self.assertEqual((artifacts / "de.json").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
