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

The same hosted suite exercises ordinary server-HLS startup through
`PlayerViewModel` and Plozzigen, with no initial quality options. Its first
segment withholds response headers for 45 seconds; the unchanged 30-second app
watchdog must request exactly one forced H.264 replacement at Original quality
and present ten decoded frames before the original segment can respond.
It verifies the selected version and that the outgoing session's stop report
precedes replacement negotiation. This isolates the client recovery gap; the
replacement is pre-encoded synthetic H.264, not evidence that a reporter's
Jellyfin encoder, remux, Dolby Vision or TrueHD file will succeed.

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
to 120 seconds. Requests identify the read-only test client with an explicit
`Plozz-Tracker-Acceptance` user agent; they do not impersonate a browser.
No key is written to disk or passed on argv.

Independent reads verify exact server/user/catalog identities before recording
only allowlisted watched/resume state. Missing, changing, duplicate, unfiltered
or truncated tracker pages fail. Explicitly unknown watch dates remain unknown;
absent Plex state fields remain absent rather than becoming an invented reset.
Baselines are observations over an interval, not atomic snapshots or permission
to overwrite concurrent activity. They contain private viewing state and are
not public reports. This command performs no mutations; later live scenarios
still require explicit account/title mutation approval and exact run-owned
cleanup evidence.

### Independent before/after comparison

Capture separate baselines immediately before and after an authorized test
action, then compare them without making any network request:

```sh
python3 tools/compare-tracker-baselines.py \
  --before /absolute/private/run/before.json \
  --after /absolute/private/run/after.json \
  --output /absolute/private/run/comparison.json
python3 -m unittest tools.tests.test_tracker_acceptance_preflight tools.tests.test_compare_tracker_baselines
```

The comparator requires identical configuration, tracker/server credential
fingerprints, exact provider/server/user/catalog identities and complete case
coverage. Older baselines without server credential fingerprints must be
recaptured. Observation intervals must be ordered, non-overlapping and each
within the reader's 120-second limit. Missing fields, duplicate cases/records
and unsupported evidence fail rather than compare as empty state.

By default, both server and tracker state must be unchanged. Use
`--require-unchanged server` when an authorized tracker-side change is expected
but the server must remain unchanged before import approval. The report still
records both outcomes. Exit status is **0** for the requested unchanged state,
**2** for changed state, or **1** for invalid/unavailable evidence.

Inputs must be private, owned files; output must be a new file in a private,
owned directory. The output records both input hashes but does not copy tokens
or viewing-state payloads. Absent Plex fields, unknown watch dates, individual
record IDs, counts and resume positions retain their actual meanings.

**Equal snapshots prove only equal observed endpoint state**, not absence of
intervening writes, rollback, concurrent activity or intermediate states. Local
hashes bind input files; they do not authenticate their origin. This tool neither
drives Plozz nor verifies playback, consent UI, app/account identity, coexistence
or process recovery. Its result always retains `acceptanceVerified: false`.
The actual production-app driver and authenticated acceptance remain separate
requirements; this comparison does not turn fixture tests into live evidence.

### Production-app live connection check

`PublicMetaDBLiveConnectionTests` is a separate **unbound** XCTest driver for
the installed production app, not FocusHost or PresentationHost. Build only its
runner with:

```sh
bash tools/run-tracker-connection-tests.sh --build-only tvOS
bash tools/run-tracker-connection-tests.sh --build-only iOS
```

Use an explicitly selected, already-booted owned simulator with the approved
production app running in English and a dedicated test profile/account. Do not
run connection-changing scenarios against a household profile. Setup,
authentication and input use production controls, not seeded profiles, injected
credentials or fixture hosts. TV navigation can open Settings from Live TV.
The iOS runner currently supports only `negative`; open PublicMetaDB settings
before running it. The authenticated driver uses the TV QR and navigation, not
the mobile browser link or mobile relaunch navigation.

```sh
bash tools/run-tracker-connection-tests.sh --run tvOS \
  OWNED_SIMULATOR_UUID EXPECTED_APP_EXECUTABLE_SHA256 negative
python3 -m unittest tools.tests.test_tracker_connection_evidence
```

The optional final argument selects exactly one scenario:

| Scenario | Required state and coverage |
| --- | --- |
| `negative` (default) | No saved key. Live relay challenge, automatic TV input focus, repeated Back/input navigation, cancellation/revocation, fresh code, and rejection of a deliberately invalid manually entered key. |
| `setup` (TV only) | Isolated first-run app. Imports the public `iptv-org` San Marino playlist through normal controls and completes profile, optional Seerr and appearance setup. This is setup evidence, not connection acceptance. |
| `browser` (TV only) | No saved key. Decodes the actual production QR, writes a unique private handoff file, waits for real browser authentication, verifies Connected and revoked pairing, and reads the dedicated account's empty Lists page. |
| `persistence` (TV only) | Saved test connection. Terminates/relaunches the installed app normally, verifies the saved connection, reads Lists and dismisses the account sheet through Done. |
| `disconnect` (TV only) | Saved test connection. Cancels replacement confirmation and entry, rejects an invalid replacement and cancels it, verifies restored account access, cancels then confirms Disconnect, and checks removal after normal relaunch. |
| `manual` (TV only) | Saved test connection and an authorized one-shot loopback input source. Confirms replacement, enters the real key with ordinary TV remote keyboard events, submits Connect and verifies authenticated Lists. |

`browser` requires `PLOZZ_TRACKER_CONNECTION_HANDOFF` to name a new absolute
`browser-request.json` path in a private existing directory. The file contains
only the decoded public QR URL/code. A separately owned browser driver (or the
tester) must submit the legitimate test key through that deployed page within
the native wait. Keep browser credentials in a secret-safe source, verify the
encrypted submission and consumed-code rejection independently, and close the
owned browser/profile on success, failure or cancellation.

`manual` requires `PLOZZ_TRACKER_MANUAL_INPUT_URL`: an owned, short-lived,
single-use HTTP endpoint on `127.0.0.1` returning `{"key":"..."}` from a private
credential store. Use an unpredictable path, private configuration, no request
or response logging, and a bounded server lifetime. This input goes only to the
test runner's keyboard navigator, never to an app service or app Keychain API.
Do **not** use XCTest `typeText` for real credentials: it logs a prefix even for
secure fields. The navigator uses observed key geometry and remote events with
no credential text in query/action arguments. Its current native-layout coverage
is the 1080p tvOS 26.2 keyboard; unexpected geometry fails rather than guessing.
Manual input has a twenty-minute deadline; other scenarios have five minutes.

Obtain the expected executable hash from the approved build's retained
evidence, not by accepting whatever happens to be installed. The runner verifies
the installed canonical app against it, rejects application-bound test manifests,
and checks that its own source has not changed since compilation. It never builds
or installs Plozz or boots/shuts down simulators. Explicit persistence/disconnect
scenarios relaunch Plozz with no custom arguments/environment. XCTest installs
only its isolated runner. Xcode's generated runner
paths and standard environment metadata are checked exactly; custom application
launch arguments and environment overrides are rejected.

Unexpected UI,
missing prerequisites, quota/network failures and incomplete cleanup are failures,
not skips or passes. Automatic screenshots/recording are disabled. Setup may
attach its credential-free UI tree; the browser scenario intentionally attaches
the public QR and final Connected screen, never a populated credential field.
Private results are retained under
`.build/tracker-connection.*/`, including source snapshots (also for untracked
driver files), the generated runner manifest and installed executable identity.

Each verdict requires the exact selected method, one completed case, and zero
failures/skips. A setup or negative pass cannot stand in for a successful browser
or manual connection. Compare complete independent account fingerprints around
connection-only scenarios when checking that lists, watched plays and resume
records remain unchanged. These scenarios do not establish playback, imports,
exports, cross-server coexistence, physical-device behavior or other trackers'
acceptance. Compiling a driver is not a live pass.

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
The watched-only/manual fixture variation verifies that unsupported resume
controls are absent, the manual-check explanation is present, and a new play
still requires **Sync now**.
TV actions use the native remote focus system; mobile actions use taps and
scrolling. Select the class within its corresponding UI-test target when running
the existing build-for-testing/test-without-building workflow.

These are fixture-backed UI integration checks, not authenticated API, real
server-plugin coexistence, playback, or process-relaunch acceptance. The live
account and exact-title authorization requirements above remain unchanged.
