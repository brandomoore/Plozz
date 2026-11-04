#!/usr/bin/env python3
"""Offline roadmap coverage: commitment ownership, real delivery, and replay."""

import copy
import importlib.util
import io
import os
from pathlib import Path
import unittest
from contextlib import redirect_stdout
from unittest.mock import Mock, patch

from test_discord_bridge import Discord, GitHub, issue, message


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("discord_roadmap", ROOT / "tools/discord-roadmap.py")
ROAD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ROAD)
B = ROAD.BRIDGE
CHANNEL = {"id": ROAD.CHANNEL, "guild_id": B.GUILD, "type": 0, "name": "roadmap"}
COMMIT = "a" * 40


def event(label="roadmap: planned", actor=ROAD.MAINTAINER, **changes):
    return {"id": 1, "created_at": "2026-10-01T00:00:00Z", "event": "labeled",
            "actor": {"login": actor}, "label": {"name": label}, **changes}


def receipt():
    return {"issue": 1, "commit": COMMIT, "platforms": ["iOS", "tvOS"],
            "deliveries": {}, "status": "awaiting_release"}


class EventGitHub(GitHub):
    def __init__(self, issues=None, comments=None, events=None):
        super().__init__(issues, comments)
        self.events = events or []

    def pages(self, path):
        return copy.deepcopy(self.events) if path.endswith("/events") else super().pages(path)


class RoadmapDiscord(Discord):
    def __init__(self):
        super().__init__([CHANNEL])
        self.messages[ROAD.CHANNEL] = []
        self.fail_pin = False

    def call(self, method, path, data=None, query=None):
        if method == "PUT" and "/messages/pins/" in path:
            self.writes.append((method, path, data))
            if not self.fail_pin:
                for item in self.messages[ROAD.CHANNEL]:
                    if item["id"] == path.split("/")[-1]:
                        item["pinned"] = True
            return None
        return super().call(method, path, data, query)


def synchronize(discord, stages=None, **options):
    with redirect_stdout(io.StringIO()):
        ROAD.synchronize(discord, CHANNEL, stages or {s: [] for s in ROAD.STAGES}, **options)


class StageTests(unittest.TestCase):
    def test_triage_labels_do_not_make_commitments_and_both_kinds_are_included(self):
        github = EventGitHub([
            issue(1, labels=[{"name": "bug"}, {"name": "triage: verify"}]),
            issue(2, labels=[{"name": "enhancement"}, {"name": "triage: backlog"}]),
            issue(3, state="closed"),
            issue(4, labels=[{"name": "bug"}, {"name": "duplicate"}]),
        ])
        stages = ROAD.board(B.GitHubIndex(github), [], [])
        self.assertEqual(len(stages["Backlog"]), 2)
        self.assertIn("Bug #1", stages["Backlog"][0])
        self.assertIn("Feature #2", stages["Backlog"][1])
        self.assertTrue(all(not stages[s] for s in ROAD.STAGES[1:]))
        self.assertFalse(github.writes)

    def test_only_maintainer_label_events_choose_commitment(self):
        report = issue(labels=[{"name": "bug"}, {"name": "roadmap: planned"}])
        self.assertEqual(ROAD.commitment(report, [event()]), "Planned")
        for events in [[], [event(actor="github-actions[bot]")], [event(actor="contributor")],
                       [event(), event(id=2, event="unlabeled")]]:
            with self.assertRaises(ROAD.Error):
                ROAD.commitment(report, events)
        report["labels"].append({"name": "roadmap: in progress"})
        with self.assertRaises(ROAD.Error):
            ROAD.commitment(report, [event()])

    def test_links_require_bot_owned_bridge_provenance(self):
        body = B.managed_body(B.marker("report", "1556500000000000001", "1556500000000000002"), "Report")
        index = B.GitHubIndex(EventGitHub([
            issue(1, body=body, user=B.GITHUB_BOT),
            issue(2, body=body, user="human"),
        ]))
        lines = ROAD.board(index, [], [])["Backlog"]
        self.assertEqual(sum("Discord discussion" in line for line in lines), 1)
        self.assertIn("1556500000000000001/1556500000000000002", "\n".join(lines))

    def check_delivery(self, beta, store, events=(), declarations=None):
        with patch.dict(ROAD.RES, {
            "commit_declarations": Mock(return_value=declarations if declarations is not None else [
                {"issue": 1, "commit": COMMIT, "platforms": ["iOS", "tvOS"]}
            ]),
            "git": lambda *args: "2026-10-01T00:00:00+00:00" if "--format=%cI" in args else "body",
            "ancestor": Mock(return_value=True),
        }), patch.object(ROAD, "includes_fix", side_effect=lambda commit, source: source == "contains-fix"):
            return ROAD.delivery_stage(receipt(), events, beta, store)

    def test_no_delivery_from_merge_closure_or_partial_platforms(self):
        self.assertIsNone(self.check_delivery([], []))
        self.assertIsNone(self.check_delivery([{"platforms": {"IOS"}, "source": "contains-fix"}], []))
        self.assertIsNone(self.check_delivery([{"platforms": {"IOS", "TV_OS"}, "source": "unrelated"}], []))

    def test_beta_and_app_store_are_separate_and_require_every_platform(self):
        both = {"platforms": {"IOS", "TV_OS"}, "source": "contains-fix"}
        self.assertEqual(self.check_delivery([both], []), "In beta")
        self.assertEqual(self.check_delivery([], [both]), "Released")
        self.assertEqual(self.check_delivery(
            [{"platforms": {"TV_OS"}, "source": "contains-fix"}],
            [{"platforms": {"IOS"}, "source": "contains-fix"}],
        ), "In beta")

    def test_reopened_report_and_mismatched_declaration_do_not_appear_delivered(self):
        both = {"platforms": {"IOS", "TV_OS"}, "source": "contains-fix"}
        self.assertIsNone(self.check_delivery([], [both], [
            {"event": "reopened", "created_at": "2026-10-02T00:00:00Z"}
        ]))
        with self.assertRaises(ROAD.Error):
            self.check_delivery([], [both], declarations=[])

    def test_reverted_fix_is_not_delivered(self):
        ROAD.includes_fix.cache_clear()
        with patch.dict(ROAD.RES, {"ancestor": lambda *a: True, "reverted": lambda *a: True}):
            self.assertFalse(ROAD.includes_fix("fix", "source"))
        ROAD.includes_fix.cache_clear()


