# Home navigation baseline

This is the bounded documentation pilot from the
[architecture roadmap](../architecture-roadmap.md#ordered-work-queue).
The [Home task map](../../Sources/FeatureHome/README.md#where-to-look-first)
now links behavior, code owners, and regression entry points.

## What changed

The entry guide changed from 1,850 lines / 132,767 UTF-8 bytes to 95 lines /
8,980 bytes. Its existing behavior documentation moved into six topic guides;
it was not discarded. The entry and six guides together contain 2,001 lines /
141,638 bytes, including new navigation and headings. Reading all of them is
therefore more expensive than reading the old guide.

The intended improvement is selective entry: find the relevant owner and
coverage without reading unrelated contracts. Existing README heading links
remain valid. Shared state-management, testing, and performance policy still
have their original owners.

These are structural measurements, **not measured token savings, faster
investigation, or application performance improvements**. Application source,
tests, package targets, and runtime behavior are unchanged.

## Three fixed discovery tasks

The baseline source is commit `11ca729448223705e7b7b14122f23603711e50ba`.
The following retrieval sets were selected after inspecting the code, before
reorganizing the guide. They measure known-file discovery, not an unfamiliar
reader's search strategy or the full context needed to implement a change.

| Task | Files | Range reads | Search calls | Selected excerpts + search output, UTF-8 bytes |
| --- | ---: | ---: | ---: | ---: |
| Locate detail Play-target ownership and regressions | 6 | 9 | 1 | 13,869 |
| Find Home return timing, lifecycle delivery, and tests | 5 | 5 | 1 | 17,096 |
| Locate Continue Watching tap-action UI, profile persistence, and tests | 5 | 8 | 1 | 12,618 |

One search means `rg -n PATTERN` over the task's listed files, followed by the
listed bounded excerpts. The counts exclude tool wrappers, line-number metadata
on reads, earlier exploration, and subsequent implementation context.
Local retrieval took 0.059082, 0.015349, and 0.011467 seconds respectively in
one run. These are I/O/search timings, not investigation time; they have no
statistical significance. Actual agent tokens, billing, and end-to-end
investigation time were not captured.

The detail task stops at locating owners; runtime account selection and
`MediaItem` routing still need review before changing playback. The settings
task stops at persistence/UI; consumer behavior needs its own checks.

For code changes, the existing explicit-suite commands are:

| Task | Shared correctness checks |
| --- | --- |
| Detail selection or refresh | `tools/test-fast.sh FeatureHomeCoreTests FeatureHomeTests` |
| Home refresh rules | `tools/test-fast.sh FeatureHomeCoreTests FeatureHomeTests` |
| Home preference persistence/consumption | `tools/test-fast.sh CoreModelsTests FeatureHomeTests` |

These are commands to select existing coverage, not results from this docs-only
batch. Use the [testing policy](../testing-policy.md) and
[build-lease protocol](../apple-maintenance-windows.md) for execution. The entry
map additionally identifies hosted/UI checks; package checks alone do not prove
notification delivery, real navigation, focus, or live-provider behavior.

## Reproduce the byte baseline

Run this read-only snippet at the repository root with Python 3, Git, and
ripgrep available. It reads pinned Git objects without switching branches or
writing files. The per-file replay prefixes each match with its path to reproduce
the original single multi-file search output. Ranges are inclusive,
one-based, clipped at EOF, and tied to the baseline commit rather than current
line numbers.

```python
import subprocess

base = "11ca729448223705e7b7b14122f23603711e50ba"
readme = "Sources/FeatureHome/README.md"
tasks = [
    ("detail-play-target",
     r"playbackSources|func playItem|func playbackItem|testSingleSourcePlayback", [
         (readme, [(21, 41), (949, 1000), (1814, 1827), (1844, 1850)]),
         ("Sources/FeatureHomeCore/ItemDetailViewModel.swift", [(429, 441)]),
         ("Sources/FeatureHomeCore/DetailPlaybackSelection.swift", [(265, 282)]),
         ("Sources/FeatureHome/ItemDetailView.swift", [(1062, 1098)]),
         ("Sources/AppShelliOS/PlozziOSItemDetailView.swift", [(1116, 1160)]),
         ("Tests/FeatureHomeTests/ItemDetailViewModelTests.swift", [(4936, 4975)]),
     ]),
    ("home-refresh-rule",
     r"foregroundAfter|surfaceReturnAfter|applicationDidBecomeActive|func test", [
         (readme, [(21, 72)]),
         ("Sources/FeatureHomeCore/ContentRefresh/ContentRefreshModels.swift", [(105, 154)]),
         ("Sources/FeatureHomeCore/ContentRefresh/ContentRefreshLifecycleReader.swift", [(1, 200)]),
         ("Tests/FeatureHomeCoreTests/ContentRefreshCoordinatorTests.swift", [(1, 85)]),
         ("Tests/FeatureHomeTests/HomeViewModelStalenessRefreshTests.swift", [(20, 45)]),
     ]),
    ("continue-watching-action-setting",
     r"continueWatchingAction|ContinueWatchingActionControl|testArrangementPersists", [
         (readme, [(548, 575)]),
         ("Sources/FeatureSettings/HomeSectionSettingsViews.swift", [(307, 344)]),
         ("Sources/CoreModels/HomeLibraryVisibility.swift", [(121, 148), (425, 428), (476, 520)]),
         ("Sources/CoreModels/HomeLibraryVisibilityStore.swift", [(17, 44), (343, 353)]),
         ("Tests/CoreModelsTests/HomeRowCustomizationTests.swift", [(473, 500)]),
     ]),
]
for task, pattern, files in tasks:
    total = 0
    for path, ranges in files:
        raw = subprocess.check_output(["git", "show", f"{base}:{path}"])
        lines = raw.splitlines(keepends=True)
        total += sum(len(b"".join(lines[a - 1:b])) for a, b in ranges)
        found = subprocess.run(
            ["rg", "-n", "--no-heading", pattern],
            input=raw, capture_output=True,
        )
        if found.returncode not in (0, 1):
            raise RuntimeError(found.stderr.decode())
        total += sum(len(path.encode()) + 1 + len(line)
                     for line in found.stdout.splitlines(keepends=True))
    print(task, total)
```

## Next measurement

During the detail code pilot, record the actual search/read calls, files and
bytes exposed, investigation time, and model tokens when available. Start at
the new entry map; retain the exact task, source revision, and accounting rules.
Do not treat familiarity from this work as a cold-reader speedup. A credible
before/after token claim needs equivalent tasks, comparable starting context,
and consistent model/tool accounting. Until then, do not roll this documentation
pattern across every module on the strength of the entry-file size alone.

## Detail pilot follow-through

The first code pilot traced the existing opening, model, selection, routing,
and runtime boundaries described in the
[selection ownership map](detail-and-playback.md#selection-ownership).
It consolidated the repeated TV/mobile composition without introducing another
mutable owner. Across the two adapters and shared selector, the production diff
against `05d54e4d9` adds 97 lines and removes 205 (108 fewer lines in total).
That is a structural maintenance result, not a runtime benchmark.

The investigation was not a cold-reader replay: it reused knowledge from the
documentation work. Search/read calls, full investigation bytes, model tokens,
and end-to-end investigation time were not instrumented consistently enough for
a comparison to the fixed baseline. No before/after token or investigation-time
claim is supported. Preserve the baseline method for a future instrumented task
rather than treating smaller adapter files as proof of savings.
