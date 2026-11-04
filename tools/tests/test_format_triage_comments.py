"""Regression coverage for presentation-only triage comment updates."""

import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("format_triage", ROOT / "tools/format-triage-comments.py")
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)


def comment(version=2):
    data = {
        "schema_version": version, "issue_number": 351,
        "evidence_urls": ["https://github.com/brandomoore/Plozz/issues/351"] if version == 2 else "",
    }
    return {
        "id": 42, "user": {"login": "github-actions[bot]", "type": "Bot"},
        "issue_url": "https://api.github.com/repos/brandomoore/Plozz/issues/351",
        "body": "**Assessment:** Keep this exact prose.\n\nStructured data:\n\n```json\n"
        + json.dumps(data, indent=2) + "\n```\n\n> Evidence run.\n\n" + APP.MARKER,
    }


class FormatTriageCommentsTests(unittest.TestCase):
    def test_both_versions_preserve_record_prose_and_footer_exactly(self):
        for version in (1, 2):
            with self.subTest(version=version):
                original = comment(version)
                body = APP.collapsed_body(original)
                self.assertEqual(body.replace(APP.OPEN, "").replace(APP.CLOSE, ""), original["body"])
                self.assertEqual(APP.RECORD.search(body)["data"], APP.RECORD.search(original["body"])["data"])
                self.assertIsNone(APP.collapsed_body({**original, "body": body}))

    def test_unowned_and_cross_repository_comments_are_untouched(self):
        cases = [
            {"user": {"login": "someone", "type": "User"}},
            {"user": {"login": "github-actions[bot]", "type": "User"}},
            {"body": "Discord votes"},
            {"issue_url": "https://api.github.com/repos/other/repo/issues/351"},
            {"issue_url": "https://api.github.com/repos/brandomoore/Plozz/issues/351/extra"},
        ]
        for change in cases:
            with self.subTest(change=change):
                self.assertIsNone(APP.collapsed_body({**comment(), **change}))

    def test_invalid_or_ambiguous_records_fail_without_repairing(self):
        original = comment()
        for body in (
            original["body"].replace('"issue_number": 351', '"issue_number": 352'),
            original["body"].replace('"schema_version": 2', '"schema_version": 99'),
            original["body"].replace('"issue_number": 351', "broken JSON"),
            original["body"] + "\nStructured data:\n```json\n{}\n```",
            original["body"].replace("Structured data:", "<details>\nStructured data:"),
        ):
            with self.subTest(body=body):
                with self.assertRaises(ValueError):
                    APP.collapsed_body({**original, "body": body})

    def test_dry_run_never_writes(self):
        with patch.object(APP, "api", return_value=[[comment()]]) as api:
            self.assertEqual(APP.synchronize(), 1)
            self.assertEqual(api.call_count, 1)

    def test_apply_uses_latest_body_not_inventory_snapshot(self):
        old = comment()
        current = copy.deepcopy(old)
        current["body"] = current["body"].replace("Keep this exact prose.", "Newer assessment.")
        expected = APP.collapsed_body(current)
        with patch.object(APP, "api", side_effect=[[[old]], current, {**current, "body": expected}]) as api:
            self.assertEqual(APP.synchronize(apply=True), 1)
            self.assertEqual(api.call_args.kwargs, {"body": expected})

    def test_changed_ownership_prevents_write(self):
        with patch.object(APP, "api", side_effect=[[[comment()]], {**comment(), "body": "Replaced"}]) as api:
            self.assertEqual(APP.synchronize(apply=True), 0)
            self.assertEqual(api.call_count, 2)


if __name__ == "__main__":
    unittest.main()
