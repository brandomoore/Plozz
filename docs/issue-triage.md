# Automated issue triage

The **Issue triage** GitHub Actions workflow maintains evidence-backed
assessments of existing reports. It does not fix code, accept feature requests,
or close issues. GitHub issues remain the source of truth; these records can
also feed a public website board without creating another backlog.

## What the status means

| Label | Meaning |
| --- | --- |
| `triage: needs evidence` | Specific missing information blocks investigation. |
| `triage: investigate` | There is an actionable report or code-supported hypothesis. |
| `triage: verify` | A specific relevant change needs affected-user confirmation. |
| `triage: backlog` | A feature request, not a commitment or delivery date. |
| `awaiting release` | Owned by the existing [delivery watcher](discord-bridge.md#delivery-gated-issue-resolution), not this agent. |

Each issue gets at most one current workflow-owned assessment comment, updated
in place. It records the reported app build, the evidence, and one next action.
Machine-readable records sit inside a collapsed **Automation details** section.
After safe outputs succeed, a deterministic formatting job adds only the
disclosure wrapper; it preserves the assessment, JSON and provenance exactly.
It never modifies human comments or other bots' records. To preview a bulk
presentation update, run `python3 tools/format-triage-comments.py`; add `--apply`
to update the workflow-owned comments in place.
Unknown builds stay unknown. Static code inspection is not reproduction, and a
merge is not delivery. New reports after a shipped fix remain actionable.

## Running and activation

This uses [GitHub Agentic Workflows](https://github.github.com/gh-aw/), not the
separate private-repository-only Copilot cloud automations product. Execution
runs on GitHub-hosted runners and does not require the maintainer's computer.

1. Enable GitHub Actions and configure the repository Actions secret
   `COPILOT_GITHUB_TOKEN` with a fine-grained personal access token. Its user
   needs a Copilot entitlement and **Account permissions > Copilot Requests >
   Read**. Never put the token in source, a workflow input, an issue, or a log.
2. Land `issue-triage.md` and its generated `issue-triage.lock.yml` on the default
   branch. Run **Issue triage** manually. With publication disabled, safe
   outputs appear only as previews in the Actions run; no labels/comments are
   changed.
3. Verify that both the assessment and threat-detection jobs actually use
   `gpt-6.1-sol` at high effort, and inspect authentication, output quality
   and billed usage. Availability here is not guaranteed by desktop access.
   The workflow disallows switching to another model. The primary job also
   disables token steering.
4. Set repository variable `PLOZZ_TRIAGE_PUBLISH=true` to permit label/comment
   updates from main. Set `PLOZZ_TRIAGE_ENABLED=true` to enable automatic
   triggers. Leave either unset to retain its corresponding safety gate.

Automatic triggers are pushes to main, new/edited/reopened issues, issue
replies, published releases, and a daily catch-up. Bot-triggered activity may
be filtered by the platform; the catch-up reads public reports regardless of
who created them. Runs serialize and process at most 20 assessments, with
oldest/unassessed reports reserved space. Initial backfill can therefore take
multiple runs. This is eventual refresh, not an instantaneous completeness
guarantee.

GitHub reads are restricted to `brandomoore/Plozz` with `min-integrity: none`,
so reports and replies from new community members are included. The default
public-repository `approved` integrity filter silently omits some of them.
This explicitly broadens readable input, not write authority or trust:
all report content remains untrusted, and output safety review stays required.

Only the four `triage:` labels and the workflow's own assessment comments can
be changed. Source, release state, issue state, assignments, milestones and
existing human labels are outside its write capabilities. A separate
threat-detection job must succeed before safe outputs are applied; detection
and workflow failures remain in Actions rather than creating more bug issues.

The v1.0.1 compiler's external detector does not forward reasoning arguments,
so this workflow uses its supported inline detector. That path preserves
high effort. Detection does not inherit the primary sandbox's model policy;
an explicit same-model-only retry list disables its implicit alternate-model
fallback, and delegation is disabled. The detector can still emit budget
notices; those are not permission to change models.

Actions execution and Copilot inference have separate billing rules. Verify
the account's model entitlement and usage; do not assume an unlimited desktop
model entitlement transfers to Actions.

The initial hosted previews found `mai-code-2-flash` in the credential's model
catalog, first without pricing and then rejected by the upstream service:
`no model endpoints available given user constraints`. Listing a model is not
proof that the credential can use it. The maintainer approved switching both
jobs to `gpt-6.1-sol` at high effort. Its pricing is supplied by the compiler's
catalog and the runtime provider; no custom accounting estimate is retained.
Inference uses the token owner's Copilot entitlement. Consult that account's
billing for actual consumption rather than treating workflow estimates as an
invoice.

## Durable evidence and website consumption

The generated comment footer includes the workflow identity and a link to the
evidence run. The comment's **Structured data** JSON is the durable record.
Consumers must require the `github-actions[bot]` author and `issue-triage`
workflow marker, validate supported schema versions and matching issue number, and
treat all strings as untrusted text. Render text safely, never as raw HTML.

Records include `checked_sha`, `checked_at`, reported and last-reported app
builds, `last_report_at`, `status`, `assessment`, relevant source paths, public
evidence URLs and `next_action`. Version 2 uses arrays of individual strings for paths and
URLs. Version 1 used newline-separated strings; valid legacy records remain
readable, but malformed JSON must be reassessed, not guessed or repaired by
parsing fragments. Multiple escaped-newline-separated URLs can be misread by
the v1.0.1 publication sanitizer, so new records must use version 2 arrays.
A new issue with no record is **Not assessed**, not implicitly confirmed or
fixed. Show assessment age and the inspected source revision. New substantive
replies or relevant code changes mean **Awaiting reassessment** until checked;
never relabel an old assessment as current just because the board refreshed.

The website board itself is a separate consumer in `brandomoore/plozz-website`;
this workflow does not deploy that site or grant cross-repository access.
Use live GitHub issue state and the delivery watcher's receipts for closure
and released-build information, not an AI inference.

## Editing the workflow

The Markdown file is the source of truth. Use the pinned authoring compiler:

```sh
gh extension install github/gh-aw --pin v1.0.1
gh aw compile issue-triage
```

Commit the Markdown and compiled lock file together. Do not hand-edit the
lock file or run `gh aw init` merely to update this workflow; repository-wide
agent configuration is unnecessary. After changing models, permissions,
triggers or outputs, run a publication-disabled preview before enabling
automatic writes again.
