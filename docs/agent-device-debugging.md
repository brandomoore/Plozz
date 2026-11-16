# Agent device and simulator debugging

A repeatable route for an agent (or a contributor) to observe app behaviour and
capture evidence **without asking the user to drive the app**, and to know exactly
which parts still need a human. Written from the Home/hero flicker investigation,
where the difference between guesswork and a fix came down to getting
millisecond-accurate state transitions rather than screenshots.

Read [performance-debugging.md](performance-debugging.md) for profiling and
[testing-policy.md](testing-policy.md) for which checks a change needs. This file
covers observation and capture only.

## Rules that apply everywhere

- **Ask before installing, signing, or delivering.** A code change does not
  authorize device installation, credential/signing changes, merging or
  distribution. See `AGENTS.md`.
- **Keep the phone unlocked and awake.** `devicectl` refuses launches while the
  device is locked (`FBSOpenApplicationErrorDomain error 7`, "Locked"), and every
  capture then silently records nothing. Set **Settings → Display & Brightness →
  Auto-Lock → Never** for the session and verify with a screenshot probe before
  trusting any later result.
- **Never hide a transient state behind a timer.** Gating a skeleton on
  `Task.sleep` produces measurements that cannot be reproduced. Gate on data
  (published loading state, cached content, explicit season selection)
  so a capture can prove the behaviour.
- **A screenshot burst is not a measurement.** `devicectl` costs ~2.4 s per
  screenshot and screen recording is unavailable on current iPhones. Use
  in-app telemetry for timing questions and screenshots only for appearance.

## Simulator lanes

Simulators give continuous video and full logs, and cost nothing on the device.

**Build the presentation host** (UI harness, no signing):

```bash
tools/generate-project.sh                     # project.yml is the source of truth
xcodebuild build -project Plozz.xcodeproj -scheme PlozziOSPresentationHost \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath <owned derived data> CODE_SIGNING_ALLOWED=NO
```

Prefer an owned `-derivedDataPath` per lane; never reuse a path across concurrent
runs (`build.db is locked` failures come from that, not from broken code).

**Install and launch:**

```bash
xcrun simctl install <UDID> <path>/PlozziOSPresentationHost.app
xcrun simctl launch --terminate-running-process <UDID> \
  com.thatcube.Plozz.PresentationHost --continue-watching-details-fixture
```

Fixtures live in `Tests/iOSPresentationHost/` and `Tests/HomePresentationSupport/`
and are selected by launch arguments (`--detail-selection-fixture
--selection-series`, `--browse-movies`, `--browse-server-films`,
`--detail-route-parity`, …).

**Logs (this is the reliable channel):**

```bash
xcrun simctl spawn <UDID> log stream --style compact \
  --predicate 'category == "fanout"' > /tmp/log.txt &
SIMCTL_CHILD_PLZXFAN_STDOUT=1 xcrun simctl launch ...
```

`SIMCTL_CHILD_`-prefixed variables reach the app. `simctl launch --stdout=` does
not materialise output on this toolchain; the log stream does.

**Continuous video** (the only way to see sub-second transitions):

```bash
xcrun simctl io <UDID> recordVideo --codec=h264 --display=1 --force out.mp4 &
# --display is REQUIRED when more than one display exists (error 22 otherwise)
kill -INT <record pid>          # writes the file on SIGINT
```

Extract frames with AVFoundation (`AVAssetImageGenerator`) — there is no `ffmpeg`
on the build host. Then classify frames rather than eyeballing them: a per-frame
"is the hero band present, and at what y/height" pass distinguishes a slot flap
(band absent) from a metric settling (band resized).

## Real device

**Probe first** — a black frame means the device is asleep/locked and nothing that
follows will work:

```bash
xcrun devicectl device capture screenshot --device <UDID> --destination /tmp/p.png
# ~50 KB and uniform black => asleep;  100 KB+ with content => awake
```

**Launch with stdout bridged:**

```bash
xcrun devicectl device process launch --device <UDID> --console \
  --terminate-existing -e '{"PLZXFAN_STDOUT":"1"}' com.thatcube.Plozz.selfbuild
```

