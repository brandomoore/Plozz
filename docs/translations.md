# Translating Plozz

How translations are sourced, reviewed and shipped. For the engineering rules —
what makes a string translatable in the first place — see
[`localization.md`](localization.md).

## Current production system

Translations are produced and independently reviewed using the selected
high-capability language model, then treated as untrusted batch input. Agents never edit
`Localizable.xcstrings` directly:

1. A source packet contains every key, English value, translator comment, and
   Apple plural/substitution structure.
2. A translator owns one bounded, multilingual delta batch outside Git. Small
   changes group up to six languages; larger changes split by key budget.
   Every language/key pair has exactly one owner.
3. A separate reviewer checks every entry against the source and comments,
   fixes terminology/grammar/context, and reviews any changed system permission
   prompts. The coordinator records the actual author and reviewer identities.
4. `tools/l10n-import.py` requires exact key coverage, nonempty values,
   `needs_review` provenance, canonical BCP-47 tags, unchanged placeholder types,
   valid plural leaves, and all permission prompts. It merges into temporary
   catalogs first and makes Apple's `xcstringstool` compile all three.
5. Only the importer writes the repository catalogs.

`tools/l10n-source-snapshot.json` fingerprints the source text, translator
comment, English variation structure, and three permission prompts from the
last completed pass. That catches changed semantic-key values and permission
copy even when a non-English localization still exists under the same key.

This is deliberate. `Localizable.xcstrings` is one large JSON file; allowing
parallel agents or translator pull requests to edit it directly creates merge
conflicts and makes one malformed language capable of corrupting every other
language.

### Why model translation is acceptable here

Plozz accepts useful, complete model translations over an English-only app.
Perfect native review before first release is not the gate; users can report a
poor phrase and corrections are cheap.

That policy is viable because this catalog has unusually strong context:

- 960 keys say where the string appears and what every placeholder contains.
- Ambiguous English collisions have separate semantic keys: the switch state
  “Off” is not the subtitle picker's “Off”; the network-share noun “Share” is not
  the diagnostics action verb.
- Runtime content and product/codec brands are separated from copy.
- Counts use real Apple plural variations, including independent substitutions
  for strings with two counts.
- An independent reviewer is a separate agent, using the selected model and
  reasoning effort unless an explicit permitted override applies.
- Structural gates reject output that would crash, drop a number, corrupt a
  placeholder, or make a language silently fall back to English.

Every model-generated unit remains `needs_review`. That is provenance, not a
release blocker. A later native-speaker correction changes the unit to
`translated`.

## Languages

Plozz ships 36 non-English languages:

- Arabic, Bulgarian, Catalan, Croatian, Czech, Danish, Dutch
- Finnish, French, German, Greek, Hebrew, Hindi, Hungarian
- Indonesian, Italian, Japanese, Korean, Malay, Norwegian Bokmål
- Polish, Brazilian Portuguese, Romanian, Russian
- Serbian (Latin), Slovak, Slovenian, Spanish, Swedish, Thai, Turkish
- Ukrainian, Vietnamese, Simplified Chinese, Traditional Chinese, Persian

This set deliberately covers hard engineering cases, not just reach. German
stresses long labels; Polish/Russian/Ukrainian/Czech/Slovak exercise multi-form
plurals; Slovenian exercises the dual; Arabic/Hebrew/Persian exercise
right-to-left layout and logical navigation symbols.

## Quality gate

A model-generated language can ship when:

1. It has all catalog keys and all three permission prompts.
2. A separate reviewer completed a full independent review.
3. The importer passes placeholder, plural, locale-tag, state, and key-set
   validation.
4. `xcstringstool` compiles the merged app and permission catalogs.
5. Both platform builds and the full test suite pass.
6. `AppLanguage.releaseReady` explicitly includes the tag.

`needs_review` remains visible in `--coverage`; it tells maintainers what still
lacks native review without hiding a usable language from users.

## Commands

```sh
# Early development preflight: validates source/plurals/permissions without
# requiring translations that the next plan is meant to produce.
python3 tools/l10n-sync.py --validate-source

# Sync the current dual-platform source before planning. Exact compiled extraction
# may be reused after catalog-only edits; current catalog validation is never skipped.
python3 tools/l10n-sync.py --reuse-if-unchanged

# Rebuild disposable full-language artifacts from the committed catalogs. This
# makes incremental translation self-contained; no prior agent session is needed.
tools/l10n-export-artifacts.py /tmp/plozz-translations

# Plan only missing/stale work, including changed permission prompts.
# Use a fresh output path: planning never overwrites in-flight work.
python3 tools/l10n-batches.py plan /tmp/plozz-batches

# After every batch has been authored and independently reviewed, assemble
# new full artifacts. This does not modify the original artifacts or catalogs.
python3 tools/l10n-batches.py merge \
  /tmp/plozz-batches/manifest.json /tmp/plozz-translations \
  /tmp/plozz-reviewed-translations

# Import the complete reviewed result; snapshot update remains after final gates.
python3 tools/l10n-import.py /tmp/plozz-reviewed-translations \
  --allow-translated-state --require-info-plist --apply

# Build a full packet, or only keys missing/stale for a language after a merge
tools/l10n-export-source.py /tmp/source.json
tools/l10n-export-source.py /tmp/fr-delta.json --missing-for fr

# Validate isolated language files without changing the catalog
python3 tools/l10n-import.py <artifact-dir> \
  --languages de,fr,es \
  --allow-translated-state \
  --require-info-plist

# Merge only after every listed language passes
python3 tools/l10n-import.py <artifact-dir> \
  --languages de,fr,es \
  --allow-translated-state \
  --require-info-plist \
  --apply

# Only after reviewed import and every final gate succeeds
tools/l10n-export-source.py /tmp/final-delta.json \
  --missing-for nl \
  --update-snapshot

# Catalog and source-code gates
python3 tools/l10n-sync.py --coverage
python3 tools/l10n-sync.py --validate-only
tools/l10n-export-source.py /tmp/delta.json --missing-for nl --check-snapshot
tools/l10n-guard.sh
```

