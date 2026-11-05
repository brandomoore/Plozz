# Disc-menu laboratory

An isolated experiment, **not an enabled Plozz playback feature**. It runs
authored Java menus and, through a separate live prototype, native HDMV menus
using libbluray rather than imitating a disc menu in SwiftUI.
No production app target, playback engine dependency or
signing setting is changed. Simulator routes install only their own test app in
a newly created simulator; the device build route does not sign or install.

## Run

On Apple Silicon macOS, with Python 3.12+, Xcode command-line tools, Meson, Ninja,
pkg-config, FFmpeg (including libx264 and AC3), and the native dependencies
fontconfig, FreeType, libudfread and libxml2 available to pkg-config:

```sh
python3 -m unittest discover -s tools/disc-menu-lab -p 'test_*.py'
python3 tools/disc-menu-lab/lab.py navigate
python3 tools/disc-menu-lab/lab.py tvos-build
python3 tools/disc-menu-lab/lab.py tvos-runtime
python3 tools/disc-menu-lab/lab.py tvos-smoke
python3 tools/disc-menu-lab/lab.py tvos-bdj
python3 tools/disc-menu-lab/lab.py tvos-bdj-device-build
```

`bootstrap` downloads prerequisites only; `host` builds libbluray and its Java
support without running a disc. Downloads are version/checksum pinned in
`dependencies.json` and extracted with Python's safe data filter. JDK and Ant
remain inside `.build/disc-menu-lab/`; nothing is installed globally. Native
host dependencies are supplied by the development environment, not this manifest.

The runner acquires the repository's shared build lease, prevents overlapping
lab invocations, bounds child processes, and retains each run's commands, logs
and outputs in a unique directory. It does not clean caches or reset services.
An unsuccessful command exits nonzero; missing evidence never becomes a pass.
Use the printed evidence directory rather than an older successful run.

## What the host experiment establishes

The authored disc has a real index, BDJO application descriptor, two MPLS
playlists, clip information with a start access point, and one original Xlet JAR.
Its red/blue video and tones come from `../generate-bdmv-test-fixture.py`.
There is no commercial disc content, encryption or key material.

The native harness:

- Starts the disc's Java application via `bd_play`.
- Copies the actual IG-plane ARGB callbacks, publishing snapshots only on FLUSH.
- Sends Enter, returns through `bd_menu_call`, sends Right and Enter.
- Requires playlist events for both choices and at least 64 KiB of video data
  from each selection, then closes the disc/runtime.
- Decodes a frame from each selected stream and asserts its expected red/blue
  color. Saves both menu screenshots, decoded frames and a structured result.

This demonstrates menu execution, changed selection, return-to-menu navigation,
and correctly routed stream data. It does **not** establish continuous real-time
A/V playback, frame rate, arbitrary seeking, commercial-disc compatibility,
HDMV menus, multi-angle transitions, background-plane composition or network VFS.
The short clips index only their first access point; they are not seeking fixtures.

Initial development caught a missing CPI access-point entry that crashed native
libbluray. The fixture now supplies that entry and has structural regression
coverage. This is another reason not to treat an authored-fixture pass as
untrusted-disc hardening. Upstream Java/native diagnostic warnings during
initialization and menu teardown remain visible in retained logs.

## Runtime and security boundaries

The successful host path uses Temurin **HotSpot 21 with `-Xint`**, not Zero.
HotSpot still generates native interpreter stubs; this is **not proof of a
no-executable-memory runtime or tvOS compatibility**.

Only the lab's own generated Xlet is supported by the Java routes. Do not feed
third-party Java discs into those routes. The separate HDMV route below rejects
BD-J discs. libbluray's Java SecurityManager stays enabled; the owned
libbluray source gets one explicit change disabling its otherwise unconditional
`bluray.network.connected=YES`. Xlet initialization requires a SecurityManager
and verifies that a network permission check is denied, without opening a socket.
Persistence is disabled and library cache roots are per-run.