`-e` takes a **JSON dictionary**; a bare `KEY=1` corrupts argument parsing
(`DecodingError … not valid JSON`). `--terminate-existing` is a cold launch; omit
it to *activate* an already-running app, which is the foreground-return path.
Note `--terminate-existing` also resets what a "return" measures — for the real
background/foreground lane, launch the app, background it (`process launch
com.apple.Preferences`), then activate it without `--terminate-existing`.

**Install a signed build:**

```bash
tools/install-verified.sh <UDID> <path>/Plozz.app --force
```

Installs need the device awake, and installing mid-measurement invalidates the
run you are in — finish the capture first.

**Installed-app Home timing diff:** the TestFlight app and the self-build are
separate bundle identifiers, so both can stay installed. They emit the same
`PLZBOOT HomeVM`/`HomeAgg` telemetry when launched with `PLZBOOT_STDOUT=1`; the
runner launches each one, timestamps the console stream and writes a Markdown
report plus raw JSON:

```sh
python3 tools/device-timing-diff.py --device <UDID> --runs 3
```

Pass `--self-build-configuration Release` when the self-build is optimized, and
compare like configurations. Wall offsets include CoreDevice launch overhead;
the app-side `HomeAgg`/row milliseconds are the better comparison. Benchmark
reports are intentionally not committed; capture them locally when comparing.

**What is not available:** screen recording (`CoreDeviceError 1001 — Screen
Recording capability not supported`), and `idevicescreenshot` from
libimobiledevice cannot see the device (pairing mismatch). Budget ~2.4 s per
screenshot and design around it.

## In-app telemetry is the measurement of record

Presentation timing questions are answered inside the app, not from frames.
Diagnostics are silent unless the process is launched with `PLZXFAN_STDOUT=1`
(`FanoutDiagnostics`), and the lines carry counts, kinds and hashes — never
titles, ids or URLs.

| line | answers |
|---|---|
| `HOMESEED` | what the launch snapshot offered: hero count, CW count, store present |
| `HOMEFRAME` | Home presentation state transitions with `t=` monotonic ms |
| `HEROFRAME` | the carried hero set changed (hash + count) |
| `HOMECAROUSEL` | the *filtered* carousel set changed, and which slide is selected |
| `HEROARTREF` | the displayed slide's artwork references changed |
| `HOMECW` / `HOMECWLOADING` | Continue Watching row count and placeholder state |
| `DETAILVIEW` / `DETAILRAIL` / `DETAILRETURN` | detail open, rail skeleton state, return refresh |

Use the timestamps to prove duration ("the skeleton was painted for 1.8 s"), not
to infer it from frame counts. If a question cannot be answered by an existing
line, add one at the state transition that decides it — that is cheaper than
another build/capture cycle.

## Automated checks without a user

- **Unit/logic:** `swift test` for the affected package targets.
- **UI:** `xcodebuild test -scheme <hosted scheme> -destination
  'platform=iOS Simulator,id=<UDID>'`. Hosted flows that need `XCUIRemote` or a
  tvOS simulator ≥ 18 cannot run on every host; say so instead of calling a
  focused run a full pass.
- **tvOS compile:** `-destination 'generic/platform=tvOS Simulator'
  CODE_SIGNING_ALLOWED=NO` — a compile check only, not a hosted test pass.
- **Package resolution:** a pin that is only a branch tip upstream cannot be
  fetched by SHA. Fetch the branch and check the package workspace out at the
  commit, or SwiftPM fails with `Couldn't check out revision …`.

## Human-in-the-loop checklist

Some paths cannot be driven headlessly: there is no deep link to a title and no
tap channel, so **opening a detail page and pressing Back needs the user**. Prompt
for it explicitly and keep the capture open before they start:

1. Ask the user to unlock the device and set Auto-Lock to Never.
2. Start the console capture **first** (`--console`, 3–4 minutes).
3. Ask for the exact sequence ("open a series, let it settle, press Back, twice").
4. Read the captured lines; if the count is zero, the device was locked or the
   taps did not happen — say that instead of reporting a pass.

Report evidence as it is: command output, line counts, frame classifications.
"A build succeeded" is not "the behaviour is fixed".
