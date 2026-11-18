#!/usr/bin/env python3
"""Offline coverage for availability, credential boundaries, and replay safety."""

import base64
import copy
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("testflight_discord", ROOT / "tools/testflight-discord.py")
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)
BRIDGE = APP.BRIDGE
WORKFLOW = (ROOT / ".github/workflows/testflight-discord.yml").read_text()
PERMISSIONS = sum(1 << bit for bit in (10, 11, 14, 16))


def build(platform="TV_OS", number="56", external="IN_BETA_TESTING", **attributes):
    identifier = platform + number
    return {
        "type": "builds", "id": identifier,
        "attributes": {"version": number, "expired": False, "processingState": "VALID", **attributes},
        "relationships": {
            "preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": identifier}},
            "buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": identifier}},
        },
    }, [
        {"type": "preReleaseVersions", "id": identifier, "attributes": {"platform": platform, "version": "2026.9.25"}},
        {"type": "buildBetaDetails", "id": identifier, "attributes": {"externalBuildState": external}},
    ]


class Apple:
    def __init__(self, *builds):
        self.group = {"type": "betaGroups", "id": "group", "attributes": {
            "name": APP.GROUP, "isInternalGroup": False,
            "publicLink": APP.TESTFLIGHT, "publicLinkEnabled": True,
        }}
        self.builds = builds
        self.member_ids = [item[0]["id"] for item in builds]
        self.calls = []

    def call(self, method, path, query=None):
        self.calls.append((method, path, query))
        assert method == "GET"
        if path == "/apps":
            return {"data": [{"type": "apps", "id": "app"}]}
        if path == "/apps/app/betaGroups":
            return {"data": [copy.deepcopy(self.group)]}
        if path == "/betaGroups/group/builds":
            assert "include" not in query
            return {"data": [copy.deepcopy(item[0]) for item in self.builds if item[0]["id"] in self.member_ids]}
        if path == "/builds":
            matches = [item for item in self.builds if item[0]["attributes"]["version"] == query["filter[version]"]]
            return {
                "data": [copy.deepcopy(item[0]) for item in matches],
                "included": [copy.deepcopy(value) for item in matches for value in item[1]],
            }
        raise AssertionError(path)


class Discord:
    def __init__(self):
        self.messages = []
        self.writes = []
        self.permissions = PERMISSIONS
        self.channel = {"id": APP.CHANNEL, "guild_id": BRIDGE.GUILD, "type": 0, "permission_overwrites": []}
        self.fail_after_create = False

    def call(self, method, path, data=None, query=None):
        if method == "GET":
            if path == "/users/@me":
                return {"id": BRIDGE.BOT, "bot": True}
            if path == f"/channels/{APP.CHANNEL}":
                return copy.deepcopy(self.channel)
            if path == f"/guilds/{BRIDGE.GUILD}/members/{BRIDGE.BOT}":
                return {"roles": ["100"]}
            if path.endswith("/roles"):
                return [{"id": BRIDGE.GUILD, "permissions": str(self.permissions)}]
            if path.endswith("/messages"):
                return copy.deepcopy(self.messages)
        self.writes.append((method, path, copy.deepcopy(data)))
        if method == "POST":
            created = {
                "id": str(1000 + len(self.messages)), "author": {"id": BRIDGE.BOT, "bot": True},
                "embeds": copy.deepcopy(data["embeds"]),
            }
            self.messages.append(created)
            if self.fail_after_create:
                self.fail_after_create = False
                raise APP.Error("Ambiguous creation.")
            return copy.deepcopy(created)
        if method == "PATCH":
            item = next(item for item in self.messages if item["id"] == path.split("/")[-1])
            item.update(copy.deepcopy(data))
            return copy.deepcopy(item)
        raise AssertionError((method, path))


def catalog_fixture(number=56, version="2026.10.14", released_at="2026-10-14"):
    return {"schemaVersion": 1, "releases": [{
        "id": APP.NOTES.release_tag(number), "build": number, "version": version,
        "marketingVersion": "2026.9.25", "releasedAt": released_at,
        "sections": [{"category": "Updated", "items": ["Playback improvements."]}],
    }]}


