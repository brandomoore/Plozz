# Plozz pairing links Worker

A tiny Cloudflare Worker that powers the **Universal Link** used by Sync & Setup
("set up another device") and Trakt's native PKCE callback. It claims only the
paths below on `plozz.app`; everything
else on the domain is still served by the existing `plozz-website` Pages project.

| Path | Purpose |
| --- | --- |
| `/.well-known/apple-app-site-association` | AASA file mapping `https://plozz.app/pair` to the Plozz app (`N8Z5T4AK3X.com.thatcube.Plozz`). |
| `/pair` | Universal Link target. If Plozz is installed, iOS opens the app before this loads (pairing payload rides in the URL `#fragment`, never sent here). If not installed, Safari shows a "get Plozz / finish setup" page. |
| `/auth/trakt/callback` | Secretless PKCE callback intercepted by `ASWebAuthenticationSession`. A plain-text fallback never echoes or exchanges codes. |

The AASA also declares `webcredentials` for the canonical app. Apple's HTTPS
authentication-session callback requires this association and the matching
`webcredentials:plozz.app` entitlement, not just the pairing `applinks` entry.
The Trakt registration must list `https://plozz.app/auth/trakt/callback` exactly.
No client secret, server token exchange, CORS origins or callback analytics are
needed. Keep request logging disabled so callback query strings are not retained.

## Deploy

```bash
cd web/pairing-links
npx wrangler@4 deploy
```

Requires wrangler logged in to the Cloudflare account that owns the `plozz.app`
zone. Worker routes take priority over Pages for matching paths, so this never
touches the rest of the site.

## Publishing note

`APP_STORE_URL` in `src/worker.js` is empty until Plozz is published; the `/pair`
page adapts its copy. Set it to the App Store (or public TestFlight) URL and
redeploy once available.
