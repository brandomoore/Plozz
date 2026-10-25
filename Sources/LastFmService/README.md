# Last.fm

The existing TV music integration now includes **Listening history** in its
connected account page. Mobile does not currently instantiate this service or
wire its scrobbler; the shared history view does not add a mobile music playback
pipeline.

History browsing calls `user.getRecentTracks` with the app API key and the
connected username. This endpoint needs neither the user's session key nor a
signature; neither is sent. Reads use a captured profile/connection, same-origin
redirects, a 2 MiB response bound, and exactly one requested page of up to 50
dated scrobbles. A fixed `to` timestamp stabilizes the browsing window; refreshing
explicitly starts a new one. Page/user/total/count/order checks reject partial
results, and changing totals while paging requires a refresh. Concurrent remote
edits are still possible; this is not an atomic history snapshot.

The optional current track is separate from dated scrobbles and never counts as
a completed listen. Repeated plays are preserved, including equal timestamps;
Last.fm does not supply a unique play ID. Empty MusicBrainz IDs remain unknown.
Titles, artists and album labels are display data, not server matching evidence.
Profile changes, replaced credentials, disconnect and page cancellation fence
late responses. API errors, including HTTP-200 error envelopes, remain errors.
There are no automatic retries.

The page is read-only. It does not turn music listens into movie/TV watched
flags, alter server play counts, or enable historical backfill. Last.fm
scrobbling retains its existing playback path. A server-side music-history import
would need an explicit supported writer and verified recording identity; neither
is invented from title/artist strings.

Contract: [user.getRecentTracks](https://www.last.fm/api/show/user.getRecentTracks).