def catalog_response(catalog):
    content = base64.encodebytes(json.dumps(catalog).encode()).decode()
    return {"type": "file", "encoding": "base64", "content": content}


def github_fixture(catalog):
    return Mock(
        pages=Mock(return_value=[{"tag_name": entry["id"], "draft": False} for entry in catalog["releases"]]),
        call=Mock(return_value=catalog_response(catalog)),
    )


def sync(discord, apple, publish=True, github=None, catalog=None, roadmap_enabled=False):
    github = github or github_fixture(catalog_fixture())
    with redirect_stdout(io.StringIO()):
        APP.synchronize(
            discord, apple, github,
            catalog if catalog is not None else catalog_fixture(),
            (56, 0, 0), publish=publish, roadmap_enabled=roadmap_enabled,
        )


class AvailabilityTests(unittest.TestCase):
    def test_both_platforms_share_one_announcement_and_replays_do_not_write(self):
        discord, apple = Discord(), Apple(build(), build("IOS"))
        sync(discord, apple)
        self.assertEqual(len(discord.messages), 1)
        embed = discord.messages[0]["embeds"][0]
        self.assertIn("2026.10.14 (56)", embed["title"])
        self.assertIn("Apple TV", embed["description"])
        self.assertIn("iPhone and iPad", embed["description"])
        self.assertIn("/releases/tag/release/056", embed["description"])
        self.assertIn("**Updated**\n• Playback improvements.", embed["description"])
        sync(discord, apple)
        self.assertEqual(len(discord.writes), 1)
        self.assertTrue(discord.writes[0][2]["enforce_nonce"])
        self.assertEqual(discord.writes[0][2]["allowed_mentions"]["parse"], [])

    def test_partial_availability_adds_platform_to_same_message_after_review(self):
        discord = Discord()
        sync(discord, Apple(build(), build("IOS", external="WAITING_FOR_BETA_REVIEW")))
        self.assertNotIn("iPhone", discord.messages[0]["embeds"][0]["description"])
        sync(discord, Apple(build(), build("IOS")))
        self.assertEqual(len(discord.messages), 1)
        self.assertEqual([item[0] for item in discord.writes], ["POST", "PATCH"])
        self.assertIn("iPhone", discord.messages[0]["embeds"][0]["description"])

    def test_uploaded_internal_only_expired_and_old_builds_do_not_announce(self):
        cases = [
            build(external="READY_FOR_BETA_SUBMISSION"),
            build(external="WAITING_FOR_BETA_REVIEW"),
            build(expired=True), build(processingState="PROCESSING"),
            build(number="55.6"), build(expired=None),
        ]
        for item in cases:
            with self.subTest(item=item[0]["attributes"]):
                discord = Discord()
                sync(discord, Apple(item))
                self.assertEqual(discord.writes, [])

    def test_missing_group_link_or_relationship_fails_without_writing(self):
        for kind in ("group", "link", "relationship"):
            discord, apple = Discord(), Apple(build())
            if kind == "group":
                apple.group["attributes"]["name"] = "Other group"
            elif kind == "link":
                apple.group["attributes"]["publicLinkEnabled"] = False
            else:
                apple.builds[0][1].clear()
            with self.subTest(kind=kind), self.assertRaises(APP.Error):
                sync(discord, apple)
            self.assertEqual(discord.writes, [])

    def test_dotted_builds_sort_numerically_and_future_builds_without_github_notes_work(self):
        apple = Apple(build(number="56.10"), build(number="57"), build(number="56.2"))
        releases = APP.available_builds(apple, (56, 0, 0))
        self.assertEqual([item["build"] for item in releases], ["56.2", "56.10", "57"])
        embed = APP.announcement(releases[-1], {"releases": []}, [{"tag_name": "release/057", "draft": True}])
        self.assertEqual("Plozz build 57 is on TestFlight", embed["title"])
        self.assertNotIn("2026.9.25", embed["title"])
        self.assertIn("notes are available in TestFlight", embed["description"])
        self.assertNotIn("/releases/tag/", embed["description"])

    def test_check_is_read_only(self):
        discord = Discord()
        sync(discord, Apple(build()), publish=False)
        self.assertEqual(discord.writes, [])

    def test_available_build_outside_external_group_does_not_announce(self):
        discord, apple = Discord(), Apple(build())
        apple.member_ids = []
        sync(discord, apple)
        self.assertEqual(discord.writes, [])

    def test_ambiguous_create_is_recovered_without_duplicate(self):
        discord, apple = Discord(), Apple(build())
        discord.fail_after_create = True
        with self.assertRaises(APP.Error):
            sync(discord, apple)
        sync(discord, apple)
        self.assertEqual(len(discord.messages), 1)
        self.assertEqual(len(discord.writes), 1)

    def test_copied_human_marker_is_ignored_but_duplicate_bot_markers_fail(self):
        discord, apple = Discord(), Apple(build())
        sync(discord, apple)
        human = copy.deepcopy(discord.messages[0])
        human.update(id="2000", author={"id": "person"})
        discord.messages.append(human)
        sync(discord, apple)
        self.assertEqual(len(discord.writes), 1)
        discord.messages.append(copy.deepcopy(discord.messages[0]))
        with self.assertRaisesRegex(APP.Error, "Duplicate"):
            sync(discord, apple)

    def test_duplicate_platform_identity_fails(self):
        with self.assertRaisesRegex(APP.Error, "Duplicate available"):
            APP.available_builds(Apple(build(), build()), (56, 0, 0))


