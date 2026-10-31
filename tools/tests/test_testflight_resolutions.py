#!/usr/bin/env python3
"""Offline regression coverage for the hosted, delivery-gated issue watcher."""

import copy
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from test_testflight_discord import Apple, build, catalog_fixture
from test_discord_bridge import Discord, GitHub, THREAD, SECOND, thread, synchronize


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("testflight_resolutions", ROOT / "tools/testflight-resolutions.py")
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)
BRIDGE = APP.BRIDGE
FIX = {"issue": 177, "commit": "a" * 40, "platforms": ["iOS", "tvOS"]}


def release(number="59.4", platforms=("TV_OS", "IOS")):
    return {
        "build": number, "platforms": set(platforms), "marketing": "2026.9.25",
        "version": "2026.10.21", "source": "b" * 40, "tag": APP.NOTES.release_tag(number),
    }


class ResolutionGitHub:
    def __init__(self):
        self.issue = {
            "number": 177, "state": "open", "state_reason": None,
            "updated_at": "2026-10-21T01:00:00Z", "labels": [{"name": "bug"}],
        }
        self.comments = []
        self.events = []
        self.writes = []
        self.fail_after_comment = False
        self.fail_before_close = False
        self.fail_after_close = False
        self.label_exists = True

    def pages(self, path):
        return copy.deepcopy(self.events if path.endswith("/events") else self.comments)

    def call(self, method, path, data=None):
        if method == "GET":
            if "/labels/" in path:
                if not self.label_exists:
                    raise BRIDGE.APIError("GitHub", "GET", 404)
                return {"name": APP.AWAITING_LABEL}
            return copy.deepcopy(self.issue)
        self.writes.append((method, path, copy.deepcopy(data)))
        if method == "POST" and path.endswith("/comments"):
            comment = {
                "id": len(self.comments) + 1, "body": data["body"],
                "user": {"login": BRIDGE.GITHUB_BOT},
                "issue_url": f"https://api.github.com/repos/{BRIDGE.REPO}/issues/177",
                "created_at": "2026-10-21T02:00:00Z",
            }
            self.comments.append(comment)
            if self.fail_after_comment:
                self.fail_after_comment = False
                raise BRIDGE.BridgeError("Ambiguous comment write")
            return copy.deepcopy(comment)
        if method == "PATCH" and "/comments/" in path:
            comment = next(c for c in self.comments if c["id"] == int(path.rsplit("/", 1)[1]))
            comment.update(data)
            return copy.deepcopy(comment)
        if method == "POST" and path.endswith("/labels"):
            if "/issues/" not in path:
                self.label_exists = True
                return data
            self.issue["labels"].extend({"name": name} for name in data["labels"])
            return copy.deepcopy(self.issue["labels"])
        if method == "DELETE":
            self.issue["labels"] = [label for label in self.issue["labels"] if label["name"] != APP.AWAITING_LABEL]
            return None
        if method == "PATCH":
            if self.fail_before_close:
                self.fail_before_close = False
                raise BRIDGE.BridgeError("Close rejected")
            self.issue.update(data)
            if self.fail_after_close:
                self.fail_after_close = False
                raise BRIDGE.BridgeError("Ambiguous close")
            return copy.deepcopy(self.issue)
        raise AssertionError((method, path))


def resolve(github, releases=(), publish=True, fixes=None):
    with (
        redirect_stdout(io.StringIO()),
        patch.object(APP, "ancestor", return_value=True),
        patch.object(APP, "reverted", return_value=False),
        patch.object(APP, "git", return_value="2026-10-20T00:00:00+00:00"),
    ):
        APP.resolve_issues(github, fixes or [FIX], list(releases), publish=publish)


