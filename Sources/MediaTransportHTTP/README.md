# MediaTransportHTTP

HTTP/WebDAV protocol primitives used by `MediaTransportWebDAV` and
`ProviderShare` on tvOS and iOS/iPadOS. Shared ownership, identity, resolver,
and byte-source contracts live in `MediaTransportCore`.

## Adapter guarantees

- **Origin discipline**: exact scheme/host/port normalization
  (`TransportOrigin`). `OPTIONS` and `PROPFIND` retain same-origin redirects
  (`RedirectPolicy`). File GETs have the separate delivery policy below.
- **Credentials**: `CredentialPreflight` owns the existing LAN policy.
  Configured HTTP shares permit credentials with an onboarding warning;
  HTTPS is recommended. This permission does not allow redirect downgrades.
  Password challenges enforce the immutable `PasswordAuthPolicy` and use
  session-only credentials (`.forSession`). URLSession can reuse an accepted
  challenge within that exact managed session rather than paying a 401 round
  trip on every request. Credential storage remains disabled; account, revision,
  origin, trust and role boundaries and retirement discard that learned state.
  Descriptions and errors exclude secret values.
  Unsupported IIS NTLM/Negotiate protection spaces are declined at both session
  and task challenge callbacks, allowing URLSession to offer Basic or Digest.
  No credential is supplied to Windows authentication, and Digest-only policy
  still rejects Basic. Anonymous media-delivery sessions never negotiate auth.
- **TLS trust**: system trust by default; an explicitly accepted override pins
  the exact leaf certificate DER for one origin/trust revision, never "trust
  all." A mismatch fails closed.
- **Session isolation**: ephemeral sessions are scoped to account, credential
  revision, origin, trust revision and role. Cookie storage, URL caches and
  shared credential storage are disabled. Retirement cancels the source's
  sessions without affecting another account.
- **WebDAV surface**: bounded OPTIONS, PROPFIND Depth 0/1, external-entity-free
  XML parsing, normalized root-contained hrefs, and explicit byte/entry caps.
  Namespace prefixes remain tolerant, but only properties at the expected
  multistatus/response/propstat/prop positions can supply metadata. Nested
  extension properties cannot replace file identity or mark a file as a folder.
  CDATA and ordinary XML text are handled equivalently.
  Repeated entries with the same normalized path and identical parsed metadata
  are collapsed, preserving first-occurrence order for both listing and stat.
  For files with a size and the same valid strong ETag, a modification-date
  difference alone also collapses: the ambiguous date is discarded, while the
  strong ETag remains authoritative. Missing/weak ETags, folders and missing
  sizes do not qualify for this exception.
  Conflicting entries remain distinct: stat rejects ambiguous metadata rather
  than choosing the first file or combining validators from different entries.
  The entry cap counts responses before deduplication.
- **Range safety**: identity encoding, exact `206`, matching `Content-Range`
  offsets/total and body length. A bounded GET establishes the actual
  representation's strongest usable validator. Two bytes remain the default;
  playback opening of files at least 256 KiB retains a validated 256 KiB prefix.
  Reads wholly inside it reuse those exact bytes; validated network reads send
  `If-Match` for a strong ETag, or `If-Unmodified-Since` for Last-Modified, and
  requires the same response validator. Weak ETags alone are insufficient.
  Missing/changed validators, HTTP 412, changed sizes, ignored ranges and
  truncated responses fail instead of being treated as usable media. The explicit
  anonymous-delivery streaming exception below retains range/size checks without
  claiming content-change detection.
- **Independent delivery**: `validateAnonymousAccess` checks the already-probed
  HTTPS URL in a separate anonymous media session, including same-origin grants.
  Its conditional two-byte read retains the exact URL, size and validator;
  it never inherits account credentials, cookies or trust overrides, and never
  follows another redirect. This proves independent access, not grant lifetime.
- **Response buffering**: each task owns one mutable body accumulator under the
  delegate lock. Callback appends must not copy the entire previously received
  body. The byte cap is enforced before appending, and cancellation/errors never
  return the partial body as successful media.

## File identity and compatibility

