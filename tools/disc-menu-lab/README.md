# Disc-menu laboratory

An isolated experiment, **not an enabled Plozz playback feature**. It runs an
original Java Xlet through real libbluray navigation, rather than imitating a
disc menu in SwiftUI. No app target, playback engine dependency, signing setting,
or physical-device installation is changed. The optional runtime smoke route
installs only its own test app in a newly created simulator.

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

Only the lab's own generated Xlet is supported. Do not feed third-party discs
into the harness. libbluray's Java SecurityManager stays enabled; the owned
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
wrong selection, truncated images and incorrect decoded clip colors.

This proves the original menu execution and navigation path on Simulator, not
continuous audiovisual playback, Siri Remote hardware input, performance on
Apple TV, commercial-disc compatibility, network-share caching, or a complete
security boundary. Upstream initialization/teardown warnings remain in the logs,
including the fixture's absent HDMV MovieObject file and the intentionally
denied network permission check. The runner does not infer a full compatibility
pass from this deliberately small original disc.

Plozz playback integration has not been changed. No physical Apple TV has run
this experiment. A distributable implementation also needs
license/notice review and an App Review decision; support for arbitrary external
Java media applications must not be described as preapproved.

Upstream references:
[libbluray 1.5.0](https://download.videolan.org/pub/videolan/libbluray/1.5.0/),
[navigation API](https://videolan.videolan.me/libbluray/bluray_8h.html),
[historical OpenJDK iOS port](https://openjdk.org/projects/mobile/ios.html),
[Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/).
Downloaded dependencies retain their upstream license and notice files.