class ResolutionTests(unittest.TestCase):
    def test_merged_only_stays_open_and_marks_awaiting_release_once(self):
        github = ResolutionGitHub()
        github.label_exists = False
        resolve(github)
        self.assertEqual(github.issue["state"], "open")
        self.assertIn({"name": APP.AWAITING_LABEL}, github.issue["labels"])
        self.assertIn("awaiting external TestFlight", github.comments[0]["body"])
        count = len(github.writes)
        resolve(github)
        self.assertEqual(len(github.writes), count)

    def test_partial_delivery_waits_then_posts_a_new_build_comment_before_closing(self):
        github = ResolutionGitHub()
        resolve(github, [release(platforms=("TV_OS",))])
        self.assertEqual(github.issue["state"], "open")
        self.assertIn("build 59.4", github.comments[0]["body"])
        self.assertIn("awaiting external TestFlight availability for iPhone and iPad", github.comments[0]["body"])
        resolve(github, [release()])
        self.assertEqual(github.issue["state"], "closed")
        self.assertEqual(github.issue["state_reason"], "completed")
        self.assertEqual(len(github.comments), 2, "Delivery must create a notification, not only edit an old comment.")
        self.assertNotIn({"name": APP.AWAITING_LABEL}, github.issue["labels"])
        self.assertIn({"name": "bug"}, github.issue["labels"])
        self.assertIn("Apple TV", github.comments[-1]["body"])
        self.assertIn("iPhone and iPad", github.comments[-1]["body"])
        count = len(github.writes)
        resolve(github, [release()])
        self.assertEqual(len(github.writes), count)

    def test_each_platform_retains_its_first_observed_delivered_build(self):
        github = ResolutionGitHub()
        resolve(github, [release("59.4", ("TV_OS",))])
        resolve(github, [release("59.5")])
        receipt = BRIDGE.release_resolution(github.comments[-1], 177)
        self.assertEqual(receipt["deliveries"]["tvOS"]["build"], "59.4")
        self.assertEqual(receipt["deliveries"]["iOS"]["build"], "59.5")

    def test_expired_partial_delivery_waits_and_later_creates_a_new_delivery_notification(self):
        github = ResolutionGitHub()
        resolve(github, [release("59.4", ("TV_OS",))])
        resolve(github, [release("59.5", ("IOS",))])
        self.assertEqual(github.issue["state"], "open")
        self.assertEqual(len(github.comments), 1)
        self.assertEqual(BRIDGE.release_resolution(github.comments[0], 177)["status"], "awaiting_release")
        resolve(github, [release("59.5")])
        self.assertEqual(github.issue["state"], "closed")
        self.assertEqual(len(github.comments), 2)
        self.assertEqual(BRIDGE.release_resolution(github.comments[-1], 177)["status"], "delivered")

    def test_platform_specific_fix_does_not_wait_for_unaffected_platform(self):
        github = ResolutionGitHub()
        resolve(github, [release(platforms=("TV_OS",))], fixes=[{**FIX, "platforms": ["tvOS"]}])
        self.assertEqual(github.issue["state"], "closed")

    def test_checks_are_read_only(self):
        github = ResolutionGitHub()
        resolve(github, [release()], publish=False)
        self.assertEqual(github.writes, [])

    def test_source_without_fix_or_with_revert_never_closes(self):
        for include, reverted in ((False, False), (True, True)):
            github = ResolutionGitHub()
            with (
                patch.object(APP, "ancestor", return_value=include),
                patch.object(APP, "reverted", return_value=reverted),
                patch.object(APP, "git", return_value="2026-10-20T00:00:00+00:00"),
                redirect_stdout(io.StringIO()),
            ):
                APP.resolve_issues(github, [FIX], [release()], publish=True)
            self.assertEqual(github.issue["state"], "open")

    def test_ambiguous_notification_does_not_duplicate_and_failed_close_recovers(self):
        for field in ("fail_after_comment", "fail_before_close", "fail_after_close"):
            with self.subTest(field=field):
                github = ResolutionGitHub()
                setattr(github, field, True)
                with self.assertRaises(BRIDGE.BridgeError):
                    resolve(github, [release()])
                resolve(github, [release()])
                self.assertEqual(github.issue["state"], "closed")
                self.assertEqual(len(github.comments), 1)

    def test_reopened_issue_is_not_closed_again_by_same_fix(self):
        github = ResolutionGitHub()
        resolve(github, [release()])
        github.issue.update(state="open", state_reason="reopened")
        github.events.append({"event": "reopened", "created_at": "2026-10-21T03:00:00Z"})
        count = len(github.writes)
        resolve(github, [release()])
        self.assertEqual(github.issue["state"], "open")
        self.assertEqual(len(github.writes), count)

    def test_previously_closed_issues_are_not_backfilled_or_reopened(self):
        github = ResolutionGitHub()
        github.issue.update(state="closed", state_reason="not_planned")
        resolve(github, [release()])
        self.assertEqual(github.writes, [])

    def test_reopen_before_first_receipt_is_respected(self):
        github = ResolutionGitHub()
        github.events.append({"event": "reopened", "created_at": "2026-10-21T01:00:00Z"})
        resolve(github, [release()])
        self.assertEqual(github.writes, [])

    def test_reopen_during_delivery_notification_does_not_close(self):
        github = ResolutionGitHub()
        original = github.call

        def reopened(method, path, data=None):
            if method == "POST" and path.endswith("/comments"):
                github.events.append({"event": "reopened", "created_at": "2026-10-21T01:59:00Z"})
            return original(method, path, data)

        with patch.object(github, "call", side_effect=reopened):
            resolve(github, [release()])
        self.assertEqual(github.issue["state"], "open")

    def test_new_declaration_after_reopen_can_resolve(self):
        github = ResolutionGitHub()
        github.events.append({"event": "reopened", "created_at": "2026-10-19T01:00:00Z"})
        resolve(github, [release()])
        self.assertEqual(github.issue["state"], "closed")

    def test_human_cannot_forge_a_receipt_or_duplicate_bot_records(self):
        github = ResolutionGitHub()
        resolve(github)
        github.comments[0]["user"]["login"] = "someone"
        resolve(github, [release()])
        self.assertEqual(len(github.comments), 2)
        other = ResolutionGitHub()
        resolve(other)
        other.comments.append(copy.deepcopy(other.comments[0]))
        with self.assertRaisesRegex(BRIDGE.BridgeError, "duplicate release records"):
            resolve(other, [release()])

    def test_concurrent_issue_change_defers_writes(self):
        github = ResolutionGitHub()
        original = github.call
        reads = 0

        def changed(method, path, data=None):
            nonlocal reads
            if method == "GET" and path.endswith("/issues/177"):
                reads += 1
                if reads == 2:
                    github.issue["updated_at"] = "2026-10-21T04:00:00Z"
            return original(method, path, data)

        with patch.object(github, "call", side_effect=changed):
            resolve(github, [release()])
        self.assertEqual(github.writes, [])


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.patch = patch.object(APP, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.run_git("init", "-q")
        self.run_git("config", "user.email", "test@example.invalid")
        self.run_git("config", "user.name", "Test")
        self.run_git("config", "core.hooksPath", "/dev/null")
        path = self.root / "App/Resources/ReleaseNotes.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(catalog_fixture()))
        self.run_git("add", ".")
        self.run_git("commit", "-qm", "Baseline")

    def run_git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.root, check=True, capture_output=True, text=True,
        ).stdout.strip()

    def commit(self, message):
        self.run_git("commit", "--allow-empty", "-qm", message)
        return self.run_git("rev-parse", "HEAD")

    def test_only_explicit_full_fix_trailers_are_declarations(self):
        self.commit("Related changes\n\nRefs #177")
        self.assertEqual(APP.declared_fixes(), ([], []))
        first = self.commit("Fix episode entry\n\nRefs #177\n\nTestFlight-Fix: #177 [tvOS]")
        self.assertEqual(APP.declared_fixes(), ([{"issue": 177, "commit": first, "platforms": ["tvOS"]}], []))
        latest = self.commit("Follow-up fix\n\nRefs #177\n\nTestFlight-Issue: 177 [tvOS,iOS]")
        self.assertEqual(APP.declared_fixes(), ([{**FIX, "commit": latest}], []))

    def test_malformed_trailer_and_standard_revert_fail_closed(self):
        fixed = self.commit("Fix\n\nTestFlight-Fix: #177 [tvOS]")
        self.commit(f"Revert fix\n\nThis reverts commit {fixed}.")
        self.assertTrue(APP.reverted(fixed, "HEAD"))
        self.commit("Bad declaration\n\nTestFlight-Fix: #177 [macOS]")
        fixes, errors = APP.declared_fixes()
        self.assertEqual(fixes, [])
        self.assertIn("invalid TestFlight declaration", errors[0])

    def test_documented_trailer_has_no_github_closing_reference(self):
        guide = (ROOT / ".github/CONTRIBUTING.md").read_text()
        example = guide.split("```text\n", 1)[1].split("```", 1)[0]
        self.assertIn("Refs #177", example)
        self.assertIn("TestFlight-Issue: 177 [tvOS]", example)
        self.assertNotRegex(example.lower(), r"\b(?:fix(?:es|ed)?|close[sd]?|resolve[sd]?):?\s+#")

    def test_historical_session_footer_preserves_explicit_declaration(self):
        for key, reference in (("TestFlight-Fix", "#216"), ("TestFlight-Issue", "216")):
            sha = self.commit(
                f"Restore sign-ins\n\nRefs #216\n\n{key}: {reference} [tvOS,iOS]"
                "\n\nCopilot-Session: c34f31ee-9ce6-4d07-be36-e8d3149dbfc4"
            )
            self.assertEqual(APP.declared_fixes(), ([{**FIX, "issue": 216, "commit": sha}], []))

    def test_malformed_history_does_not_block_unrelated_new_fixes(self):
        self.commit("Earlier fix\n\nTestFlight-Issue: 177 [tvOS]")
        self.commit("Malformed follow-up\n\nRefs #177\n\nTestFlight-Issue: 177 [macOS]")
        valid = self.commit("Different fix\n\nTestFlight-Issue: 178 [iOS]")
        fixes, errors = APP.declared_fixes()
        self.assertEqual(fixes, [{"issue": 178, "commit": valid, "platforms": ["iOS"]}])
        self.assertEqual(len(errors), 1)
        replacement = self.commit("Complete follow-up\n\nTestFlight-Issue: 177 [tvOS,iOS]")
        fixes, errors = APP.declared_fixes()
        self.assertEqual(fixes[0], {**FIX, "commit": replacement})
        self.assertEqual(errors, [])

    def test_prose_after_declaration_is_not_a_metadata_footer(self):
        self.commit("Example\n\nTestFlight-Issue: 177 [tvOS]\n\nNot a complete fix.")
        fixes, errors = APP.declared_fixes()
        self.assertEqual(fixes, [])
        self.assertIn("final trailer block", errors[0])

    def test_malformed_legacy_number_is_quarantined_even_in_a_mixed_block(self):
        self.commit("Old fix\n\nTestFlight-Issue: 250 [tvOS]")
        self.commit("Malformed mixed block\n\nTestFlight-Issue: 238 [tvOS]\nTestFlight-Fix: 250 [tvOS]")
        fixes, errors = APP.declared_fixes()
        self.assertEqual(fixes, [])
        self.assertEqual(len(errors), 1)
        replacement = self.commit("Partial replacement\n\nTestFlight-Issue: 238 [tvOS]")
        fixes, errors = APP.declared_fixes()
        self.assertEqual(fixes, [{"issue": 238, "commit": replacement, "platforms": ["tvOS"]}])
        self.assertEqual(len(errors), 1)
        self.commit("Final replacement\n\nTestFlight-Issue: 250 [tvOS]")
        fixes, errors = APP.declared_fixes()
        self.assertEqual([fix["issue"] for fix in fixes], [238, 250])
        self.assertEqual(errors, [])

    def test_unidentifiable_line_cannot_hide_behind_an_identifiable_line(self):
        self.commit("Old fix\n\nTestFlight-Issue: 250 [tvOS]")
        self.commit("Unknown scope\n\nRefs #250\n\nTestFlight-Issue: 238 [tvOS]\nTestFlight-Fix: missing [tvOS]")
        self.commit("Known scope only\n\nTestFlight-Issue: 238 [tvOS]")
        fixes, errors = APP.declared_fixes()
        self.assertEqual([fix["issue"] for fix in fixes], [238])
        self.assertEqual(len(errors), 1)

    def test_duplicate_and_mixed_invalid_declarations_quarantine_the_whole_commit(self):
        self.commit("Old fix\n\nTestFlight-Issue: 177 [tvOS]")
        for trailer in (
            "TestFlight-Issue: 177 [tvOS]\nTestFlight-Fix: #177 [tvOS]",
            "TestFlight-Issue: 177 [tvOS]\nTestFlight-Issue: 178 [macOS]",
        ):
            self.commit(f"Incomplete metadata\n\n{trailer}")
            fixes, errors = APP.declared_fixes()
            self.assertEqual(fixes, [])
            self.assertTrue(errors)

    def test_published_available_tag_and_exact_catalog_are_required(self):
        self.run_git("tag", "release/056")
        github = Mock(pages=Mock(return_value=[{"tag_name": "release/056", "draft": False}]))
        result = APP.delivered_releases(Apple(build(), build("IOS")), github, (56, 0, 0))
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["source"], self.run_git("rev-parse", "HEAD"))
        self.assertEqual(result[0]["version"], "2026.10.14")
        github.pages.return_value = []
        self.assertEqual(APP.delivered_releases(Apple(build()), github, (56, 0, 0)), [])
        github.pages.return_value = [{"tag_name": "release/056", "draft": False}]
        self.assertEqual(APP.delivered_releases(
            Apple(build(external="WAITING_FOR_BETA_REVIEW")), github, (56, 0, 0),
        ), [])

    def test_available_branch_release_can_declare_fixes_before_main_merge(self):
        main = self.run_git("rev-parse", "HEAD")
        fixed = self.commit("Branch fix\n\nTestFlight-Fix: #177 [tvOS]")
        self.run_git("tag", "release/056")
        self.run_git("checkout", "--detach", main)
        self.assertEqual(APP.declared_fixes(), ([], []))
        self.assertEqual(APP.declared_fixes(("HEAD", fixed)), (
            [{"issue": 177, "commit": fixed, "platforms": ["tvOS"]}], [],
        ))

    def test_tag_catalog_mismatch_prevents_resolution(self):
        self.run_git("tag", "release/057")
        github = Mock(pages=Mock(return_value=[{"tag_name": "release/057", "draft": False}]))
        with self.assertRaisesRegex(ValueError, "not in the catalog"):
            APP.delivered_releases(Apple(build(number="57")), github, (56, 0, 0))


