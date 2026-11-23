import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools.tests.test_tracker_acceptance_preflight import KEY, config, transport

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("tracker_comparison", ROOT / "tools/compare-tracker-baselines.py")
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


def snapshots(provider="jellyfin"):
    before = comparison.reader.baseline(config(), transport(), lambda _: KEY)
    before.update(startedAt="2026-10-24T12:00:00+00:00", capturedAt="2026-10-24T12:00:01+00:00")
    if provider != "jellyfin":
        before["serverCredentialSHA256"] = {provider: before["serverCredentialSHA256"]["jellyfin"]}
        before["cases"][0]["provider"] = provider
    if provider == "plex":
        before["cases"][0]["server"]["state"] = {"viewOffset": None, "viewCount": None, "lastViewedAt": None}
    after = copy.deepcopy(before)
    after.update(startedAt="2026-10-24T12:00:02+00:00", capturedAt="2026-10-24T12:00:03+00:00")
    return before, after


def watched(record_id="watch-a", date=None):
    return {"id": record_id, "content": {"tmdb_id": 550, "media_type": "movie"}, "watchedAt": date}


class CompareTrackerBaselinesTests(unittest.TestCase):
    def test_equal_observations_never_become_app_acceptance_or_proof_of_no_writes(self):
        for provider in ("jellyfin", "emby", "plex"):
            with self.subTest(provider=provider):
                before, after = snapshots(provider)
                result = comparison.compare(before, after)
                self.assertTrue(result["statesUnchanged"])
                self.assertTrue(result["serverStatesUnchanged"])
                self.assertTrue(result["trackerStatesUnchanged"])
                self.assertFalse(result["acceptanceVerified"])
                self.assertNotIn("noWritesVerified", result)
                self.assertEqual(result["writesAttempted"], 0)
                self.assertNotIn(KEY, json.dumps(result))

    def test_server_watch_progress_count_and_date_changes_are_reported_independently(self):
        for field, value in (("played", True), ("playCount", 1), ("positionMilliseconds", 31000),
                             ("lastPlayedAt", "2026-10-24T12:00:02Z")):
            with self.subTest(field=field):
                before, after = snapshots()
                after["cases"][0]["server"]["state"][field] = value
                result = comparison.compare(before, after)
                self.assertFalse(result["statesUnchanged"])
                self.assertFalse(result["serverStatesUnchanged"])
                self.assertTrue(result["trackerStatesUnchanged"])

    def test_plex_absent_fields_never_equal_explicit_zero(self):
        for field in ("viewOffset", "viewCount", "lastViewedAt"):
            before, after = snapshots("plex")
            after["cases"][0]["server"]["state"][field] = 0
            self.assertFalse(comparison.compare(before, after)["serverStatesUnchanged"])

    def test_changed_runtime_is_not_ignored_as_metadata(self):
        before, after = snapshots()
        after["cases"][0]["server"]["runtimeMilliseconds"] += 1
        self.assertFalse(comparison.compare(before, after)["serverStatesUnchanged"])

    def test_tracker_record_presence_identity_and_unknown_dates_are_preserved(self):
        changes = ([], [watched("replacement")], [watched(date="2026-10-24T12:00:02Z")])
        for changed in changes:
            before, after = snapshots()
            before["cases"][0]["tracker"]["watched"] = [watched()]
            after["cases"][0]["tracker"]["watched"] = changed
            result = comparison.compare(before, after)
            self.assertTrue(result["serverStatesUnchanged"])
            self.assertFalse(result["trackerStatesUnchanged"])

    def test_case_and_record_order_does_not_change_state(self):
        before, after = snapshots()
        for snapshot in (before, after):
            snapshot["cases"][0]["tracker"]["watched"] = [watched("a"), watched("b")]
            second = copy.deepcopy(snapshot["cases"][0])
            second["caseID"], second["itemID"] = "second", "item-b"
            snapshot["cases"].append(second)
        after["cases"].reverse()
        after["cases"][1]["tracker"]["watched"].reverse()
        self.assertTrue(comparison.compare(before, after)["statesUnchanged"])

    def test_resume_presence_position_runtime_and_updated_date_are_compared(self):
        resume = {"id": "resume-a", "content": {"tmdb_id": 550, "media_type": "movie"},
                  "positionMilliseconds": 10000, "runtimeMilliseconds": 100000, "updatedAt": None}
        for field, value in (("positionMilliseconds", 10001), ("runtimeMilliseconds", 100001),
                             ("updatedAt", "2026-10-24T12:00:02Z"), ("id", "replacement")):
            before, after = snapshots()
            for snapshot in (before, after):
                snapshot["cases"][0]["tracker"]["resume"] = [copy.deepcopy(resume)]
            self.assertTrue(comparison.compare(before, after)["statesUnchanged"])
            after["cases"][0]["tracker"]["resume"][0][field] = value
            self.assertFalse(comparison.compare(before, after)["trackerStatesUnchanged"])
            after["cases"][0]["tracker"]["resume"] = []
            self.assertFalse(comparison.compare(before, after)["trackerStatesUnchanged"])

    def test_episode_specials_and_multiple_provider_coverage(self):
        before, after = snapshots()
        for snapshot in (before, after):
            second = copy.deepcopy(snapshot["cases"][0])
            second.update(caseID="special", provider="emby", serverID="server-b", userID="user-b",
                          content={"tmdb_id": 1396, "media_type": "tv", "season": 0, "episode": 1})
            record = watched()
            record["content"] = copy.deepcopy(second["content"])
            second["tracker"]["watched"] = [record]
            snapshot["cases"].append(second)
            snapshot["serverCredentialSHA256"]["emby"] = "a" * 64
        self.assertTrue(comparison.compare(before, after)["statesUnchanged"])
        after["cases"].pop()
        with self.assertRaisesRegex(comparison.Failure, "coverage"):
            comparison.compare(before, after)

    def test_boolean_catalog_ids_cannot_equal_numeric_ids(self):
        before, after = snapshots()
        for snapshot in (before, after):
            snapshot["cases"][0]["content"]["tmdb_id"] = 1
            record = watched()
            record["content"]["tmdb_id"] = True
            snapshot["cases"][0]["tracker"]["watched"] = [record]
        with self.assertRaises(comparison.Failure):
            comparison.compare(before, after)

    def test_configuration_and_both_credential_scopes_must_be_unchanged(self):
        for field in ("configurationSHA256", "trackerCredentialSHA256", "serverCredentialSHA256"):
            before, after = snapshots()
            after[field] = {"jellyfin": "0" * 64} if isinstance(after[field], dict) else "0" * 64
            with self.subTest(field=field), self.assertRaisesRegex(comparison.Failure, "scope changed"):
                comparison.compare(before, after)

    def test_case_scope_changes_and_missing_coverage_fail_instead_of_looking_unchanged(self):
        for field, value in (("caseID", "different"), ("serverID", "different"), ("userID", "different"),
                             ("itemID", "different"), ("content", {"tmdb_id": 999, "media_type": "movie"})):
            before, after = snapshots()
            after["cases"][0][field] = value
            with self.subTest(field=field), self.assertRaises(comparison.Failure):
                comparison.compare(before, after)
        before, after = snapshots()
        after["cases"] = []
        with self.assertRaises(comparison.Failure):
            comparison.compare(before, after)

    def test_duplicate_cases_records_and_ambiguous_resume_fail(self):
        for kind in ("case", "watched", "resume"):
            before, after = snapshots()
            if kind == "case":
                after["cases"].append(copy.deepcopy(after["cases"][0]))
            elif kind == "watched":
                after["cases"][0]["tracker"]["watched"] = [watched(), watched()]
            else:
                after["cases"][0]["tracker"]["resume"] = [{}, {}]
            with self.subTest(kind=kind), self.assertRaises(comparison.Failure):
                comparison.compare(before, after)

    def test_missing_malformed_and_unknown_state_fields_fail_closed(self):
        mutations = (
            lambda x: x.pop("serverCredentialSHA256"),
            lambda x: x.update(acceptanceVerified=True),
            lambda x: x.update(writesAttempted=False),
            lambda x: x.update(schemaVersion=True),
            lambda x: x["cases"][0]["server"]["state"].pop("played"),
            lambda x: x["cases"][0]["server"]["state"].update(played=1),
            lambda x: x["cases"][0]["server"]["state"].update(playCount=True),
            lambda x: x["cases"][0]["server"]["state"].update(positionMilliseconds=float("nan")),
            lambda x: x["cases"][0]["server"]["state"].update(positionMilliseconds=100001),
            lambda x: x["cases"][0]["tracker"].update(unknown=[]),
            lambda x: x["cases"][0]["tracker"].update(watched=[{"id": "a", "content": {}}]),
        )
        for mutate in mutations:
            before, after = snapshots()
            mutate(after)
            with self.assertRaises(comparison.Failure):
                comparison.compare(before, after)

    def test_replayed_overlapping_reversed_naive_and_overlong_observations_fail(self):
        before, _ = snapshots()
        with self.assertRaises(comparison.Failure):
            comparison.compare(before, copy.deepcopy(before))
        for start, end in (
            ("2026-10-24T12:00:01Z", "2026-10-24T12:00:03Z"),
            ("2026-10-24T12:00:02Z", "2026-10-24T12:00:01Z"),
            ("2026-10-24T12:00:02", "2026-10-24T12:00:03Z"),
            ("2026-10-24T12:00:02Z", "2026-10-24T12:02:03Z"),
        ):
            before, after = snapshots()
            after.update(startedAt=start, capturedAt=end)
            with self.assertRaises(comparison.Failure):
                comparison.compare(before, after)

    def test_cli_private_files_hashes_changed_exit_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            before, after = snapshots()
            after["cases"][0]["tracker"]["watched"] = [watched()]
            paths = [root / name for name in ("before.json", "after.json")]
            for path, snapshot in zip(paths, (before, after)):
                path.write_text(json.dumps(snapshot))
                path.chmod(0o600)
            for mode, expected in (("all", 2), ("server", 0)):
                output = root / f"{mode}.json"
                args = ["compare", "--before", str(paths[0]), "--after", str(paths[1]), "--output", str(output),
                        "--require-unchanged", mode]
                with patch.object(comparison.sys, "argv", args), \
                        patch.object(comparison.sys, "stdout", new_callable=io.StringIO) as stdout, \
                        patch.object(comparison.sys, "stderr", new_callable=io.StringIO):
                    self.assertEqual(comparison.main(), expected)
                    original = output.read_bytes()
                    result = json.loads(original)
                    self.assertEqual(result["beforeSHA256"], hashlib.sha256(paths[0].read_bytes()).hexdigest())
                    self.assertEqual(result["afterSHA256"], hashlib.sha256(paths[1].read_bytes()).hexdigest())
                    self.assertFalse(result["acceptanceVerified"])
                    self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(comparison.main(), 1)
                    self.assertEqual(output.read_bytes(), original)
                    self.assertNotIn(KEY, stdout.getvalue())

    def test_input_permissions_size_duplicate_json_and_nonfinite_json_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private.json"
            path.write_text("{}")
            path.chmod(0o644)
            with self.assertRaises(comparison.Failure):
                comparison.read_snapshot(path)
            path.chmod(0o600)
            for body in ('{"key":1,"key":2}', '{"value":NaN}', '{"nested":{"a":1,"a":2}}'):
                path.write_text(body)
                with self.assertRaises(comparison.Failure):
                    comparison.read_snapshot(path)
            path.write_text("123456")
            with patch.object(comparison, "MAX_BYTES", 5), self.assertRaises(comparison.Failure):
                comparison.read_snapshot(path)

    def test_cli_failure_writes_no_success_report_or_private_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            before, after = snapshots()
            after["cases"][0]["server"]["state"]["lastPlayedAt"] = KEY
            a, b, output = (root / name for name in ("a.json", "b.json", "output.json"))
            for path, snapshot in ((a, before), (b, after)):
                path.write_text(json.dumps(snapshot))
                path.chmod(0o600)
            with patch.object(comparison.sys, "argv", [
                "compare", "--before", str(a), "--after", str(b), "--output", str(output)
            ]), patch.object(comparison.sys, "stdout", new_callable=io.StringIO) as stdout, \
                    patch.object(comparison.sys, "stderr", new_callable=io.StringIO) as stderr:
                self.assertEqual(comparison.main(), 1)
                self.assertFalse(output.exists())
                self.assertNotIn(KEY, stderr.getvalue())
                self.assertEqual(stdout.getvalue(), "")
                b.write_text(json.dumps(before))
                root.chmod(0o755)
                self.assertEqual(comparison.main(), 1)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