class AppleAvailabilityTests(unittest.TestCase):
    def versions(self, state="READY_FOR_SALE"):
        return [{"id": "version", "attributes": {"platform": "IOS", "versionString": "1.0.0", "appStoreState": state},
                 "relationships": {"build": {"data": {"type": "builds", "id": "build"}}}}]

    def read(self, versions, included=None):
        if included is None:
            included = {("builds", "build"): {"attributes": {"version": "70", "processingState": "VALID"}}}
        with patch.object(ROAD.ANN, "apple_collection", side_effect=[
            ([{"id": "app"}], {}), (versions, included),
        ]):
            return ROAD.app_store_builds(Mock())

    def test_live_distribution_only_not_approval_preorder_or_pending_release(self):
        for state in ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION"]:
            self.assertEqual(self.read(self.versions(state))[0]["build"], "70")
        for state in ["PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PREORDER_READY_FOR_SALE",
                      "IN_REVIEW", "APPROVED", "REMOVED_FROM_SALE"]:
            self.assertEqual(self.read(self.versions(state)), [])

    def test_missing_build_or_duplicate_live_platform_fails_closed(self):
        with self.assertRaises(ROAD.Error):
            self.read(self.versions(), {})
        with self.assertRaises(ROAD.Error):
            self.read(self.versions() + self.versions())

    def test_latest_distributed_version_wins_regardless_of_response_order(self):
        older = self.versions()[0]
        newer = copy.deepcopy(older)
        newer["attributes"]["versionString"] = "1.1.0"
        newer["attributes"]["appVersionState"] = "READY_FOR_DISTRIBUTION"
        newer["relationships"]["build"]["data"]["id"] = "new-build"
        pending = copy.deepcopy(newer)
        pending["attributes"].update(versionString="1.2.0", appVersionState="PENDING_DEVELOPER_RELEASE")
        included = {
            ("builds", "build"): {"attributes": {"version": "69", "processingState": "VALID"}},
            ("builds", "new-build"): {"attributes": {"version": "70", "processingState": "VALID"}},
        }
        for versions in ([older, newer, pending], [pending, newer, older]):
            self.assertEqual(self.read(versions, included), [
                {"marketing": "1.1.0", "build": "70", "platforms": {"IOS"}},
            ])

    def test_legacy_source_without_catalog_is_explicitly_excluded(self):
        releases = [{"build": "24"}, {"build": "70"}]
        published = [{"tag_name": ROAD.ANN.NOTES.release_tag(r["build"]), "draft": False} for r in releases]
        output = io.StringIO()
        with patch.dict(ROAD.RES, {
            "git": Mock(side_effect=["", "App/Resources/ReleaseNotes.json"]),
            "verified_release_source": Mock(return_value={"build": "70", "source": COMMIT}),
        }), redirect_stdout(output):
            self.assertEqual(ROAD.verified_releases(releases, published), [{"build": "70", "source": COMMIT}])
            ROAD.RES["verified_release_source"].assert_called_once_with(releases[1])
        self.assertIn("Build 24: tagged source has no release catalog", output.getvalue())

    def test_broken_tag_or_invalid_existing_catalog_is_not_skipped(self):
        releases = [{"build": "70"}]
        published = [{"tag_name": ROAD.ANN.NOTES.release_tag("70"), "draft": False}]
        for lookup, verifier in [
            (Mock(side_effect=ROAD.Error("Missing tag")), Mock()),
            (Mock(return_value="App/Resources/ReleaseNotes.json"),
             Mock(side_effect=ROAD.Error("Invalid catalog"))),
        ]:
            with patch.dict(ROAD.RES, {"git": lookup, "verified_release_source": verifier}):
                with self.assertRaises(ROAD.Error):
                    ROAD.verified_releases(releases, published)

    def test_unpublished_source_never_becomes_a_verified_release(self):
        with patch.dict(ROAD.RES, {"verified_release_source": Mock()}):
            self.assertEqual(ROAD.verified_releases([{"build": "70"}], []), [])
            ROAD.RES["verified_release_source"].assert_not_called()