class RoadmapLinkTests(unittest.TestCase):
    def test_every_announcement_variant_includes_link_only_after_activation(self):
        for number in ("56", "56.5"):
            catalog = catalog_fixture(number)
            for platforms in ({"TV_OS"}, {"IOS"}, {"TV_OS", "IOS"}):
                release = {"build": number, "marketing": "2026.9.25", "platforms": platforms}
                for source in (catalog, {"releases": []}):
                    for published in (False, True):
                        if published and not source["releases"]:
                            continue
                        github_releases = [
                            {"tag_name": APP.NOTES.release_tag(number), "draft": False}
                        ] if published else []
                        with self.subTest(number=number, platforms=platforms, published=published, source=source):
                            baseline = APP.announcement(release, source, github_releases)
                            self.assertNotIn(APP.ROADMAP, baseline["description"])
                            self.assertEqual(baseline, APP.announcement(
                                release, source, github_releases, roadmap_enabled=False,
                            ))
                            enabled = APP.announcement(release, source, github_releases, roadmap_enabled=True)
                            self.assertEqual(enabled["description"].count(f"[Roadmap]({APP.ROADMAP})"), 1)
                            self.assertEqual(enabled["title"], baseline["title"])
                            self.assertEqual(enabled["url"], baseline["url"])

    def test_activation_and_disabling_edit_existing_message_once(self):
        discord, apple = Discord(), Apple(build(), build("IOS"))
        sync(discord, apple)
        original = copy.deepcopy(discord.messages[0])
        discord.writes.clear()
        sync(discord, apple, roadmap_enabled=True)
        sync(discord, apple, roadmap_enabled=True)
        self.assertEqual([write[0] for write in discord.writes], ["PATCH"])
        self.assertEqual(len(discord.messages), 1)
        self.assertEqual(discord.messages[0]["id"], original["id"])
        self.assertEqual(discord.messages[0]["embeds"][0]["footer"], original["embeds"][0]["footer"])
        self.assertEqual(discord.writes[0][2]["allowed_mentions"]["parse"], [])
        discord.writes.clear()
        sync(discord, apple)
        sync(discord, apple)
        self.assertEqual([write[0] for write in discord.writes], ["PATCH"])
        self.assertEqual(discord.messages[0]["embeds"], original["embeds"])

    def test_enabled_preview_does_not_write(self):
        discord = Discord()
        sync(discord, Apple(build()), publish=False, roadmap_enabled=True)
        self.assertEqual(discord.writes, [])

    def test_cli_uses_only_the_separate_explicit_link_activation(self):
        for value in (None, "", "false", "TRUE", "true"):
            environment = {"TESTFLIGHT_DISCORD_MIN_BUILD": "56", "DISCORD_ROADMAP_ENABLED": "true"}
            if value is not None:
                environment["DISCORD_ROADMAP_LINK_ENABLED"] = value
            with self.subTest(value=value), patch.dict(os.environ, environment, clear=True), \
                    patch.object(APP.sys, "argv", ["script", "--mode", "check"]), \
                    patch.object(APP.BRIDGE, "API"), patch.object(APP, "apple_token"), \
                    patch.object(APP.NOTES, "load_catalog"), patch.object(APP, "synchronize") as synchronize:
                self.assertEqual(APP.main(), 0)
                self.assertEqual(synchronize.call_args.kwargs["roadmap_enabled"], value == "true")
                self.assertFalse(synchronize.call_args.kwargs["publish"])
        self.assertIn("DISCORD_ROADMAP_LINK_ENABLED: ${{ vars.DISCORD_ROADMAP_LINK_ENABLED }}", WORKFLOW)


