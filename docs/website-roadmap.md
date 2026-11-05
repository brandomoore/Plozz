# Website roadmap refresh

The public board at [plozz.app/roadmap](https://plozz.app/roadmap/) is owned by
[`brandomoore/plozz-website`](https://github.com/brandomoore/plozz-website).
Its verified feed, delivery rules, cache and production deployment procedure
remain documented in that repository's README.

`Refresh website roadmap` requests a fresh website export when issues or issue
comments change, after main pushes or release changes, and after the issue
triage, Discord issue bridge or TestFlight issue-resolution workflows finish.
The workflow-completion triggers also cover writes made with `GITHUB_TOKEN`,
which do not emit new issue-triggered workflow runs. Pull-request comments and
workflow runs from other repositories cannot trigger the job.

The dispatcher always runs trusted `main` code and requests only
`brandomoore/plozz-website`'s `roadmap-feed.yml` on `main`. It does not evaluate
issue content, forward event payloads, change labels, publish data, or infer
delivery. GitHub remains canonical; the website's existing verification must
succeed before it publishes anything.

## Activation

With maintainer approval, create a dedicated expiring fine-grained GitHub token:

- Resource owner: `brandomoore`.
- Repository access: **only `brandomoore/plozz-website`**.
- Repository permissions: **Actions: read and write**, plus required Metadata read.
- No Contents, Issues or other optional permissions.

GitHub cannot restrict an Actions-write token to one workflow. The dispatcher
itself fixes that target; do not describe the credential as workflow-scoped.
Do not reuse the broad Copilot credential or extend the roadmap editor app's
permissions.

Save the token directly as the **Plozz** repository Actions secret
`WEBSITE_ROADMAP_DISPATCH_TOKEN`, without putting it in chat, files or command
arguments. Then set the Plozz repository variable
`WEBSITE_ROADMAP_REFRESH_ENABLED=true`. The website's independent
`ROADMAP_FEED_ENABLED=true` switch must also remain enabled.

After both repositories' reviewed changes land, manually dispatch
`website-roadmap-refresh.yml`. Verify the downstream website run succeeded,
then verify the timestamp and expected cards at `https://plozz.app/api/roadmap`.
An accepted dispatch alone is not proof of publication.

## Reliability and recovery

Both repositories serialize refresh runs without cancelling an active run;
bursts can replace pending runs because each export reads the complete current
state. The website retains its roughly fifteen-minute scheduled fallback for
missed events and external App Store/TestFlight availability changes.
Event-driven runs avoid dependence on that cron for normal issue updates,
but GitHub outages and runner delays can still postpone them.

Dispatch retries transient HTTP and transport failures at most three times
within a two-minute budget, respecting bounded `Retry-After` delays. A lost
acknowledgement can cause duplicate dispatches; downstream concurrency
coalesces them, and all exports independently verify their data. Authentication,
permission, missing-workflow and other permanent errors fail immediately.
Failures are visible in Actions, not reported as successful refreshes.

If publication is stale, inspect both workflows. Fix expired/missing credentials
or validation errors, then dispatch a **fresh** refresh rather than publishing
an old artifact. Disable event-driven refresh with
`WEBSITE_ROADMAP_REFRESH_ENABLED=false`; the website's scheduled fallback is
independent. Rotate the dedicated credential before its expiry.

Run the offline dispatcher checks with:

```sh
python3 -B -m unittest discover -s tools/tests -p test_refresh_website_roadmap.py
actionlint .github/workflows/website-roadmap-refresh.yml
```
