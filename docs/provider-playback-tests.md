# Real-server playback checks

`tools/run-provider-playback-tests.py` exercises the production Jellyfin, Emby,
Plex, and Silo adapters, authenticated URL resolver, and native video engine against
real configured servers. It is opt-in: ordinary unit tests never contact a
server. Local/network shares are deliberately out of scope.
Every test player is muted before it can start. Audio decoding is verified from
stream bytes without sending sound to speakers; system volume is never changed.

Silo uses native protocol-3 quality preferences and bandwidth caps, validating
the returned recipe before playback. Its custom case uses the same total
1080p / 2,000 Kbps limit as the other adapters, reserving 192 Kbps for Silo's
stereo AAC output. Native Silo currently offers 480p/720p/1080p/4K conversion
with H.264 output; unsupported resolution/codec choices remain explicit.

## One-time setup

1. Generate a copyright-free video using
   `python3 tools/generate-playback-fixture.py`. It contains 90 seconds of moving
   1080p H.264 video and AAC stereo sine-wave audio. FFmpeg must already be
   installed; the generator does not install software or overwrite files.
2. Import it into a **dedicated test library/account** on each server. This is an
   ordinary playback test: start/stop reports can change the test item's resume
   state. Do not point it at a household user's normal movie.
3. Copy `tools/provider-playback.example.json` outside the repository, fill in the
   server/user/item IDs, and store each test-account token in Keychain using the
   configured `tokenKeychainService` and `tokenKeychainAccount`. The runner reads
   only those explicitly named entries. Keep the configuration owned by you and
   mode `600`; never commit credentials or pass tokens on the command line.
   The example's IDs are placeholders, not usable credentials.
   For Silo, the Keychain value is the JSON-encoded `SiloCredential` of a
   **dedicated test pairing**, including profile identity/proof, not just its
   access token. Its access grant must remain valid for the bounded run; the
   harness refuses refresh rather than rotate a credential without durably
   updating its Keychain owner. Do not clone a live household pairing.
4. Choose an explicitly owned iOS or tvOS simulator. All servers must be reachable
   from it. A VPN, Local Network permission, unsupported server setting, or missing
   subscription can make a live run fail; none is treated as a passing skip.
5. Start with `codecs: ["h264"]` for every provider. Silo also accepts the
   legacy `["server"]` alias, which now checks the H.264 custom-limit case.
   Add `"hevc"` only when the server's HEVC encoder
   is configured/entitled **and the destination advertises HEVC hardware decode**.
   The current iOS simulator does not; it fails explicitly with
   `clientHEVCUnavailable` rather than claiming to test HEVC through H.264.
   A configured codec is required to work: a silently
   substituted codec fails the case rather than giving a false green result.

## Run

```sh
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
python3 tools/run-provider-playback-tests.py \
  --sim-id YOUR_OWNED_SIMULATOR_ID --platform iOS \
  --config /absolute/private/playback-tests.json \
  --providers jellyfin,plex,emby,silo
```

Run the harness's configuration/playlist tests without any server:

```sh
python3 tools/run-provider-playback-tests.py \
  --sim-id YOUR_OWNED_SIMULATOR_ID --platform iOS --self-test
python3 -m unittest tools.tests.test_provider_playback_runner
```

Validate the entire harness with generated media and loopback API fixtures:

```sh
python3 tools/run-provider-playback-tests.py \
  --sim-id YOUR_OWNED_SIMULATOR_ID --platform iOS --fixture-self-test
```

This exercises all four production adapters, authenticated media URLs, H.264
streams, real video-frame/audio decoding, seek/pause/resume and cleanup. It reports
**synthetic-provider-contract-playback**, never real-provider success. The local
HTTP service is owned by the invocation and closed on success/failure; its
pre-encoded streams do not validate an actual server encoder or subscription.

`StreamingBufferingHostedTests` in the iOS/tvOS presentation test targets
separately delays the second segment of a synthetic H.264/AAC VOD stream by
20 seconds. It requires actual decoded frames and recovery at more than 90%
of the selected speed once the remaining segments are available, including a
paused/resumed case at 1.25x speed. An exploratory comparison found that both
immediate and automatically buffered playback can exhaust the first segment
during this unpredictable gap. The regression checks recovery, not a promise
of stall-free playback from an underpowered or stalled real encoder.
The test reuses the existing generated `iptv` media fixture and discontinuity
markers rather than adding captured content or contacting a live provider.

`--self-test` is explicitly labelled **harness-unit-tests**, not an end-to-end
result. To test one available server, explicitly select `--providers emby`, for
example. The report then names that narrower required set; it does not imply the
other providers were exercised. Missing required configuration fails before
building.

