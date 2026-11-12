# ProviderSubsonic

Music-only Subsonic/OpenSubsonic provider, offered as **Navidrome (Subsonic)**
in development/TestFlight onboarding. The named entry opens sign-in directly;
Plex, Jellyfin and Emby retain their ordinary sign-in and automatic music discovery.

## Contracts

- Address, username, and password or API key. Passwords become a salted protocol
  token; the token/salt or API key stays in the existing account Keychain.
  The normalized origin and reverse-proxy subpath identify the server.
  API-key sign-in also verifies the supplied username with `getUser` before
  binding the credential to an account.
- One virtual Music library respects the existing profile/account/library
  selection. It contributes no movie/show catalogue or Live TV discovery.
- Artists, albums, songs, genres and read-only playlists use the standard REST
  endpoints. Song paging walks albums incrementally instead of relying on
  nonstandard empty-search behavior. Repeated album pages fail explicitly.
  Playlist order and duplicate song occurrences are preserved.
- Playback uses the existing player and account/revision-scoped HTTP resolver.
  Known native audio containers request `format=raw`; others request MP3
  transcoding. Actual compatibility and transcoding availability remain
  server-dependent.
- Favorites use `star`/`unstar`. Now-playing and qualified listening submissions
  use `scrobble`; seeking ahead alone does not count as listening.
- Persisted artwork and playback references contain no credentials.
  Authentication is attached only at the network boundary, after active-account
  and credential-revision checks. Metadata/artwork transport uses an ephemeral,
  offline-aware session, no URL cache, and same-origin redirects.

## Initial limits

No folder picker, alternate connection addresses, playlist editing, server-side
lyrics or server-history rails yet. Existing optional lyrics fallback still
applies. Music browsing uses server album order and indexed artists, rather than
claiming arbitrary server-side sorting. Classic servers requiring plaintext
password authentication instead of salted tokens are not supported. API-key
availability depends on the server.

Protocol behavior was compared with the user-owned GPL Mozz implementation and
the published Subsonic API. Primuse was consulted for compatibility considerations;
no AGPL implementation was copied.