## Batch ownership and review

The planner groups languages with identical missing/stale keys and preserves
each locale's distinct gaps. Defaults are six languages, 200 language/key pairs,
and 64 KB of source-unit data multiplied by language count per batch. Both app
strings and permission prompts count toward the limits. An oversized single
entry fails explicitly; increase its budget rather than splitting a plural or
silently dropping work. English plural errors also fail before dispatch, so
translations are not commissioned against an unusable source structure.

For a 19-key change across 36 languages, this produces **six author tasks and
six independent review tasks**, not 36 authors plus reviewers. All 684
translations still get reviewed. Read the bounded source packet and targeted
terminology references, not the entire catalog in every task. Reconstruct full
artifacts once, then merge them once through the coordinator.

`manifest.json` assigns each batch its source packet, output/review templates,
draft, reviewed output, and review-evidence path. Authors write only their draft.
Reviewers write a separate reviewed output; they must not review their own
authored batch. Different batches may cover different keys in the same language,
but no agents write the full-language artifacts or repository catalogs.

Use the main session's selected model and effort explicitly for every task,
subject to the operator's provider policy and any explicit override. A different
provider is not required for independent review. The planner does not launch
models, choose fallbacks, or change those selections.

The coordinator verifies completed reviewer results, then completes the generated
review template with the actual author/reviewer task IDs, models and efforts,
SHA-256 hashes of both output files, and `verdict: "approved"`. The template
already declares the exact source hash, languages, ordered keys, permission
prompts and unit count. It starts pending and cannot be accepted unchanged.

Assembly rejects stale/tampered plans, missing reviews or units, self-review,
changed reviewed files, incorrect placeholders, and dishonest `translated`
provenance. It runs the existing delta merger in isolation, then the full
importer and Apple's catalog compiler before publishing the output directory.
Any failure leaves the input artifacts and repository catalogs unchanged.
Only the final explicit `l10n-import.py --apply` writes repository catalogs.

## Change-scoped pre-main pass

Before exporting translation packets, validate the English catalog with
`tools/l10n-sync.py --validate-source`, including its count/plural structures.
This permits missing translations that the upcoming plan is intended to supply;
`--validate-only` remains the complete current-catalog check.
For reviewed source-only corrections, `l10n-import.py --source-delta` accepts a
source-language artifact containing only existing keys, with `deltaKeys` in exact
translation order and `sourceCatalogSHA256` matching the exported catalog hash.
All changed units must remain `needs_review`. This preserves implicit English
fallbacks and unrelated source states instead of manufacturing a full English
translation. It cannot change permission prompts; ordinary language imports still
require full coverage. Re-export and review affected translations after changing
source wording or plural structures.

Localization runs when relevant source/context changes, not on a timer or merely
because a branch is landing. The committed
`.githooks/pre-push` gate activates only for a push targeting `main`; ordinary
feature-branch pushes stay fast. The repository uses `core.hooksPath=.githooks`.

The agent assesses changes to translatable source, comments, plural structures,
and permission text. If these changed without sufficient current-source evidence:

1. Validate and sync the English source catalog, using
   `l10n-sync.py --reuse-if-unchanged` when complete extraction evidence matches;
2. Plan the exact missing-or-source-changed delta, including permission prompts,
   using the committed source fingerprint snapshot;
3. For a nonempty plan, export disposable artifacts, assign bounded batches to
   an author and a separate reviewer, and check complete coverage using actual
   task identities;
4. Assemble reviewed batches through `l10n-batches.py merge` (which reuses
   `l10n-merge-delta.py`) and import only through `l10n-import.py`.
5. Run catalog/source guards and the relevant checks justified by the change,
   following `testing-policy.md`; retain the importer's Apple compiler checks.
6. Update the source snapshot only after the selected checks pass, then publish
   the explicitly authorized main update after verifying main has not moved.

When the plan reports **zero units and zero batches**, there is nothing to author,
review, assemble, or import. Skip the full-language artifact round trip and
continue with source/catalog guards and the selected checks. Do not manufacture
review evidence for an empty delta or trigger a full app matrix merely to merge.

The pre-push hook checks the current catalog's language coverage, snapshot, and
source guard without building. It does not prove that new Swift source has been
extracted: that is the agent's responsibility when assessing relevant changes.
A failed check requires completing the translation pass on the feature branch
before retrying. Distribution retains its complete localization safeguards.

This is a safety net after feature work, not permission to put user-facing
`String` values back into models. The source guard still requires copy to use
the localization-safe APIs documented in `localization.md`.

Importer regression tests run in CI because Apple’s compiler does **not** reject
every unsafe plural shape. During review, `xcstringstool` accepted a plural
category that dropped its count and another that added a nonexistent runtime
argument; the importer now blocks both.

## Corrections

Native speakers do not need a translation platform account. A translation issue
should identify:

- language;
- screen;
- current wording;
- better wording and, when useful, why.

The correction can be made directly in Xcode's String Catalog editor or in the
catalog JSON, validated, and shipped. A future Crowdin/Weblate-style platform is
optional community infrastructure, not a dependency for language support.