class PublicationTests(unittest.TestCase):
    def test_first_publish_pin_and_repeat_are_idempotent(self):
        discord = RoadmapDiscord()
        synchronize(discord, publish=True, pin=True)
        self.assertEqual(len(discord.messages[ROAD.CHANNEL]), 6)
        self.assertEqual(sum(m.get("pinned", False) for m in discord.messages[ROAD.CHANNEL]), 1)
        for method, path, payload in discord.writes:
            if method == "POST":
                self.assertTrue(payload["enforce_nonce"])
                self.assertEqual(payload["allowed_mentions"]["parse"], [])
        discord.writes.clear()
        synchronize(discord, publish=True, pin=True)
        self.assertEqual(discord.writes, [])

    def test_changed_entries_edit_existing_messages_and_shrink_retires_surplus(self):
        discord = RoadmapDiscord()
        stages = {s: [] for s in ROAD.STAGES}
        stages["Backlog"] = ["x" * 1000] * 8
        synchronize(discord, stages, publish=True)
        count = len(discord.messages[ROAD.CHANNEL])
        stages["Backlog"] = ["One updated report"]
        discord.writes.clear()
        synchronize(discord, stages, publish=True)
        self.assertEqual(len(discord.messages[ROAD.CHANNEL]), count)
        self.assertTrue(all(method == "PATCH" for method, _, _ in discord.writes))
        retired = [m for m in discord.messages[ROAD.CHANNEL] if m["embeds"][0]["title"] == "Roadmap page retired"]
        self.assertEqual(len(retired), 2)
        discord.writes.clear()
        synchronize(discord, stages, publish=True)
        self.assertEqual(discord.writes, [])

    def test_duplicate_bot_records_stop_before_any_write_and_human_markers_are_ignored(self):
        discord = RoadmapDiscord()
        embed = {"footer": {"text": B.FOOTER + ROAD.PREFIX + "guide"}}
        discord.messages[ROAD.CHANNEL] = [message(embeds=[embed])]
        synchronize(discord, publish=True)
        bot_guide = next(m for m in discord.messages[ROAD.CHANNEL] if m["author"]["id"] == B.BOT)
        discord.messages[ROAD.CHANNEL].append(copy.deepcopy(bot_guide))
        discord.writes.clear()
        with self.assertRaises(ROAD.Error):
            synchronize(discord, publish=True)
        self.assertFalse(discord.writes)

    def test_dry_run_never_posts_and_large_board_fails_before_writes(self):
        discord = RoadmapDiscord()
        synchronize(discord)
        self.assertEqual(discord.writes, [])
        stages = {s: [] for s in ROAD.STAGES}
        stages["Backlog"] = ["x" * 3600] * 51
        with self.assertRaises(ROAD.Error):
            synchronize(discord, stages, publish=True)
        self.assertEqual(discord.writes, [])

    def test_unicode_limits_and_title_injection(self):
        pages = ROAD.pages(["\U0001f600" * 1000] * 4)
        self.assertEqual(len(pages), 4)
        self.assertTrue(all(ROAD.units(page) <= 3600 for page in pages))
        title = ROAD.title_text("@everyone [click](https://evil.invalid)\n# Header")
        self.assertNotIn("@everyone", title)
        self.assertNotIn("[click]", title)
        self.assertNotIn("\n", title)

    def test_pin_must_be_confirmed_and_permission_changes_are_opt_in(self):
        discord = RoadmapDiscord()
        discord.fail_pin = True
        with self.assertRaises(ROAD.Error):
            synchronize(discord, publish=True, pin=True)
        with patch.object(B, "make_channel_read_only") as permissions:
            synchronize(RoadmapDiscord(), publish=True)
            permissions.assert_not_called()

    def test_ambiguous_creation_is_rediscovered_without_duplicate_messages(self):
        discord = RoadmapDiscord()
        discord.fail_after_create = True
        # The bridge's fake models ambiguous creation for guide threads, so
        # interrupt after a real message write here instead.
        original = discord.call
        failed = False

        def lose_response(method, path, data=None, query=None):
            nonlocal failed
            result = original(method, path, data, query)
            if method == "POST" and not failed:
                failed = True
                raise ROAD.Error("Ambiguous write")
            return result

        with patch.object(discord, "call", side_effect=lose_response), self.assertRaises(ROAD.Error):
            synchronize(discord, publish=True)
        synchronize(discord, publish=True)
        self.assertEqual(len(discord.messages[ROAD.CHANNEL]), 6)

    def test_wrong_guild_or_bot_cannot_be_used(self):
        discord = Mock()
        discord.call.side_effect = [{"id": B.BOT, "bot": True}, {**CHANNEL, "guild_id": "wrong"}]
        with self.assertRaises(ROAD.Error):
            ROAD.inspect_channel(discord)
        discord.call.side_effect = [{"id": "wrong", "bot": True}]
        with self.assertRaises(ROAD.Error):
            ROAD.inspect_channel(discord)

    def test_no_automatic_setup_or_unapproved_publication(self):
        for args, env in [
            (["roadmap", "--mode", "sync"], {"GITHUB_REPOSITORY": B.REPO, "GITHUB_REF": "refs/heads/main"}),
            (["roadmap", "--mode", "setup"], {
                "GITHUB_REPOSITORY": B.REPO, "GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "schedule",
            }),
            (["roadmap", "--mode", "check", "--make-read-only"], {}),
            (["roadmap", "--mode", "sync"], {
                "GITHUB_REPOSITORY": B.REPO, "GITHUB_REF": "refs/heads/feature", "DISCORD_ROADMAP_ENABLED": "true",
            }),
        ]:
            with patch.dict(os.environ, env, clear=True), patch("sys.argv", args), self.assertRaises(ROAD.Error):
                ROAD.main()

    def test_workflow_roadmap_is_read_only_on_github_model_free_and_opt_in(self):
        workflow = (ROOT / ".github/workflows/discord-bridge.yml").read_text()
        job = workflow.split("\n  roadmap:\n", 1)[1].split("\n  sync:\n", 1)[0]
        self.assertIn("vars.DISCORD_ROADMAP_ENABLED == 'true'", job)
        self.assertIn("github.ref == 'refs/heads/main'", job)
        self.assertIn("ref: main", job)
        self.assertIn("fetch-depth: 0", job)
        self.assertIn("issues: read", job)
        self.assertNotIn("issues: write", job)
        self.assertNotIn("COPILOT", job)
        self.assertIn("inputs.mode == 'roadmap-check'", job)
        self.assertIn('if [ "$PIN_GUIDE" = "true" ]', job)
        self.assertIn('if [ "$MAKE_READ_ONLY" = "true" ]', job)


if __name__ == "__main__":
    unittest.main()
