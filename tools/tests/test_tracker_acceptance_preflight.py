import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("tracker_preflight", ROOT / "tools/tracker-acceptance-preflight.py")
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
KEY = "pm-" + "a" * 60
MOVIE = {"tmdb_id": 550, "media_type": "movie"}
EPISODE = {"tmdb_id": 1396, "media_type": "tv", "season": 0, "episode": 1}
DATE = "2026-10-24T12:00:00.000Z"


def config(provider="jellyfin", episode=False):
    case = {"caseID": "first", "provider": provider, "itemID": "item-a",
            "content": copy.deepcopy(EPISODE if episode else MOVIE)}
    if episode:
        case.update(seriesItemID="series-a", episodeOrder="tmdb")
    return {"schemaVersion": 1, "publicMetaDB": {
        "tokenKeychainService": "test-only", "tokenKeychainAccount": "pmdb", "ownedTestListID": "owned-a",
    }, "servers": {provider: {
        "baseURL": "https://server.test", "serverID": "server-a", "userID": "user-a",
        "tokenKeychainService": "test-only", "tokenKeychainAccount": provider,
    }}, "titles": [case]}


def page(items, *, size=500, number=1, total=None):
    total = len(items) if total is None else total
    return {"items": items, "page": number, "perPage": size, "total": total,
            "totalPages": (total + size - 1) // size}


def jellyfin_item():
    return {"Id": "item-a", "Type": "Movie", "ProviderIds": {"Tmdb": "550"}, "RunTimeTicks": 1000000000,
            "UserData": {"Played": False, "PlaybackPositionTicks": 300000000, "PlayCount": 0}}


class FakeHTTP:
    def __init__(self, values):
        self.values = {path: list(responses) for path, responses in values.items()}
        self.calls = []

    def get(self, base, path, headers, query=None):
        self.calls.append((base, path, headers, query))
        if path not in self.values or not self.values[path]:
            raise AssertionError("Unexpected independent read: " + path)
        return self.values[path].pop(0)


def transport(item=None):
    return FakeHTTP({
        "/api/external/lists": [page([{"id": "owned-a", "name": "Private test"}])],
        "/System/Info/Public": [{"Id": "server-a"}],
        "/Users/Me": [{"Id": "user-a"}],
        "/Users/user-a/Items/item-a": [item or jellyfin_item()],
        "/api/external/watched": [page([])],
        "/api/external/resume": [page([])],
    })


class TrackerAcceptancePreflightTests(unittest.TestCase):
    def test_private_preflight_is_never_app_acceptance_and_projects_only_allowlisted_state(self):
        for provider in ("jellyfin", "emby"):
            with self.subTest(provider=provider):
                http = transport()
                # Unrelated response data must never be copied to the evidence file.
                http.values["/Users/Me"][0]["Password"] = "not-for-evidence"
                result = reader.baseline(config(provider), http, lambda _: KEY)
                self.assertFalse(result["acceptanceVerified"])
                self.assertEqual(result["kind"], "read-only-tracker-preflight")
                self.assertEqual(result["writesAttempted"], 0)
                self.assertEqual(result["serverCredentialSHA256"], {
                    provider: hashlib.sha256(KEY.encode()).hexdigest()
                })
                self.assertEqual(result["cases"][0]["server"]["state"]["positionMilliseconds"], 30000)
                self.assertEqual(result["cases"][0]["server"]["runtimeMilliseconds"], 100000)
                self.assertNotIn(KEY, json.dumps(result))
                self.assertNotIn("not-for-evidence", json.dumps(result))
                self.assertNotIn("server.test", json.dumps(result))
                for _, path, _, query in http.calls:
                    if path in ("/api/external/watched", "/api/external/resume"):
                        self.assertEqual({name: query[name] for name in MOVIE}, MOVIE)

    def test_owned_test_list_is_required_without_inventing_an_account_profile_endpoint(self):
        http = transport()
        http.values["/api/external/lists"] = [page([{"id": "foreign"}])]
        with self.assertRaisesRegex(reader.Failure, "account scope is unverified"):
            reader.baseline(config(), http, lambda _: KEY)
        self.assertEqual(len(http.calls), 1)

    def test_wrong_user_or_server_blocks_item_and_tracker_reads(self):
        for path in ("/Users/Me", "/System/Info/Public"):
            http = transport()
            http.values[path] = [{"Id": "wrong"}]
            with self.assertRaises(reader.Failure):
                reader.baseline(config(), http, lambda _: KEY)
            self.assertFalse(any("Items" in call[1] or "watched" in call[1] for call in http.calls))

    def test_movies_require_authoritative_tmdb_not_title_or_episode_ids(self):
        for replacement in ({}, {"Imdb": "tt0137523"}, {"Tmdb": "999"}, {"Tmdb": "550", "TMDB": "999"}):
            item = jellyfin_item()
            item["ProviderIds"] = replacement
            with self.assertRaisesRegex(reader.Failure, "TMDB"):
                reader.baseline(config(), transport(item), lambda _: KEY)

    def test_episode_uses_series_id_including_specials_and_rejects_combined_files(self):
        item = jellyfin_item()
        item.update(Type="Episode", SeriesId="series-a", ParentIndexNumber=0, IndexNumber=1,
                    ProviderIds={"Tmdb": "episode-id-not-show"})
        http = transport(item)
        http.values["/Users/user-a/Items/series-a"] = [
            {"Id": "series-a", "Type": "Series", "ProviderIds": {"Tmdb": "1396"}}
        ]
        result = reader.baseline(config(episode=True), http, lambda _: KEY)
        self.assertEqual(result["cases"][0]["content"], EPISODE)
        for field, value in (("IndexNumberEnd", 2), ("SeriesId", "different"), ("ParentIndexNumber", 1)):
            changed = dict(item, **{field: value})
            with self.assertRaisesRegex(reader.Failure, "episode identity"):
                reader.baseline(config(episode=True), transport(changed), lambda _: KEY)

    def test_missing_and_malformed_server_state_cannot_become_unwatched_or_zero(self):
        for field in ("Played", "PlaybackPositionTicks", "PlayCount"):
            item = jellyfin_item()
            del item["UserData"][field]
            with self.assertRaises(reader.Failure):
                reader.baseline(config(), transport(item), lambda _: KEY)
        for value in (-1, float("nan"), float("inf"), True, 1000000001):
            item = jellyfin_item()
            item["UserData"]["PlaybackPositionTicks"] = value
            with self.assertRaises(reader.Failure):
                reader.baseline(config(), transport(item), lambda _: KEY)

    def test_pagination_completes_all_pages_and_rejects_duplicates_totals_and_truncation(self):
        first = page([{"id": "a"}], size=1, total=2)
        second = page([{"id": "b"}], size=1, number=2, total=2)
        self.assertEqual(len(reader.complete_pages(FakeHTTP({"/api/external/lists": [first, second]}), KEY, "/lists")), 2)
        for changed in (
            page([{"id": "a"}], size=1, number=2, total=2),
            page([{"id": "b"}], size=1, number=2, total=3),
            dict(second, items=[]), dict(second, page=1), dict(second, totalPages=9),
            dict(second, perPage=True), dict(second, perPage=2),
        ):
            with self.subTest(changed=changed), self.assertRaises(reader.Failure):
                reader.complete_pages(FakeHTTP({"/api/external/lists": [first, changed]}), KEY, "/lists")
        pages = [page([{"id": f"r-{i}"}], size=1, number=i, total=21) for i in range(1, 21)]
        with self.assertRaisesRegex(reader.Failure, "budget"):
            reader.complete_pages(FakeHTTP({"/api/external/lists": pages}), KEY, "/lists")

    def test_watched_dates_distinguish_unknown_missing_and_invalid(self):
        for date in (None, DATE):
            http = transport()
            http.values["/api/external/watched"] = [page([dict(MOVIE, id="watch", watched_at=date)])]
            result = reader.baseline(config(), http, lambda _: KEY)
            self.assertEqual(result["cases"][0]["tracker"]["watched"][0]["watchedAt"], date)
        for record in (dict(MOVIE, id="watch"), dict(MOVIE, id="watch", watched_at="2026-10-24"),
                       dict(MOVIE, id="watch", watched_at=1000), dict(MOVIE, id="watch", watched_at="invalid")):
            http = transport()
            http.values["/api/external/watched"] = [page([record])]
            with self.assertRaises(reader.Failure):
                reader.baseline(config(), http, lambda _: KEY)

    def test_unfiltered_or_ambiguous_tracker_results_do_not_pass(self):
        for records in (
            [dict(MOVIE, tmdb_id=999, id="a", position_ms=30000, runtime_ms=100000)],
            [dict(MOVIE, id=i, position_ms=30000, runtime_ms=100000) for i in ("a", "b")],
            [dict(MOVIE, id="a", position_ms=100001, runtime_ms=100000)],
        ):
            http = transport()
            http.values["/api/external/resume"] = [page(records)]
            with self.assertRaises(reader.Failure):
                reader.baseline(config(), http, lambda _: KEY)

    def test_plex_independent_server_user_and_catalog_checks_preserve_absent_fields(self):
        cfg = config("plex")
        cfg["servers"]["plex"]["userID"] = "42"
        metadata = {"ratingKey": "item-a", "type": "movie", "duration": 100000, "Guid": [{"id": "tmdb://550"}]}
        http = FakeHTTP({
            "/api/external/lists": [page([{"id": "owned-a"}])],
            "/identity": [{"MediaContainer": {"machineIdentifier": "server-a"}}],
            "/api/v2/user": [{"id": 42}],
            "/library/metadata/item-a": [{"MediaContainer": {"Metadata": [metadata]}}],
            "/api/external/watched": [page([])],
            "/api/external/resume": [page([])],
        })
        result = reader.baseline(cfg, http, lambda _: KEY)
        self.assertEqual(result["cases"][0]["server"]["state"],
                         {"viewCount": None, "viewOffset": None, "lastViewedAt": None})
        identity_calls = [call for call in http.calls if call[1] == "/api/v2/user"]
        self.assertEqual(identity_calls[0][0], "https://plex.tv")
        wrong = dict(metadata, Guid=[{"id": "tmdb://550"}, {"id": "tmdb://999"}])
        with self.assertRaises(reader.Failure):
            reader.server_state(FakeHTTP({"/library/metadata/item-a": [{"MediaContainer": {"Metadata": [wrong]}}]}),
                                "plex", cfg["servers"]["plex"], KEY, cfg["titles"][0])

    def test_configuration_rejects_unscoped_titles_credentials_and_servers_before_access(self):
        mutations = [
            lambda c: c.update(schemaVersion=True),
            lambda c: c.update(titles=[]),
            lambda c: c["titles"].append(copy.deepcopy(c["titles"][0])),
            lambda c: c["titles"][0].update(itemID="../wrong"),
            lambda c: c["titles"][0].update(content=dict(MOVIE, tmdb_id=True)),
            lambda c: c["publicMetaDB"].update(ownedTestListID=""),
            lambda c: c["servers"]["jellyfin"].update(baseURL="https://server.test/?api_key=secret"),
            lambda c: c["servers"]["jellyfin"].update(baseURL="https://user:password@server.test"),
            lambda c: c["servers"]["jellyfin"].update(baseURL="https://server.test:bad"),
            lambda c: c["servers"].update(silo=copy.deepcopy(c["servers"]["jellyfin"])),
            lambda c: c["publicMetaDB"].pop("tokenKeychainService"),
        ]
        for mutation in mutations:
            cfg = config()
            mutation(cfg)
            with self.assertRaises(reader.Failure):
                reader.validate_config(cfg)
        cfg = config(episode=True)
        cfg["titles"][0]["episodeOrder"] = "aired"
        with self.assertRaises(reader.Failure):
            reader.validate_config(cfg)

    def test_http_is_get_only_no_cache_and_never_reports_response_bodies(self):
        opener = MagicMock()
        response = opener.open.return_value.__enter__.return_value
        response.status, response.read.return_value = 200, b'{"ok":true}'
        http = reader.ReadOnlyHTTP(opener=opener)
        self.assertTrue(http.get(reader.PMDB, "/api/external/lists", {"Authorization": "Bearer " + KEY})["ok"])
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)
        self.assertEqual(request.get_header("Cache-control"), "no-cache")
        self.assertEqual(request.get_header("User-agent"),
                         "Plozz-Tracker-Acceptance/1.0 (read-only integration verification)")
        self.assertNotIn(KEY, request.full_url)
        for code in (302, 401, 403, 429, 500):
            opener.reset_mock()
            opener.open.side_effect = urllib.error.HTTPError("https://private.test", code, "secret", {}, io.BytesIO(b"secret"))
            with self.assertRaises(reader.Failure) as caught:
                reader.ReadOnlyHTTP(opener=opener).get(reader.PMDB, "/api/external/lists", {})
            self.assertNotIn("secret", str(caught.exception))
            self.assertNotIn("private.test", str(caught.exception))
            self.assertEqual(opener.open.call_count, 1)
        self.assertIsNone(reader._playback.NoRedirect().redirect_request(None, None, 302, "", {}, "https://foreign.test"))

    def test_deadline_http_partial_large_and_nonfinite_responses_fail_closed(self):
        opener = MagicMock()
        with self.assertRaises(reader.Failure):
            reader.ReadOnlyHTTP(budget=-1, opener=opener).get(reader.PMDB, "/api/external/lists", {})
        opener.open.assert_not_called()
        response = opener.open.return_value.__enter__.return_value
        for status, body in ((207, b"{}"), (200, b"x" * (8 * 1024 * 1024 + 1)),
                             (200, b'{"value":NaN}'), (200, b"not-json")):
            response.status, response.read.return_value = status, body
            with self.assertRaises(reader.Failure):
                reader.ReadOnlyHTTP(opener=opener).get(reader.PMDB, "/api/external/lists", {})

    def test_cli_enforces_private_config_and_never_overwrites_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            cfg = root / "input.json"
            cfg.write_text(json.dumps(config()))
            cfg.chmod(0o600)
            output = root / "evidence.json"
            with patch.object(reader, "baseline", return_value={"acceptanceVerified": False}), \
                    patch.object(reader.sys, "stdout", new_callable=io.StringIO), \
                    patch.object(reader.sys, "stderr", new_callable=io.StringIO), \
                    patch.object(reader.sys, "argv", ["preflight", "--config", str(cfg), "--output", str(output)]):
                self.assertEqual(reader.main(), 0)
                original = output.read_bytes()
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                self.assertEqual(reader.main(), 1)
                self.assertEqual(output.read_bytes(), original)
                output.unlink()
                cfg.chmod(0o644)
                self.assertEqual(reader.main(), 1)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
