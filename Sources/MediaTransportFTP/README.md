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