class ReleaseIdentityTests(unittest.TestCase):
    def test_published_tag_supplies_date_when_main_catalog_lacks_build(self):
        discord = Discord()
        github = github_fixture(catalog_fixture(57, "2026.10.17", "2026-10-17"))
        sync(discord, Apple(build(number="57"), build("IOS", number="57")), github=github)
        self.assertEqual(discord.messages[0]["embeds"][0]["title"], "Plozz 2026.10.17 (57) is on TestFlight")
        github.call.assert_called_once_with(
            "GET", f"/repos/{BRIDGE.REPO}/contents/App/Resources/ReleaseNotes.json",
            query={"ref": "refs/tags/release/057"},
        )

    def test_tagged_catalog_wins_over_a_changed_main_entry(self):
        discord = Discord()
        changed_main = catalog_fixture(version="2026.10.16", released_at="2026-10-16")
        changed_main["releases"][0]["sections"][0]["items"] = ["Unshipped changes on main."]
        sync(discord, Apple(build()), catalog=changed_main)
        self.assertEqual(discord.messages[0]["embeds"][0]["title"], "Plozz 2026.10.14 (56) is on TestFlight")
        self.assertIn("Playback improvements.", discord.messages[0]["embeds"][0]["description"])
        self.assertNotIn("Unshipped changes", discord.messages[0]["embeds"][0]["description"])

    def test_existing_incorrect_announcement_is_repaired_once_without_duplicate(self):
        discord, apple = Discord(), Apple(build(number="57"), build("IOS", number="57"))
        github = github_fixture(catalog_fixture(57, "2026.10.17", "2026-10-17"))
        unpublished = Mock(pages=Mock(return_value=[]))
        sync(discord, apple, github=unpublished)
        discord.messages[0]["embeds"][0]["title"] = "Plozz 2026.9.25 (57) is on TestFlight"
        original = copy.deepcopy(discord.messages[0])
        discord.writes.clear()
        sync(discord, apple, github=github)
        sync(discord, apple, github=github)
        self.assertEqual(len(discord.messages), 1)
        self.assertEqual(discord.messages[0]["id"], original["id"])
        self.assertEqual(discord.messages[0]["embeds"][0]["footer"], original["embeds"][0]["footer"])
        self.assertEqual(discord.messages[0]["embeds"][0]["title"], "Plozz 2026.10.17 (57) is on TestFlight")
        self.assertEqual([item[0] for item in discord.writes], ["PATCH"])
        self.assertEqual(discord.writes[0][2]["allowed_mentions"]["parse"], [])
        unpublished.call.assert_not_called()

    def test_check_resolves_tagged_identity_without_discord_writes(self):
        discord = Discord()
        github = github_fixture(catalog_fixture(57, "2026.10.17", "2026-10-17"))
        sync(discord, Apple(build(number="57")), github=github, publish=False)
        github.call.assert_called_once()
        self.assertEqual(discord.writes, [])

    def test_unpublished_release_uses_local_public_date_or_build_only(self):
        for releases in ([], [{"tag_name": "release/056", "draft": True}]):
            for catalog, title in (
                (catalog_fixture(), "Plozz 2026.10.14 (56) is on TestFlight"),
                ({"releases": []}, "Plozz build 56 is on TestFlight"),
            ):
                with self.subTest(releases=releases, catalog=catalog):
                    discord, github = Discord(), Mock(pages=Mock(return_value=releases))
                    sync(discord, Apple(build()), github=github, catalog=catalog)
                    self.assertEqual(discord.messages[0]["embeds"][0]["title"], title)
                    self.assertNotIn("Playback improvements.", discord.messages[0]["embeds"][0]["description"])
                    github.call.assert_not_called()

    def test_invalid_tagged_catalog_fails_without_falling_back_to_main(self):
        wrong_marketing = catalog_fixture()
        wrong_marketing["releases"][0]["marketingVersion"] = "2026.10.14"
        wrong_id = catalog_fixture()
        wrong_id["releases"][0]["id"] = "release/057"
        wrong_date = catalog_fixture()
        wrong_date["releases"][0]["version"] = "2026.10.17"
        responses = [
            None, {"type": "dir"}, {"type": "file", "encoding": "none", "content": ""},
            {"type": "file", "encoding": "base64", "content": "not base64!"},
            {"type": "file", "encoding": "base64", "content": base64.b64encode(b"{").decode()},
            catalog_response([]), catalog_response({"schemaVersion": 2, "releases": []}),
            catalog_response({"schemaVersion": 1, "releases": []}),
            catalog_response(catalog_fixture(57)), catalog_response(wrong_marketing),
            catalog_response(wrong_id), catalog_response(wrong_date),
        ]
        for response in responses:
            with self.subTest(response=response):
                discord, github = Discord(), github_fixture(catalog_fixture())
                github.call.return_value = response
                with self.assertRaises(APP.Error):
                    sync(discord, Apple(build()), github=github)
                self.assertEqual(discord.writes, [])

    def test_tag_fetch_failure_is_not_a_success_shaped_fallback(self):
        discord, github = Discord(), github_fixture(catalog_fixture())
        github.call.side_effect = APP.Error("GitHub GET failed (HTTP 503).")
        with self.assertRaisesRegex(APP.Error, "HTTP 503"):
            sync(discord, Apple(build()), github=github)
        self.assertEqual(discord.writes, [])

    def test_hotfix_tag_and_apple_version_keep_their_exact_identities(self):
        discord = Discord()
        github = github_fixture(catalog_fixture("56.5", "2026.10.15", "2026-10-15"))
        sync(discord, Apple(build(number="56.5")), github=github)
        self.assertEqual(discord.messages[0]["embeds"][0]["title"], "Plozz 2026.10.15 (56.5) is on TestFlight")
        self.assertEqual(github.call.call_args.kwargs["query"], {"ref": "refs/tags/release/056.5"})
        self.assertIn("testflight:2026.9.25:56.5.0", discord.messages[0]["embeds"][0]["footer"]["text"])

    def test_duplicate_published_release_is_rejected_before_fetching_or_writing(self):
        discord, github = Discord(), github_fixture(catalog_fixture())
        github.pages.return_value *= 2
        with self.assertRaisesRegex(APP.Error, "Duplicate published"):
            sync(discord, Apple(build()), github=github)
        github.call.assert_not_called()
        self.assertEqual(discord.writes, [])


