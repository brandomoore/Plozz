# Plozz pairing links Worker

A tiny Cloudflare Worker that powers the **Universal Link** used by Sync & Setup
("set up another device"), Trakt and WeTrakr native PKCE callbacks, and community shortcuts. It claims only the
paths below on `plozz.app`; everything
else on the domain is still served by the existing `plozz-website` Worker.

| Path | Purpose |
| --- | --- |
| `/.well-known/apple-app-site-association` | AASA file mapping `https://plozz.app/pair` to the Plozz app (`N8Z5T4AK3X.com.thatcube.Plozz`). |
| `/pair` | Universal Link target. If Plozz is installed, iOS opens the app before this loads (pairing payload rides in the URL `#fragment`, never sent here). If not installed, Safari shows a "get Plozz / finish setup" page. |
| `/auth/trakt/callback` | Secretless PKCE callback intercepted by `ASWebAuthenticationSession`. A plain-text fallback never echoes or exchanges codes. |
| `/auth/wetrakr/callback` | WeTrakr's equivalent secretless HTTPS callback and non-sensitive fallback. |
| `/discord`, `/discord/` | Temporary (302), non-cached redirect to the Plozz Discord invite. Query parameters are not forwarded. |
| `/github`, `/github/` | Temporary (302), non-cached redirect to `https://github.com/brandomoore/Plozz`. Query parameters are not forwarded. |

The `/discord*` and `/github*` routes permit query strings on the shortcuts. Other
paths sharing those prefixes are passed through to the website unchanged. Targets are
not permanently cached, so they can be replaced if an invite or repository moves.

Use `https://plozz.app/discord` in the app, README, QR codes, and other public
community links. Keep the replaceable Discord invite only in the `/discord`
redirect target in `src/worker.js` and its regression test.

The AASA also declares `webcredentials` for the canonical app. Apple's HTTPS
authentication-session callback requires this association and the matching
`webcredentials:plozz.app` entitlement, not just the pairing `applinks` entry.
The Trakt registration must list `https://plozz.app/auth/trakt/callback` exactly.
The WeTrakr registration must list `https://plozz.app/auth/wetrakr/callback`.
No client secret, server token exchange, CORS origins or callback analytics are
needed. Keep request logging disabled so callback query strings are not retained.

## Deploy

```bash
cd web/pairing-links
node --test tests/worker.test.mjs
npx wrangler@4 versions upload --message "Update community redirect"
# Inspect the uploaded version and retain the current version for rollback.
npx wrangler@4 versions view <uploaded-version-id>
npx wrangler@4 versions deploy <uploaded-version-id>@100%
```

Requires wrangler logged in to the Cloudflare account that owns the `plozz.app`
zone. For an existing deployment, capture the live source, version, settings,
bindings, routes, and HTTP responses before uploading. Confirm the source matches
the deployed handler and verify the staged version changes only the intended
target. Version deployment leaves existing routes and domains unchanged; do not
deploy the website Worker or synchronize routes for a target-only update.

## Publishing note

`APP_STORE_URL` in `src/worker.js` points to the released Plozz Player listing:
`https://apps.apple.com/app/plozz-player/id6782668147`. The `/pair` fallback
uses the App Store, not the optional TestFlight beta. Keep it aligned with the
main README and the website's primary install buttons.