## What a live pass proves

For every selected provider:

- Maximum negotiates original playback of the native-compatible fixture.
- Custom **1080p / 2,000 Kbps**, including the audio budget,
  requests a forced rendition through the production provider; each configured
  codec is exercised. Silo validates its server's effective recipe and verifies
  the played H.264 rendition against the height and bitrate ceilings.
- AVPlayer produces actual decoded pixel buffers, not merely `readyToPlay`.
  Sustained frame delivery and clock advancement must continue for the configured
  observation window.
- The played video's encoded dimensions stay within the requested ceiling and
  its actual codec matches the case. Unit provider tests separately verify exact
  bitrate request fields. Variable-rate output is not a byte-meter cap.
- A chunk of the **served media bytes** is decoded to PCM with AVAssetReader.
  This proves the stream contains decodable audio samples; it does not prove an
  audible speaker route, correct loudness, Atmos passthrough, or HDMI behavior.
- Pause holds position, resume advances, a seek presents new frames, and the
  custom case also starts from a nonzero resume position.
- Providers with a session-maintenance capability must acknowledge a ping while
  their rendition is paused. This checks the exact owned session, not survival
  across the server's undocumented expiry interval or iOS app suspension.
- The owned transcode cleanup request is acknowledged. This is not independent
  observation of the server's OS process exiting.

Generated fixture libraries cover the baseline. HDR conversion should also be
run with a dedicated native-compatible HDR fixture and the server's actual
tone-mapping/HEVC settings; these tests do not manufacture HDR success from
source badges. Physical-device HDR, external audio routes, PiP, and background
transitions remain separate device checks.

## Evidence and safety

Each run keeps private evidence under `.build/provider-playback-tests/<run>/`:
the complete xcresult, machine-readable verdict, startup time/frame counts,
dimensions/codecs, audio sample count, seek results, and server-cleanup outcome.
Maximum's time-to-first-frame is recorded; compare the same fixture, device,
network and cold/warm conditions across builds rather than asserting that startup
has no regression from a single result.

The runner holds the shared Apple build lease, uses private package/build roots,
serial tests and hard process deadlines, and never deletes caches. Run it alone
in this worktree: it temporarily relocates the generated `.xcodeproj` so Xcode
uses the scoped Swift package scheme, then restores it in `finally`. If another
writer creates a conflicting project, both copies are preserved and the run
fails. No other checkout or session is touched.
Tokens remain in Keychain between runs. The simulator receives temporary mode-600
token files inside the private run directory; they are removed in `finally`
after owned-session cleanup. A hard host/process kill can prevent `finally`;
retain the private run directory and use its lease records for recovery before
removing those specific temporary credentials.

Each request uses a unique test device ID. Owned encoding IDs are recorded before
playing and removed after cleanup; the runner retries only remaining owned
leases after a timeout/failure. Redirects are refused during this recovery, and
credentials stay in headers. Failed cleanup is retained and fails the run; no
server-wide stop or daemon reset is used.

Retry a failed cleanup using the original private configuration:

```sh
python3 tools/run-provider-playback-tests.py \
  --config /absolute/private/playback-tests.json \
  --recover-run /absolute/worktree/.build/provider-playback-tests/EXACT_RUN_ID
```

This reads fresh test tokens from Keychain and retries only that run's retained
session/device IDs. It does not start playback or stop any other device/session.

Encrypted or byte-range playlists are not silently accepted by the audio-byte
probe. If a server returns one, the audio evidence fails explicitly until that
format is supported. Never replace that failure with a successful HTTP status or
a source metadata assertion.

## PublicMetaDB tracking acceptance: independent preflight

`tools/tracker-acceptance-preflight.py` is the read-only baseline component of
tracking acceptance, **not an app-driven round-trip test**. It does not launch
Plozz, play media, approve an import, change watch history, or clean up records.
Its output always contains `acceptanceVerified: false`. The app-driven playback,
confirmation/cancellation, coexistence and relaunch scenarios must still run
before tracking acceptance can be claimed.

Unlike the generated playback fixture above, tracking requires genuine
catalog-identified titles lawfully available on dedicated test server users.
Never associate generated media with a public TMDB title just to pass tracking.
Use a private mode-600 configuration outside the repository, with each token
already stored in the explicitly named Keychain item:

```json
{
  "schemaVersion": 1,
  "publicMetaDB": {
    "tokenKeychainService": "PlozzTrackingTests",
    "tokenKeychainAccount": "publicmetadb",
    "ownedTestListID": "REPLACE_WITH_DEDICATED_OWNED_LIST_ID"
  },
  "servers": {
    "jellyfin": {
      "baseURL": "https://YOUR_TEST_SERVER",
      "serverID": "REPLACE_WITH_SERVER_ID",
      "userID": "REPLACE_WITH_DEDICATED_USER_ID",
      "tokenKeychainService": "PlozzTrackingTests",
      "tokenKeychainAccount": "jellyfin"
    }
  },
  "titles": [
    {
      "caseID": "movie",
      "provider": "jellyfin",
      "itemID": "REPLACE_WITH_REAL_ITEM_ID",
      "content": { "tmdb_id": 550, "media_type": "movie" }
    }
  ]
}
```

The catalog ID above is only a format example: replace it with the actual
allowlisted title's ID. One to ten exact movie/episode cases are supported.
For an episode, use the **series** TMDB ID, `media_type: "tv"`, integer `season`
and `episode`, plus the case's `seriesItemID` and `episodeOrder: "tmdb"`.
Only set that ordering declaration after confirming the server's coordinates
match TMDB; the reader cannot establish edition/order equivalence from a title.
Combined Jellyfin/Emby episode ranges are refused.

Readers currently cover Jellyfin, Emby and Plex; selecting another backend fails
explicitly rather than silently narrowing coverage. Each configured provider
must have at least one case. Plex `userID` is the numeric ID returned by the
dedicated user's `https://plex.tv/api/v2/user`, encoded as a string. The same
dedicated user token must authorize that identity read and the server read;
the preflight never switches Plex Home identities, refreshes tokens or uses an
administrator token as a substitute. Missing API access is a failed preflight.

PublicMetaDB does not document an account-profile endpoint. The reader verifies
the key by finding the exact dedicated test list in the complete owned-list
response, then records only a SHA-256 credential fingerprint for later scope
comparison. It does not infer ownership from a display name or contributor.
Provisioning that list and credential remains a separate authorized action.

```sh
python3 tools/tracker-acceptance-preflight.py \
  --config /absolute/private/tracking-tests.json \
  --output /absolute/private/run/baseline.json
python3 -m unittest tools.tests.test_tracker_acceptance_preflight
```

The output directory must already exist, be owned by the current user and mode
700. Output is a new mode-600 file and is never overwritten. The reader uses
GET only, refuses redirects, does not retry failures or 429s, disables response
caching, and bounds page counts, bytes, request count and the entire invocation
to 120 seconds. No key is written to disk or passed on argv.

Independent reads verify exact server/user/catalog identities before recording
only allowlisted watched/resume state. Missing, changing, duplicate, unfiltered
or truncated tracker pages fail. Explicitly unknown watch dates remain unknown;
absent Plex state fields remain absent rather than becoming an invented reset.
Baselines are observations over an interval, not atomic snapshots or permission
to overwrite concurrent activity. They contain private viewing state and are
not public reports. This command performs no mutations; later live scenarios
still require explicit account/title mutation approval and exact run-owned
cleanup evidence.

### Isolated tracker import interactions

`TrackerHistoryImportInteractionTests` runs in `PlozzHomeFixtureTests` on tvOS
and `PlozziOSInteractionTests` on iOS/iPadOS. Both hosts select
`--tracker-history-import-fixture`, which presents the real
`TrackerHistoryImportView`, comparison session, outbox and
`AppShellWatchMutationApplier`. Only the tracker snapshot and `MediaProvider`
endpoints are synthetic; no credentials, network requests or personal history
are involved. Test counters observe provider state and every injected tracker
delivery path rather than treating a confirmation label as proof of a write.

The shared interaction suite covers cancellation and cleared selection on page
reentry, independent Jellyfin/Plex target selection, zero tracker mirrors,
connection revocation and changed tracker evidence during approval, concurrent
server progress, and lost write replies verified by readback without repetition.
The `--history-ongoing-sync` fixture additionally exercises separate server-user
and watched-state consent, cancellation without a grant, enrollment without
backfill, a newly observed play delivered only to the selected server, and
revocation. Its device-local ledger uses isolated in-memory secure storage;
restart, uncertain-target holds, storage failures and exact batch/snapshot limits
are covered separately in `TrackerHistoryImportTests`.
TV actions use the native remote focus system; mobile actions use taps and
scrolling. Select the class within its corresponding UI-test target when running
the existing build-for-testing/test-without-building workflow.

These are fixture-backed UI integration checks, not authenticated API, real
server-plugin coexistence, playback, or process-relaunch acceptance. The live
account and exact-title authorization requirements above remain unchanged.
