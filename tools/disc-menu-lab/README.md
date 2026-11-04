# Disc-menu laboratory

An isolated experiment, **not an enabled Plozz playback feature**. It runs an
original Java Xlet through real libbluray navigation, rather than imitating a
disc menu in SwiftUI. No app target, playback engine dependency, signing setting,
or device installation is changed.

## Run

On Apple Silicon macOS, with Python 3.12+, Xcode command-line tools, Meson, Ninja,
pkg-config, FFmpeg (including libx264 and AC3), and the native dependencies
fontconfig, FreeType, libudfread and libxml2 available to pkg-config:

```sh
python3 -m unittest discover -s tools/disc-menu-lab -p 'test_*.py'
python3 tools/disc-menu-lab/lab.py navigate
python3 tools/disc-menu-lab/lab.py zero-probe
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

## Apple TV Zero probe: blocked

The pinned OpenJDK mobile commit is a **JDK 21 development snapshot**, selected
to investigate its existing BSD Zero sources with a compatible boot JDK.
It is not a maintained runtime candidate for distribution.

Two bounded attempts are retained:

1. The explicit `aarch64-apple-tvos` target fails because its platform machinery
   does not recognize tvOS.
2. The Darwin target with explicit tvOS SDK/compiler flags gets further, but
   still requires macOS desktop Metal tooling (`xcrun -sdk macosx metal`).
   That tool was unavailable on the inspected development installation.

The probe reports failure, not a tvOS library. The second failure is a tooling/
configuration blocker, **not evidence that a tvOS port is impossible**. No JVM
object code was built and no simulator or physical Apple TV ran this experiment.
Porting the runtime requires proper target configuration, compatible libffi and
native libraries, OS/API adaptations and an actual no-JIT execution test; a
desktop fallback or fake executable cannot establish those properties.

Separately, libbluray's Darwin build assumes DiskArbitration and desktop JVM
discovery. Its Apple TV build, runtime packaging and Plozz playback integration
have not been implemented here. A distributable implementation also needs
license/notice review and an App Review decision; support for arbitrary external
Java media applications must not be described as preapproved.

Upstream references:
[libbluray 1.5.0](https://download.videolan.org/pub/videolan/libbluray/1.5.0/),
[navigation API](https://videolan.videolan.me/libbluray/bluray_8h.html),
[historical OpenJDK iOS port](https://openjdk.org/projects/mobile/ios.html),
[Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/).
Downloaded dependencies retain their upstream license and notice files.