These are experiment controls, not a complete security boundary. A production
implementation still needs parser/JNI review, explicit resource/storage limits,
profile/account isolation, cancellation, and a supported runtime security model.
Java 24 removed SecurityManager support ([JEP 486](https://openjdk.org/jeps/486));
silently removing the checks is not an acceptable upgrade path.

## Apple TV Zero runtime port

The port uses release-tagged **OpenJDK 21.0.13+9** sources from `jdk21u`, a matching
host boot JDK, and pinned libffi 3.4.8. The earlier mobile EA snapshot and raw
`zero-probe` configuration failures are historical evidence, not the current
port's outcome. This experimental pin is not a distribution/security-update policy.

`tvos-build` cross-compiles a genuine ARM64 tvOS Zero JVM (minimum tvOS 18).
`tvos-runtime` also builds and stages matching `java.base` classes, native
libraries, security configuration, CA roots and timezone data. Device-platform
cross-compilation and staging have succeeded. Each native library's Mach-O
platform and architecture are checked; a macOS or simulator binary cannot pass
as a device library. The JVM must export `JNI_CreateJavaVM` and must not import
the checked unavailable process/JIT/debugger-exception APIs.

The reproducible adaptations live in `tvos.py`, applied exactly once against
checksummed pristine inputs into an owned source copy. Device and simulator
builds have separate output/FFI directories. The build reuses BSD machinery but
passes explicit tvOS SDK/compiler targets; it does not disguise macOS binaries.

Current scope and deliberate limitations:

- Zero's code heap holds non-executable metadata. The BSD VM memory helpers
  fail explicitly if asked to reserve, commit, protect or map executable data.
  This is not a complete audit of every native dependency or physical-device
  proof of no-JIT behavior.
- External process APIs throw `UnsupportedOperationException`; first access can
  wrap that in a class-initialization error. Desktop process enumeration,
  launcher and macOS KeychainStore native support are not supplied.
  An attempted KeychainStore native load fails rather than bypassing security.
- Legacy macOS global proxy-property import is unavailable and logs that
  limitation. URL-specific system-proxy selection uses CFNetwork when enabled
  with `java.net.useSystemProxies`; it is not exercised by the offline probe.
- Desktop Metal/printing dependencies are not needed for this `java.base` build.
  Their omission alone is not a port of `java.desktop`; the separate BD-J route
  below adds a deliberately limited offscreen AWT implementation.

`tvos-smoke` builds a separate **tvOS Simulator** variant and an original
`app.plozz.lab.ZeroSmoke` app. It creates one owned simulator, boots it, installs
the app, and requires a structured result within 120 seconds. The JNI worker
must execute arithmetic, catch an expected Java exception, round-trip a file,
compute SHA-256, run a Java thread, reject process creation, deny a network
permission check with SecurityManager enabled, and destroy the VM. Loading the
library alone is not a pass. No connection is attempted.

This probe **passed on tvOS 27 Simulator with the Zero interpreter**, including
VM teardown and owned-simulator cleanup. The executable-memory guards were
enabled. This advances the result beyond cross-compilation, but it does not
establish physical-device behavior.
SecurityManager deprecation warnings remain visible rather than suppressed.

The runner retains app stdout/stderr, runtime results and any JVM fatal-error
log found on timeout, and shuts down/deletes only its owned simulator in a
`finally` path. It does not reset shared simulator services. Simulator evidence
must not be presented as physical Apple TV execution.

## Actual BD-J menu on tvOS Simulator

`tvos-bdj` has **executed the authored Java disc menu on tvOS 27 Simulator using
Zero and target-built libbluray**. It renders the real ARGB callbacks in a native
UIKit image surface, sends Enter, returns to the top menu, moves Right and
selects the second playlist. Both selected streams must decode to their expected
red/blue test colors. The simulator app is separate from Plozz.

The route adds matching `java.desktop`, `java.datatransfer`, `java.xml`,
`java.prefs`, `java.logging` and `java.rmi` classes. It builds OpenJDK's portable
AWT raster/image libraries and bundled FreeType, reuses upstream lightweight
AWT initialization and splash-cleanup code, and replaces desktop window-server
loading with a loader that accepts **only libbluray's BDToolkit**. This is not a
general-purpose Java desktop port: AppKit, native desktop controls, printing,
system audio/MIDI, macOS fontmanager, native preferences and desktop integration
are not supplied. Untested APIs may fail.

The isolated libbluray source copy removes DiskArbitration, uses the existing
directory mount implementation, builds its bundled libudfread for the target,
and requires an application-provided `lib/zero` runtime. It does not spawn the
desktop Java locator or fall back to a host JVM. Native metadata XML parsing and
fontconfig are disabled for this fixture; Java XML support remains present.
The original Xlet still checks that disc networking is denied.

Font rendering uses pinned DejaVu 2.37 fonts, explicitly mapped by their real
file names; no system-font extraction or proprietary font bundling is involved.
Font and native dependency notices are retained in the staged runtime.

Each run retains `menu-first.png`, `menu-second.png`, `simulator-menu.png`,
the selected M2TS samples, stdout/stderr, `bdj-result.json` and simulator-cleanup
evidence. The initial display flush can contain only the background, so the
harness waits for painted choice colors and text rather than counting any
frame as menu readiness. Independent output assertions reject blank text,
wrong selection, truncated images and incorrect decoded clip colors. They also
check the captured device/simulator screen, allowing text antialiasing from
display scaling while retaining exact checks for the original Java buffers.

This proves the original menu execution and navigation path on Simulator, not
continuous audiovisual playback, Siri Remote hardware input, performance on
Apple TV, commercial-disc compatibility, network-share caching, or a complete
security boundary. Upstream initialization/teardown warnings remain in the logs,
including the fixture's absent HDMV MovieObject file and the intentionally
denied network permission check. The runner does not infer a full compatibility
pass from this deliberately small original disc.

`tvos-bdj-device-build` builds the same authored-menu app for physical tvOS,
using separate device-native libraries. It deliberately **does not sign,
install or launch** anything. Its result is
`device-app-built-not-signed-or-executed`, not a runtime pass. Physical execution
requires separate authorization and an existing valid development profile and
identity covering the test bundle ID and target device; the lab does not create
Apple account resources or change Plozz signing.

Runtime receipts and menu/stream evidence use the app's `Library/Caches`
directory, which is writable on tvOS. Each receipt includes its originating lab
run ID and the compile-time device/simulator identity. A stale receipt or a
simulator receipt cannot establish successful hardware execution.

### Physical-device result and visible completion

The authored BD-J probe has also **executed on a physical Apple TV 4K
(2nd generation), launched without an attached debugger**. Its matching device
receipt, both actual menu buffers, both selected streams and an actual device
screenshot were retrieved and checked. Signing used an existing development
identity/profile; no new Apple account resources were created. Normal Plozz
remained untouched.

Hardware testing exposed a harness presentation race: after selecting the
second playlist, the stream-read check could finish while an asynchronous menu
repaint had published only its background. Closing the test then left that
incomplete image onscreen even though the earlier menu snapshots were correct.
The app now shows progress and, after shutdown, an explicitly labelled
**captured menu, not an interactive session**, with a completion message.
It retains the last successfully captured menu rather than leaving a
partially painted frame as its final screen. Both runtime variants show when
their automated checks have finished. Runtime stdout/stderr and overlay
selection diagnostics are retained in the app cache and simulator run evidence.

This hardware result still does not establish continuous audiovisual playback,
Siri Remote navigation, arbitrary-disc compatibility or a production security
boundary. Plozz playback integration has not been changed. A distributable implementation also needs
license/notice review and an App Review decision; support for arbitrary external
Java media applications must not be described as preapproved.

Upstream references:
[libbluray 1.5.0](https://download.videolan.org/pub/videolan/libbluray/1.5.0/),
[navigation API](https://videolan.videolan.me/libbluray/bluray_8h.html),
[historical OpenJDK iOS port](https://openjdk.org/projects/mobile/ios.html),
[Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/).
Downloaded dependencies retain their upstream license and notice files.

## Live HDMV / AetherEngine prototype

`live_build.py` packages a separate **Disc Menu Lab**, still using the experimental
`app.plozz.lab.ZeroSmoke` identifier. This replaces the earlier standalone smoke
app, not Plozz. It does not sign, install, or launch a physical-device app.
It requires the existing target libbluray/FreeType builds described above:

```sh
python3 tools/disc-menu-lab/live_build.py --configuration /private/path/disc.json --region A
```

The private configuration supplies `baseURL`, `authorization`, and `files`
(`path`/`size` records). Never commit it, embed share credentials, or publish a
configured app. Select the intended player region explicitly with `--region`
(`A`, `B`, or `C`); the build writes its `regionCode` into the app configuration
rather than inheriting libbluray's Region B default.
`relay.DiscRelay` supplies the network configuration from an explicitly scoped
file inventory. Its caller supplies upstream authentication in memory and owns
the server's lifetime. The device receives only a temporary disc-scoped
capability. The default limits are two hours and 8 GiB: this is a short test
session, not a way to watch an entire large backup. The Mac relay must remain
reachable. HTTP is for a trusted development LAN, not a production transport.

The build uses Plozz's exact AetherEngine revision and checks the independently
resolved graph against its dependency lock. Every dynamically linked framework
is recursively embedded and checked for the target platform and ARM64
architecture. Required native, engine, and multimedia notices accompany the
generated app. Physical signing must use an existing authorized development
profile and identity, make only the app-owned framework copies writable,
sign nested code before the app, and verify the full signed dependency chain.
Keep the build lease through signing and installation, preserving inherited
lease descriptors when launching subprocesses.

Native navigation owns its own serial queue and HTTP cursors. AetherEngine gets
independent readers for the explicitly selected MPLS and its title-relative
start position; selecting another movie in the same playlist must not reset it
to the first movie. Replacement loads are serialized and clock notifications
carry the generation captured before throttling. Native palette/RLE graphics
are composited over the engine's video surface; hidden overlays retain their
bitmap until the disc clears it.

The prototype follows first-play rather than forcing a menu call during a
disc's restricted opening sequence. At engine completion, a bounded final-access-
unit read lets libbluray resume the disc's HDMV program. Ordinary event polling
does not consume transport video or advance the engine's read-ahead cursor.
Clock synchronization maps title time into the current clip's presentation
timestamp. A menu call unavailable at the current location is a visible notice,
not a fatal navigation error; actual failures remain visible and are not
replaced by a misleading timeout/retry prompt.

Index, movie-object, playlist and clip-information files are cached in memory
before navigation starts (2 MiB per file, 16 MiB total). Menu transitions reuse
that session-local metadata instead of repeatedly fetching it during video
playback. Exact range reads retry once for transient URL timeouts/connection
loss or HTTP 503/504, with finite request and whole-attempt deadlines. Cancelled
sessions, invalid ranges, authorization failures, expiry and byte-limit failures
are not silently retried or accepted. The relay distinguishes timeout (504),
expiry (410), quota (429), and invalid upstream responses (502).

After an exhausted read failure, Back tears down the old session and creates a
fresh one rather than sending commands to a stopped native instance. Restarting
or foregrounding does not re-arm an automated sequence already claimed in that
process. Recovery cannot restore an expired relay or repair a missing source.

Controls: directions/swipes move through the original menu, Select activates,
Back requests the top menu, and Play/Pause controls AetherEngine. **Audio and
subtitle choices in the original disc menu are not connected to the engine.**
Multi-angle playback, Java menus on this route, encrypted discs, seamless
branching, complete playmark/timer behavior, and arbitrary-disc compatibility
are not established. This is not a production parser/security review or an
App Store distribution candidate.

`Library/Caches/live-result.json` records the originating run ID, native
playlist/start selections, engine phases, clock samples, and sparse decoded-
frame checksums. Logs are retained beside it. A `.playing` event alone does
not prove video playback. The optional `--lab-auto` launch argument drives the
specific development three-choice menu sequence, including an Up press during
the opening video when no menu is active. Directional/select input is admitted
only while libbluray reports an interactive menu; an unavailable key must not
stop the player. Physical remote input cancels the automated sequence and hands
control to the user. This is not a generic disc test
or evidence that physical Siri Remote input works. Launch without that argument
for manual testing. Backgrounding stops the native session and engine.

On a physical Apple TV, this route has played the opening sequence, advanced
through native HDMV navigation into the original menu, and sustained changing
AetherEngine video frames behind it. Manual directions during the opening video
were logged as unavailable without stopping playback; subsequent menu input
worked. Manual takeover interrupted the three-movie automated sequence, so this
run does **not** establish all three movie start positions on the TV. The earlier
desktop navigation evidence and this physical playback evidence remain distinct.

A subsequent physical run deliberately delayed one metadata response beyond
the request timeout. The app logged URL error `-1001`, retried the same range,
cached 95,370 bytes of navigation metadata, and continued into changing video
frames without restarting the app. This proves that specific transient-read
recovery, not arbitrary network-failure tolerance or the manual retry UI.

### Before production integration or distribution

The lab's success is not an App Store compliance result. In particular:

- Replace the temporary relay with the existing account-scoped media transports;
  preserve independent readers, source identity checks, profile isolation, and
  cancellation. Connect menu track selections, title-relative resume/watch state,
  exit behavior, and a native title/main-feature fallback before relying on menus.
- Audit the final distribution archive and every embedded dependency against
  target SDK availability. A narrow `nm` denylist is only one check. The current
  Debug engine binary imports `posix_spawnp`; its origin and distribution impact
  need investigation, not a blind replacement. Unsupported function stubs must
  preserve each API's actual error contract.
- Replace the lab-only standalone FreeType dylib layout with supported framework
  packaging or an appropriately licensed static link. Framework metadata and
  deployment targets must be valid; their versions need not equal the app's.
  Preserve applicable license texts and redistribution/relinking obligations.
- Keep the Zero runtime's no-generated-executable-memory requirement. Validate
  JVM flags against the pinned runtime rather than copying flag lists: the port
  uses `ImplicitNullChecks`, and reduced signal usage does not eliminate all
  fatal-signal handlers. libbluray uses its offscreen BDToolkit with
  `java.awt.headless=false`; forcing true is not a harmless sandbox switch.
- Arbitrary BD-J discs require further confinement and resource-limit work.
  Java permission checks alone do not harden native parsers. Keep runtime reads
  and per-disc writable storage explicitly scoped; never delete active caches
  or unrelated app data to satisfy a blanket cleanup rule.
- Use clear UI language without hiding Java/OpenJDK implementation details from
  diagnostics, licenses, or App Review. Neither interpreter packaging nor naming
  establishes approval under Apple's code-execution rules. Keep unencrypted-media
  scope explicit and do not bundle DRM circumvention.

References: [App Review Guidelines 2.5.1, 2.5.2 and 4.7](https://developer.apple.com/app-store/review/guidelines/),
[Apple's framework embedding guidance](https://developer.apple.com/library/archive/technotes/tn2435/_index.html).