class InlineNotesTests(unittest.TestCase):
    def scoped_catalog(self):
        catalog = catalog_fixture()
        catalog["releases"][0]["sections"] = [
            {"category": "New", "items": [
                "A shared feature.",
                {"text": "A TV feature.", "platforms": ["tvOS"]},
                {"text": "A mobile feature.", "platforms": ["iOS"]},
                {"text": "Explicitly shared.", "platforms": ["tvOS", "iOS"]},
            ]},
            {"category": "Updated", "items": ["Shared improvements."]},
            {"category": "Fixed", "items": [{"text": "Mobile fix.", "platforms": ["iOS"]}]},
        ]
        return catalog

    def test_shared_notes_once_and_scoped_notes_labeled_in_category_order(self):
        catalog, discord = self.scoped_catalog(), Discord()
        sync(discord, Apple(build(), build("IOS")), github=github_fixture(catalog), catalog=catalog)
        description = discord.messages[0]["embeds"][0]["description"]
        self.assertEqual(description.count("A shared feature."), 1)
        self.assertIn("• **Apple TV:** A TV feature.", description)
        self.assertIn("• **iPhone and iPad:** A mobile feature.", description)
        self.assertIn("• Explicitly shared.", description)
        self.assertLess(description.index("**New**"), description.index("**Updated**"))
        self.assertLess(description.index("**Updated**"), description.index("**Fixed**"))

    def test_pending_platform_notes_appear_only_when_available_on_the_same_message(self):
        catalog, discord = self.scoped_catalog(), Discord()
        github = github_fixture(catalog)
        sync(discord, Apple(build(), build("IOS", external="WAITING_FOR_BETA_REVIEW")), github=github)
        description = discord.messages[0]["embeds"][0]["description"]
        self.assertIn("• A TV feature.", description)
        self.assertNotIn("mobile feature", description)
        self.assertNotIn("Mobile fix", description)
        self.assertNotIn("**Fixed**", description)
        sync(discord, Apple(build(), build("IOS")), github=github)
        self.assertEqual([write[0] for write in discord.writes], ["POST", "PATCH"])
        self.assertEqual(len(discord.messages), 1)
        self.assertIn("Mobile fix", discord.messages[0]["embeds"][0]["description"])

    def test_available_platform_with_no_changes_uses_the_release_fallback(self):
        catalog = catalog_fixture()
        catalog["releases"][0]["sections"][0]["items"] = [{"text": "Mobile only.", "platforms": ["iOS"]}]
        discord = Discord()
        sync(discord, Apple(build()), github=github_fixture(catalog))
        description = discord.messages[0]["embeds"][0]["description"]
        self.assertIn("No changes for this platform in this build.", description)
        self.assertNotIn("Mobile only.", description)

    def test_long_notes_keep_complete_bullets_and_stay_under_discord_limits(self):
        catalog = catalog_fixture()
        bullets = [f"Change {index}: " + "\U0001f3ac" * 150 + " Complete." for index in range(25)]
        catalog["releases"][0]["sections"] = [{"category": "Updated", "items": bullets}]
        discord = Discord()
        sync(discord, Apple(build(), build("IOS")), github=github_fixture(catalog), roadmap_enabled=True)
        embed = discord.messages[0]["embeds"][0]
        description = embed["description"]
        self.assertLessEqual(len(description.encode("utf-16-le")) // 2, 4096)
        self.assertLessEqual(sum(len(value.encode("utf-16-le")) // 2 for value in [
            embed["title"], description, embed["footer"]["text"],
        ]), 6000)
        included = [line.removeprefix("• ") for line in description.splitlines() if line.startswith("• ")]
        self.assertGreater(len(included), 0)
        self.assertEqual(included, bullets[:len(included)])
        self.assertIn("Notes shortened to fit Discord.", description)
        self.assertIn("/releases/tag/release/056", description)
        self.assertIn(f"[Roadmap]({APP.ROADMAP})", description)
        sync(discord, Apple(build(), build("IOS")), github=github_fixture(catalog), roadmap_enabled=True)
        self.assertEqual(len(discord.writes), 1)

    def test_one_oversized_bullet_is_not_cut_or_replaced_with_a_later_note(self):
        catalog = catalog_fixture()
        catalog["releases"][0]["sections"] = [
            {"category": "New", "items": ["Long note " + "x" * 4096]},
            {"category": "Fixed", "items": ["Later fix."]},
        ]
        discord = Discord()
        sync(discord, Apple(build()), github=github_fixture(catalog))
        description = discord.messages[0]["embeds"][0]["description"]
        self.assertNotIn("Long note", description)
        self.assertNotIn("Later fix", description)
        self.assertNotIn("**New**", description)
        self.assertIn("Notes shortened", description)

    def test_exact_description_limit_is_complete_and_one_unit_over_is_explicit(self):
        entry = catalog_fixture()["releases"][0]
        prefix = "Available.\n\n**Updated**\n• "
        text = "\U0001f3ac" * 100
        text += "x" * (4096 - len((prefix + text).encode("utf-16-le")) // 2)
        entry["sections"][0]["items"] = [text]
        description = APP.with_release_notes("Available.", entry, {"TV_OS"}, "https://example.com/notes")
        self.assertEqual(len(description.encode("utf-16-le")) // 2, 4096)
        self.assertNotIn("shortened", description)
        entry["sections"][0]["items"] = [text + "x"]
        description = APP.with_release_notes("Available.", entry, {"TV_OS"}, "https://example.com/notes")
        self.assertLessEqual(len(description.encode("utf-16-le")) // 2, 4096)
        self.assertIn("Notes shortened", description)

    def test_notes_are_added_to_existing_messages_without_duplicate_or_mentions(self):
        discord = Discord()
        sync(discord, Apple(build()), github=Mock(pages=Mock(return_value=[])))
        catalog = catalog_fixture()
        catalog["releases"][0]["sections"][0]["items"] = ["Improved @everyone and <@123> display."]
        sync(discord, Apple(build()), github=github_fixture(catalog))
        self.assertEqual(len(discord.messages), 1)
        self.assertEqual([write[0] for write in discord.writes], ["POST", "PATCH"])
        self.assertEqual(discord.writes[-1][2]["allowed_mentions"]["parse"], [])


class PermissionTests(unittest.TestCase):
    def test_wrong_channel_or_bot_is_refused(self):
        discord = Discord()
        discord.channel["guild_id"] = "another-guild"
        with self.assertRaises(APP.Error):
            APP.inspect_channel(discord)
        with self.assertRaises(APP.Error):
            APP.inspect_channel(Mock(call=Mock(return_value={"id": "another-bot", "bot": True})))

    def test_each_required_permission_is_verified_before_history_reads(self):
        for bit in (10, 11, 14, 16):
            discord = Discord()
            discord.permissions &= ~(1 << bit)
            with self.subTest(bit=bit), self.assertRaisesRegex(APP.Error, "lacks permissions in channel"):
                APP.inspect_channel(discord)

    def test_channel_denial_and_member_allow_use_discord_precedence(self):
        discord = Discord()
        discord.channel["permission_overwrites"] = [
            {"id": BRIDGE.GUILD, "type": 0, "allow": "0", "deny": str(1 << 16)},
            {"id": "100", "type": 0, "allow": str(1 << 16), "deny": "0"},
            {"id": BRIDGE.BOT, "type": 1, "allow": "0", "deny": str(1 << 11)},
        ]
        with self.assertRaisesRegex(APP.Error, "Send Messages"):
            APP.inspect_channel(discord)
        discord.channel["permission_overwrites"][-1].update(allow=str(1 << 11), deny="0")
        APP.inspect_channel(discord)

    def test_administrator_does_not_require_extra_permissions(self):
        discord = Discord()
        discord.permissions = 1 << 3
        APP.inspect_channel(discord)


class BoundaryTests(unittest.TestCase):
    def test_apple_client_never_permits_writes(self):
        with self.assertRaises(APP.Error):
            BRIDGE.API("App Store Connect", "test-token", write=True)
        client = BRIDGE.API("App Store Connect", "test-token")
        self.assertEqual(client.base, "https://api.appstoreconnect.apple.com/v1")
        self.assertEqual(client.authorization, "Bearer test-token")
        with self.assertRaises(APP.Error):
            client.call("POST", "/apps", {})

    def test_pagination_uses_all_pages_and_refuses_off_origin_urls_or_cycles(self):
        client = Mock()
        client.call.side_effect = [
            {"data": [1], "links": {"next": "https://api.appstoreconnect.apple.com/v1/apps?cursor=next"}},
            {"data": [2]},
        ]
        self.assertEqual(APP.apple_collection(client, "/apps")[0], [1, 2])
        for url in (
            "https://attacker.example/v1/apps", "http://api.appstoreconnect.apple.com/v1/apps",
            "https://api.appstoreconnect.apple.com@attacker.example/v1/apps",
            "https://api.appstoreconnect.apple.com/not-v1/apps",
        ):
            with self.subTest(url=url), self.assertRaises(APP.Error):
                APP.apple_collection(Mock(call=Mock(return_value={"data": [], "links": {"next": url}})), "/apps")
        with self.assertRaisesRegex(APP.Error, "no progress"):
            APP.apple_collection(Mock(call=Mock(return_value={
                "data": [], "links": {"next": "https://api.appstoreconnect.apple.com/v1/apps"},
            })), "/apps")

    def test_pagination_preserves_included_resources_and_rejects_changed_details(self):
        detail = {"type": "buildBetaDetails", "id": "build", "attributes": {"externalBuildState": "IN_BETA_TESTING"}}
        first = {"data": [1], "included": [detail], "links": {
            "next": "https://api.appstoreconnect.apple.com/v1/builds?cursor=next",
        }}
        client = Mock(call=Mock(side_effect=[first, {"data": [2]}]))
        data, included = APP.apple_collection(client, "/builds")
        self.assertEqual(data, [1, 2])
        self.assertEqual(included[("buildBetaDetails", "build")], detail)
        changed = {**detail, "attributes": {"externalBuildState": "EXPIRED"}}
        with self.assertRaisesRegex(APP.Error, "changed related data"):
            APP.apple_collection(Mock(call=Mock(side_effect=[first, {"data": [], "included": [changed]}])), "/builds")

    @unittest.skipUnless(importlib.util.find_spec("jwt"), "JWT signing dependency is installed in the live job")
    def test_jwt_signing_is_short_lived_and_invalid_keys_are_not_disclosed(self):
        import jwt
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec

        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption(),
        ).decode()
        env = {"ASC_KEY_ID": "key-id", "ASC_ISSUER_ID": "issuer-id", "ASC_PRIVATE_KEY": pem}
        with patch.dict(os.environ, env):
            token = APP.apple_token()
            claims = jwt.decode(token, key.public_key(), algorithms=["ES256"], audience="appstoreconnect-v1")
            self.assertEqual(claims["iss"], "issuer-id")
            self.assertEqual(claims["exp"] - claims["iat"], 630)
            self.assertEqual(jwt.get_unverified_header(token)["kid"], "key-id")
        with patch.dict(os.environ, {**env, "ASC_PRIVATE_KEY": "never-print-this-key"}):
            with self.assertRaises(APP.Error) as failure:
                APP.apple_token()
            self.assertNotIn("never-print-this-key", str(failure.exception))

    def test_sync_requires_activation_and_explicit_history_floor(self):
        for environment in ({}, {"TESTFLIGHT_DISCORD_MIN_BUILD": "56"}):
            with patch.dict(os.environ, environment, clear=True), patch.object(APP.sys, "argv", ["script", "--mode", "sync"]):
                with patch("sys.stderr", new_callable=io.StringIO):
                    self.assertEqual(APP.main(), 1)

    def test_workflow_does_not_expose_secrets_on_push_and_uses_main_for_live_runs(self):
        test_job = WORKFLOW.split("  test:", 1)[1].split("  announce:", 1)[0]
        self.assertNotIn("secrets.", test_job)
        self.assertIn("ref: main", WORKFLOW)
        self.assertIn("cancel-in-progress: false", WORKFLOW)
        self.assertIn("types: [published]", WORKFLOW)
        self.assertIn("TESTFLIGHT_DISCORD_ENABLED == 'true'", WORKFLOW)
        self.assertIn("contents: read", WORKFLOW)
        self.assertNotIn("issues: write", WORKFLOW)
        self.assertNotIn("COPILOT", WORKFLOW)


if __name__ == "__main__":
    unittest.main()
