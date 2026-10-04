# Discord support forums and GitHub issues

GitHub remains the canonical Plozz backlog. The bridge makes the Discord `bugs`
and `feature-requests` forums another way to contribute to it without maintaining
a separate triage queue.

**Installing the workflow does not activate public mirroring.** Its push-triggered
preflight is read-only. Live synchronization requires an explicit activation
variable, a public-posting notice, and the workflow on `main`.

## Behavior

- A new human-authored forum post is compared with open GitHub issues of the
  appropriate kind. Copilot links a clearly equivalent report to an existing
  issue, or creates a new `bug` / `enhancement` issue when no confident match exists.
  Closed issues are not candidates for new reports; existing links remain intact.
- Report text and subsequent human replies are copied to GitHub with attribution
  and links to their Discord originals. Edits update bridge-managed content.
  Maintainer text outside the marked regions is preserved.
- The forum's default reaction counts as a vote, falling back to thumbs-up when
  no default is configured. Unique non-bot voters are counted across all Discord
  posts linked to an issue. Normal and burst reactions from the same person count
  once. The total is a bot-owned GitHub comment, not impersonated GitHub reactions.
- GitHub comments on linked issues and issue open/closed status flow back to
  Discord. Queued replies are sent oldest-first by creation time, with comment
  IDs breaking ties; editing an older comment does not move it to the end.
  A failed send stops later replies to that thread from overtaking it. Long
  comments are split without dropping content. Bot imports do not bounce between
  services. The bridge never closes or reopens a GitHub issue.
- Other channels, private threads, bot-created posts, and posts created before
  the published activation timestamp are excluded.

The scheduled action runs approximately every 15 minutes, not in real time.
Synced replies appear when delivered: Discord cannot insert a delayed GitHub
reply retroactively between native Discord messages already posted. Additional
parts introduced by expanding an older GitHub comment also appear when synced.
GitHub can delay or skip scheduled runs and can disable schedules after prolonged
repository inactivity. Standard hosted runners are free for public repositories;
Copilot matching uses the authenticated account's allowance and policies.

Copilot runs only when classifying a new report, or during an explicit connection
preflight. Existing links and vote/status updates are deterministic. Authentication,
model, or malformed-response failures leave new reports pending and fail the run
visibly; they do not silently create duplicates or choose another model.

## One-time setup

The configured server and forum IDs are in `tools/discord-bridge.py`. The bot needs
View Channels, Read Message History, Send Messages in Threads, and Embed Links in
both forums, plus Message Content Intent. Administrator, Presence Intent, and
Server Members Intent are unnecessary. Set each forum's default reaction to
thumbs-up for a consistent voting affordance.

Repository Actions secrets:

| Secret | Purpose |
| --- | --- |
| `DISCORD_BOT_TOKEN` | The configured Discord bot's token. |
| `COPILOT_GITHUB_TOKEN` | A personal fine-grained PAT with only the Copilot Requests account permission. |

Issue/comment writes use the job's separate built-in `GITHUB_TOKEN`. Do not grant
the Copilot credential repository-write permissions. Tokens are never committed.
Choose token expiration according to the account owner's maintenance and security
requirements; a nonexpiring token must still be revoked if compromised.

The public Copilot CLI package is version-pinned in the workflow. The selected
model and reasoning effort are explicit in the script. The preflight must
successfully verify that exact selection for the credential's account before
activation. No provider/model fallback is configured.

### Public-posting notice

Publish this in the guidelines of **both** forums before activation:

> Posts and replies automatically sync to GitHub

The bridge verifies that this notice remains in both forums' guidelines before
processing reports, including dry runs. Extra forum-specific instructions can
surround it; whitespace and line breaks can vary. Removing the notice stops
mirroring even if the activation variable remains enabled.

After approval of the notice and live operation:

1. Run **Discord issue bridge -> Run workflow -> preflight** on the reviewed
   revision. Verify both forum connections and the exact Copilot model.
2. Set repository variable `DISCORD_PUBLIC_SINCE` to the UTC timestamp after both
   notices were published, for example `2026-01-01T12:00:00Z`. Only later-created
   posts are eligible; this timestamp is not retroactive publication consent.
3. Run `dry-run` to inspect proposed routing without changing either service.
   Dry-run output contains thread IDs and decisions, not report contents.
4. With the reviewed workflow on `main`, set `DISCORD_BRIDGE_ENABLED` to `true`
   and run `sync`. Confirm an approved test post, reply, edit, duplicate, vote,
   and GitHub reply/status change reach the intended destinations.

Remove or set `DISCORD_BRIDGE_ENABLED` to `false` to stop scheduled writes.
Do not advance the notice timestamp after linking posts: that would exclude
existing sources and make vote totals incomplete.

## Operational limits and recovery

Mappings live in the bot-authored GitHub report bodies/comments and Discord
message footers, not in an expiring Actions cache. Keep those identifiers and
managed-region boundaries intact. Untrusted users cannot establish a mapping
by pasting a marker into their own GitHub issue or Discord message.

The workflow serializes runs. It discovers existing mappings before writing;
ambiguous POST failures are not immediately retried. A later run can recover a
successfully created remote record after a lost response. Discord writes also
use deterministic nonces. A partial source failure never publishes a partial
voter set as a complete total. Check failed Actions runs rather than repeatedly
rerunning a job without reading its error.

Locked Discord threads retain inbound synchronization but defer outbound updates
with a warning until unlocked. No Manage Threads permission is used. Posting a
GitHub reply to an unlocked archived thread may unarchive it. Previously linked
threads that disappear cause a visible failure rather than silently reducing
their vote counts.

Deletions are not propagated between services. For sensitive content, remove or
edit the Discord source first, then remove every GitHub copy and any mirrored
Discord copies. Otherwise the next run may restore a missing managed GitHub
record from its still-present source. Do not rely on the bridge to detect secrets
inside free text, screenshots, or attachments.

Discord attachment links can expire. The bridge copies their links and provides
the original Discord message link; it is **not** a durable attachment archive.
Upload an important diagnostic attachment to GitHub separately if permanent
availability there is required.

Copilot matching is conservative, not infallible. An incorrect link needs a
maintainer correction; ordinary reports do not require manual approval. Large
backlogs can exceed API or matching-context budgets; those failures are explicit
instead of silently truncating candidates or report text.

Offline regression tests:

```bash
python3 -m unittest discover -s tools/tests -p 'test_discord_bridge.py'
actionlint .github/workflows/discord-bridge.yml
```