class DiscordResolutionTests(unittest.TestCase):
    def setUp(self):
        self.discord = Discord([thread(), thread(SECOND)])
        self.github = GitHub()
        matcher = Mock()
        matcher.match.side_effect = lambda report, candidates: candidates[0]["number"] if candidates else None
        synchronize(self.discord, self.github, matcher)
        self.number = self.github.issues[0]["number"]

    def receipt(self, delivered=True, user=None):
        receipt = {
            "issue": self.number, "commit": FIX["commit"], "platforms": ["tvOS"], "deliveries": {},
            "status": "delivered" if delivered else "awaiting_release",
        }
        if delivered:
            receipt["deliveries"]["tvOS"] = {k: release()[k] for k in ("build", "version", "tag", "source")}
        self.github.comments.append({
            "id": 500, "body": APP.resolution_body(receipt),
            "user": {"login": user or BRIDGE.GITHUB_BOT},
            "issue_url": f"https://api.github.com/repos/{BRIDGE.REPO}/issues/{self.number}",
            "created_at": "2026-10-21T02:00:00Z",
        })

    def sync(self):
        with (
            patch.dict("os.environ", {"TESTFLIGHT_RESOLUTION_ENABLED": "true"}),
            redirect_stdout(io.StringIO()),
        ):
            index = BRIDGE.GitHubIndex(self.github)
            for linked_thread in self.discord.threads:
                messages = copy.deepcopy(self.discord.messages[linked_thread["id"]])
                BRIDGE.sync_issue_to_discord(self.discord, copy.deepcopy(linked_thread), messages, index, self.number)

    def test_delivery_message_precedes_archive_and_retry_does_not_write(self):
        self.receipt()
        self.github.issues[0].update(state="closed", state_reason="completed")
        self.sync()
        for linked_thread in self.discord.threads:
            self.assertTrue(linked_thread["thread_metadata"]["archived"])
            embeds = [m["embeds"][0] for m in self.discord.messages[linked_thread["id"]] if m.get("embeds")]
            self.assertTrue(any("fixed in **build 59.4**" in e["description"] for e in embeds))
            self.assertFalse(any(BRIDGE.RESOLUTION_HEADER in e["description"] for e in embeds))
        count = len(self.discord.writes)
        self.sync()
        self.assertEqual(len(self.discord.writes), count)
        self.assertFalse(any("locked" in data for _, _, data in self.discord.writes))

    def test_pending_manual_closure_and_forged_receipt_do_not_archive(self):
        for delivered, user, state in (
            (False, None, "closed"), (True, "person", "closed"), (True, None, "open"),
        ):
            with self.subTest(delivered=delivered, user=user, state=state):
                self.github.comments = [c for c in self.github.comments if c["id"] != 500]
                self.receipt(delivered, user)
                self.github.issues[0].update(state=state, state_reason="completed")
                self.sync()
                self.assertFalse(self.discord.threads[0]["thread_metadata"].get("archived", False))

    def test_disabled_activation_and_locked_posts_are_never_archived(self):
        self.receipt()
        self.github.issues[0].update(state="closed", state_reason="completed")
        with patch.dict("os.environ", {"TESTFLIGHT_RESOLUTION_ENABLED": "false"}):
            index = BRIDGE.GitHubIndex(self.github)
            BRIDGE.sync_issue_to_discord(
                self.discord, copy.deepcopy(self.discord.threads[0]),
                copy.deepcopy(self.discord.messages[THREAD]), index, self.number,
            )
        self.assertFalse(self.discord.threads[0]["thread_metadata"].get("archived", False))
        self.discord.threads[0]["thread_metadata"]["locked"] = True
        self.github.comments[-1]["body"] += "\nA new update"
        self.sync()
        self.assertFalse(self.discord.threads[0]["thread_metadata"].get("archived", False))

    def test_watcher_has_no_model_or_local_host_dependency(self):
        workflow = (ROOT / ".github/workflows/testflight-resolutions.yml").read_text()
        self.assertIn("runs-on: ubuntu-24.04", workflow)
        self.assertIn("group: discord-issue-bridge", workflow)
        self.assertIn("ref: main", workflow)
        self.assertNotIn("self-hosted", workflow)
        self.assertNotIn("COPILOT_GITHUB_TOKEN", workflow)
        self.assertNotIn("setup-node", workflow)
        self.assertNotIn("fastlane", workflow)
        self.assertIn("TESTFLIGHT_RESOLUTION_ENABLED", workflow)

    def test_deterministic_delivery_uses_existing_links_without_model_or_starter(self):
        self.receipt()
        self.github.issues[0].update(state="closed", state_reason="completed")
        self.discord.messages[THREAD] = [m for m in self.discord.messages[THREAD] if m["id"] != THREAD]
        channels = {identifier: {"id": identifier, "topic": BRIDGE.PUBLIC_NOTICE} for identifier in BRIDGE.FORUMS}
        with (
            patch.object(BRIDGE, "inspect_discord", return_value=channels),
            patch.object(BRIDGE, "require_channel_permissions") as permissions,
            patch.object(BRIDGE, "CopilotMatcher", side_effect=AssertionError("No model calls")),
            patch.dict("os.environ", {"TESTFLIGHT_RESOLUTION_ENABLED": "true"}),
            redirect_stdout(io.StringIO()),
        ):
            before = len(self.discord.writes)
            BRIDGE.sync_release_resolutions(self.discord, self.github, publish=False)
            self.assertEqual(len(self.discord.writes), before)
            BRIDGE.sync_release_resolutions(self.discord, self.github, publish=True)
        self.assertEqual(permissions.call_count, 4)
        self.assertTrue(all(t["thread_metadata"]["archived"] for t in self.discord.threads))

    def test_reopen_during_discord_send_prevents_new_archival(self):
        self.receipt()
        self.github.issues[0].update(state="closed", state_reason="completed")
        with patch.object(self.github, "call", return_value={"state": "open", "state_reason": "reopened"}):
            self.sync()
        self.assertFalse(any(t["thread_metadata"].get("archived") for t in self.discord.threads))

    def test_thread_management_permission_is_required_without_administrator(self):
        channel = {"id": THREAD, "permission_overwrites": []}
        discord = Mock()
        discord.call.side_effect = [
            {"roles": []},
            [{"id": BRIDGE.GUILD, "permissions": str((1 << 10) | (1 << 38))}],
        ]
        with self.assertRaisesRegex(BRIDGE.BridgeError, "Manage Threads"):
            BRIDGE.require_channel_permissions(discord, channel, {"Manage Threads": 34})


if __name__ == "__main__":
    unittest.main()