Onboarding and connected-session validation use a bounded Depth:0 PROPFIND of
the configured root. Success requires HTTP 207, exactly one matching self-entry,
and a collection resource type from a successful propstat. An OPTIONS response
or DAV header alone is not proof that a folder exists or is accessible; servers
that block OPTIONS or omit its DAV header can still work. Authentication,
permission, TLS and protocol failures retain the existing error paths, and
plain HTTP pages, file roots and out-of-root responses remain rejected.

This operation-based validation was informed by
[Leplayer's WebDAV provider integration](https://github.com/leisurehuang/Leplayer/blob/97ff55cf9792484f401087f196f85523d7f49d9c/Leplayer/Media/Models/MediaServerInfo.swift)
and [directory browsing](https://github.com/leisurehuang/Leplayer/blob/97ff55cf9792484f401087f196f85523d7f49d9c/Leplayer/Utils/FileSystem/FinderProvider.swift).
No implementation code or dependency was imported. Plozz retains its own
ephemeral credentials, trust policy, root containment and range validation.

[VLC iOS's WebDAV adapter](https://github.com/videolan/vlc-ios/blob/8a3eef32c0faa9bc8bf8f62a96b136972eb0fad0/Sources/Network/Server%20Browsing/Data/Protocols/WebDAV/VLCNetworkServerBrowserVLCMedia%2BWebDAV.m)
delegates to libVLC. Its
[WebDAV access module](https://github.com/videolan/vlc/blob/68e73a7b9f07f5a95fa77cb4cc4cac554e22f76d/modules/access/webdav.c)
likewise uses PROPFIND and the collection self-entry, and advertises both
`application/xml` and `text/xml`, as Plozz now does. VLC's
[Nextcloud trailing-slash correction](https://github.com/videolan/vlc/commit/b815b341c12477566d18e3fcec1cedd190d50614)
is already covered by Plozz's symmetric self-entry normalization. These are
behavioral references, not imported code or proof of server interoperability.
Plozz never promotes weak ETags to strong validators. Validator-free delivery
is a narrowly scoped streaming exception, not a durable file identity.

Directory listing and ordinary stat do not require a validator or read file
contents. When preparing a locator, `statForOpening` tries a bounded GET if DAV
metadata lacks both a strong ETag and modification time. This learns a real
identity without imposing seekability on sidecars. It never invents a timestamp,
ETag or size. Files with neither a usable DAV identity nor a same-resource GET
identity still cannot play.

GET-only identity discovery requires the exact stable DAV URL, not a redirected
resource: equal ETag strings on different resources are not comparable. Redirected
files therefore need a DAV ETag or modification time; a CDN validator alone cannot
be persisted as the stable file's identity. Opening reuses the identity-discovery
probe rather than resolving a second, potentially different delivery resource.

Opening a source revalidates its stored DAV metadata, including persisted
download locators, then probes the actual media representation. A different
delivery host can have a different ETag namespace, so its ETag is not compared
to the DAV ETag. The actual GET validator is pinned for the source lease.
Same-origin comparable DAV/GET validators and all declared sizes must agree.
The probe retains Last-Modified even when a stronger GET ETag is selected for
reads, so a date-based locator cannot skip its modification-time comparison.

After that DAV identity/size revalidation, playback may accept an anonymous
HTTPS delivery response with exact ranges but neither ETag nor Last-Modified.
This explicit `unvalidatedPlayback` mode is disabled by default in the HTTP
client, for direct DAV responses, and for scanner/metadata/artwork roles. Usable
validators remain preferred and enforced; malformed or weak-only headers cannot
enable this exception. Every network read still requires
the pinned URL, identity encoding, exact 206, offsets, total size and body length;
there is no URL refresh or redirect following within an active lease. Without
a validator, **same-size content changes during playback cannot be detected**.
No timestamp or ETag is fabricated.

These sources expose `supportsPersistentByteReuse == false` through their
source lease. Ranged playback bytes still cannot enter reusable disk caches or
resume a partial download. WebDAV additionally implements the separate
whole-file transfer contract: offline downloads issue one unconditional GET to
the pinned anonymous HTTPS delivery URL, without reusing the probe prefix.
Only HTTP 200, identity encoding and an exact complete byte count can succeed;
redirects, partial responses, changed sizes, cancellation and truncation fail.
The response is streamed to disk with backpressure, at most 4 MiB / 64 pending
callbacks, and the existing download rate limiter. No whole-file memory buffer,
credential forwarding, or relaxed TLS policy is introduced.

Interrupted whole-response downloads discard their partial bytes; every retry
or resume starts from zero after fresh DAV identity validation and delivery
resolution. Cancellation drains admitted writes before discarding the file.
Pause/background and profile retirement keep their existing queue ownership.
Completed files remain available offline, but no claim is made that validators
can detect a same-size replacement before the single response begins.
Ordinary validated sources retain their existing ranged/resumable behavior.

For playback files at least 256 KiB, the opening probe also supplies the first
media window, avoiding a separate two-byte request followed by a header GET.
Its complete body, offsets, size and selected validation mode are checked before any prefix
bytes become readable. The immutable prefix belongs to the source lease, not a
shared URL cache; cancellation and cursor retirement still apply. Reads crossing
its boundary use the selected range-validation mode. Small files, non-playback
roles and GET-only identity discovery keep the two-byte probe. The tradeoff is
up to 256 KiB retained per source, and potentially unnecessary prefix bytes for
a consumer that starts elsewhere or requests a larger first window. Remote
cache revalidation is unchanged.

Before a playback lease exists, an anonymous delivery connection failure
(`URLError.cannotConnectToHost`, -1004) permits exactly one fresh opening.
That opening repeats DAV identity/size validation before resolving another
delivery URL, then validates the complete new prefix. Recovery is recorded in
the `webdav` unified log without URLs or account data. Timeouts, TLS errors,
authentication/HTTP refusals, malformed ranges and cancellation do not trigger
this recovery; neither do DAV-origin failures or non-playback roles. Active
leases never refresh their pinned URL or validator, including after read failures.

Last-Modified is **change-detecting, not immutable**: it has one-second
precision and cannot detect a server replacing bytes while preserving both
timestamp and size. Strong ETags remain preferred. The metadata recheck adds
a PROPFIND per open; missing DAV validators add a two-byte GET during locator preparation.
No full-file download or mandatory HEAD is introduced. Each playback window
uses one validated range, up to 32 MiB. The transport reader can overlap
consumption with one bounded next window rather than doubling HTTP requests.
HTTP 429 establishes a session-local `Retry-After` cooldown (delta-seconds or
HTTP date, five-second fallback). Calls during it fail before starting another
request; there is no automatic retry or waiting-task queue. See
[disc playback](../../docs/playback-engines.md#media-share-disc-images) for the
memory/cancellation contract.

## HTTPS media delivery redirects

The initial GET must be inside the configured DAV root. Same-origin hops
remain root-bound. Only GETs (media probes and bounded sidecars/artwork) may
leave that origin, for an HTTPS DNS-host destination; IP literals, local
hostnames, URL userinfo, fragments and HTTPS downgrades are rejected.
Every hop is checked and the chain is capped at five redirects. Hostname
screening is not DNS-address pinning.

Once a chain leaves the DAV origin, every subsequent request uses an isolated
anonymous session with system TLS trust, even if a hop returns to the DAV
origin. No Authorization, cookies, Referer, shared credential storage or DAV
certificate override follows it. Authentication challenges on delivery
sessions fail instead of consulting account credentials. These sessions remain
owned by the original account/revision/role and are retired with that source.
Browsing never gains this cross-origin permission.

Resolved URLs can contain short-lived signatures. They stay inside the active
byte-source lease, never in persisted locators or diagnostics. Reads remain
bound to that URL and validator; an expired URL or a later redirect fails
rather than silently mixing representations. Retrying playback opens the
stable DAV path afresh. Bounded sidecar reads use the same redirect policy.

## Hosted WebDAV compatibility and evidence limits

Use the configured server's WebDAV root and credentials in the username/password
fields. Some services issue a dedicated key as the username; follow the service's
WebDAV authentication requirements. Prefer these fields to credential-bearing
URLs when the service supports both forms. No service-specific User-Agent,
CDN allowlist or media-URL lifetime is assumed.

Service API rate limits are not assumed to apply to WebDAV or media delivery.
The generic [rclone range checks](https://github.com/rclone/rclone/blob/d369079a1448c487d09d85bfe11382e16ea4e345/lib/rest/headers.go#L87-L155)
and [redirect handling](https://github.com/rclone/rclone/blob/d369079a1448c487d09d85bfe11382e16ea4e345/lib/rest/rest.go#L297-L361)
are useful compatibility precedents, not observations of every hosted service.

The validator and redirect regression fixtures use synthetic `URLProtocol`
responses. They do not establish a particular hosted service's ETag behavior,
redirect chain, real TLS/Basic/Digest interoperability, or a reported playback
outcome. Those still require a real-server retest.

When handoff diagnostics are enabled, rejected range probes and reads retain
the transport failure category, HTTP status, byte count, anonymous-delivery
flag and header classifications in the bounded local playback trace. ETags,
dates and ranges are classified as missing, invalid or usable (ETags also
distinguish weak/strong); no raw headers, paths, credentials or delivery URLs
are recorded. Locator-policy rejections have separate fixed check identifiers.

Share playback preparation also records a per-request ID, hashed item identity,
transport, elapsed time and the last stage reached (selection, locator, item or
sidecars). Failures retain allowlisted transport/model/native error codes rather
than raw descriptions; cancellation remains cancellation. Locator diagnostics
show listing fallback, file-size presence and validator availability without
publishing validator values. PROPFIND records depth, role, hashed resource, HTTP
status and response size; stat self-entry rejection records parsed/matching
counts and which metadata fields disagree, never their values. Identical duplicate
responses record a count; successful scanner listings omit per-request traces.
HTTP adapter errors are recorded before protocol-neutral mapping loses
their specific category. These diagnostics do not relax validation or introduce
retries, and contain no response bodies, filenames, URLs or credentials.
This distinguishes a missing validator from unsupported ranges. Entering the
streaming exception emits a fixed `PLAYBACK_COMPATIBILITY` diagnostic with
`persistentReuse=false`; retry behavior is unchanged.

## Opt-in real-server checks

`WebDAVLiveServerTests` runs the production URLSession transport against an owned
fixture and explicitly supplied public endpoints. Ordinary runs skip these
network-dependent tests. Set `PLOZZ_WEBDAV_LIVE_CONFIG` to JSON in the test scheme
environment with `shouldUseLaunchSchemeArgsEnv="NO"`; keep credentials outside Git.
The configuration contains `local` and `publicTargets` (each with `name`, `url`,
`username`, `password`, and optional `expectedStatus`), plus `files` (relative
fixture paths), `size` (bytes per fixture), and `prefix` (base64 first 1,024 bytes).
Optional `additionalOwnedTargets` runs the same full fixture checks against more
server implementations in one invocation. Seed each with identical files.
Set a target's optional `digestOnly` to `true` to prohibit Basic fallback while
testing a real Digest server.
Use a trailing-slash local root and seed the four encoding/nested-path fixtures
before running. The test only reads; it never uploads to public servers.

The owned fixture checks exact filenames, five collections with no repeated
self-entry, file sizes, and two validated `bytes=0-1023` reads per file against
the generated MP4 bytes. Inspect server-side logs to confirm authentication and
conditional headers without retaining their values. Public checks validate and
list the configured collection and read an existing suitable file when present.
An expected 401 or 404 verifies explicit failure handling, not interoperability;
the log distinguishes these outcomes and unexercised range reads.

The separate loopback regression in `WebDAVClientIntegrationTests` reproduces
IIS's combined Negotiate/NTLM/Basic challenge without a public-server dependency,
including repeated reads and rejection under Digest-only policy.

The owned matrix also covers Apache Digest authentication, rclone with MD5 ETags,
and Nextcloud/SabreDAV. Nextcloud 32.0.15 returned the entire resource for
`Range: bytes=0-0` despite HTTP 206. Default probes therefore request `bytes=0-1`;
playback-prefetch probes request `bytes=0-262143`. Both retain an exact response
cap and require matching offsets and body length (clamped only at EOF). This avoids the zero-end
quirk without accepting whole-file responses or relaxing validator checks.
