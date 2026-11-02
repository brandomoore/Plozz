# FTP transport

The shared FTP transport supports plain FTP and implicit FTPS. Explicit
FTPS remains unsupported; the transport never silently downgrades TLS.

Playback requires byte-offset restart. Capability discovery is refreshed after
authentication. If the authenticated feature list does not advertise `REST`,
the backend probes `REST 1` after `TYPE I`, then requires `REST 0` to clear the
marker before allowing any file transfer. This supports servers without `FEAT`
and servers with incomplete feature advertisements without assuming they seek.
Command-not-supported responses leave the session browseable but not playable.
Authentication, connection, temporary server failures, and a failed marker reset
remain errors, not an unsupported-capability fallback.

Each playback cursor owns its control/data connections. File size and captured
modification time are checked at open and on discontiguous reads; uninterrupted
transfers do not perform a separate mid-stream metadata check.

## Transfer lifecycle

Contiguous reads reuse one streaming `RETR`. A seek away from an unfinished
transfer closes both sockets and authenticates a fresh control connection before
revalidating `SIZE`/`MDTM` and issuing `REST`/`RETR`. This deliberately costs a
login at uncached seeks: a pending transfer-complete reply and an `ABOR` reply
cannot be reliably distinguished on every server. No heuristic reply draining
is used. A captured modification time becoming unavailable is a failure, not
permission to drop identity checking.

EOF requires the expected byte count and a final `226` or `250`; failed final
replies, premature EOF, and extra bytes are errors. Bounded whole-file and
directory reads also validate completion and reject overflow rather than
returning a truncated result. Same-size in-place edits during uninterrupted
streaming cannot be reliably detected by FTP's size/mtime identity.

A failed cursor connection is discarded. An eligible timeout, connection loss,
or FTP `425`/`426` gets at most one replay of the failed read at its original
offset, through a fresh connection with representation revalidation. This does
not retry authentication, permissions, TLS trust, malformed protocol responses,
changed representations, or cancellation. A clean but premature EOF remains a
source-change failure rather than an assumed transient disconnect. Released
cursors cannot be resurrected by recovery or return late bytes.

Passive transfers prefer EPSV. Rejected/invalid EPSV or a failed EPSV connection
can fall back once to PASV on an IPv4 control connection, never IPv6. Both modes
use the control hostname, not the PASV-advertised address. Implicit FTPS starts
the data connection before the transfer command but awaits TLS readiness after
the preliminary reply, accommodating servers that defer data TLS until `RETR`
or a listing command. Neither fallback changes encryption or certificate trust.
Explicit FTPS is still unsupported. Servers requiring control-to-data TLS
session reuse still need separate compatibility testing.

`MLST` or `MLSD` feature advertisements enable machine-readable directory
listings. An explicitly unsupported MLSD command can fall back to LIST;
authentication and transient failures are not treated as missing extensions.

## Validation

`MediaTransportFTPTests` includes scripted loopback control/data sockets for
capability negotiation, queued completion during seek, byte-count and final
status failures, identity loss, EPSV connection fallback, and listing selection.
Cursor recovery tests cover retry bounds, terminal errors, and late release.

`FTPPlaybackIntegrationTests` is opt-in. It uses the real adapter, source
resolver, byte reader, and Plozzigen player, requiring presented video and clock
progress through forward/backward seeks, pause/resume, and a fresh resumed load.
It also checks sparse files beyond 4 GiB, independent cursors, and incorrect
certificate pins, refused FTPS data ports, and an injected data-connection reset
that must actually fire. These are native simulator player tests, not app-navigation,
physical HDR output, audio-route, throughput, or exhaustive server certification.

For generated-media fixtures, install `tools/ftp-playback-requirements.txt` in
an isolated virtual environment and run `tools/ftp-playback-fixture.py`.
It serves plain FTP, normal implicit FTPS, and implicit FTPS with delayed data
TLS on ephemeral loopback ports. Its generated MP4 has metadata at the end;
the same generated audio/video is remuxed to MKV. No personal media is copied.
The fixture has a bounded lifetime and removes only its owned temporary files.

Forward the printed URL as `TEST_RUNNER_PLOZZ_FTP_FIXTURE_URL` when running the
integration target with Xcode on an owned simulator. The short-lived random
configuration URL must remain local; it can carry remote credentials in memory.
The optional independent-server case requires `--remote-config` pointing to an
owner-only JSON file with `host`, `port`, `username`, `path` (relative to `/`),
`keychainService`, and `keychainAccount`. The fixture reads that password from
Keychain without putting it in arguments, files, or logs. It checks only the
specified file. Missing remote configuration fails that opt-in case rather than
claiming two-server coverage. Keep the fixture alive through the test run and
stop it afterward; no server provisioning or physical-device action is implied.
