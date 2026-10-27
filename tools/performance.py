#!/usr/bin/env python3
"""Device-free Plozz performance lab: list, run, profile, report, compare. No hardware installs."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = 1
SAMPLES = 5
FLAGS = [
    "SWIFT_OPTIMIZATION_LEVEL=-O", "GCC_OPTIMIZATION_LEVEL=s",
    "COMPILER_INDEX_STORE_ENABLE=NO", "DEBUG_INFORMATION_FORMAT=dwarf",
    "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO",
]
METRICS = ("wallMilliseconds", "cpuMilliseconds", "residentBytes", "residentDeltaBytes")
HOME_HOST_FITTING_COUNTERS = [
    "motionSizeThatFitsCalls", "rowHostFitCalls", "columnHostFitCalls", "maskSizeThatFitsCalls",
    "rowHostFittingNanoseconds", "columnHostFittingNanoseconds",
    "hostFittingMaxNanoseconds", "hostFittingReentrantCalls",
]
SCENARIOS = {
    "server-ratings-critical-path": {
        "suite": "network", "target": "ProviderJellyfinTests",
        "test": "ServerRatingsLatencyTests/testPerformanceRequiredItemAndPlayback",
        "file": "Tests/ProviderJellyfinTests/ServerRatingsLatencyTests.swift",
        "description": "Load four item details and playback inventories with a 150-ms optional server-rating cache endpoint.",
        "counters": ["items", "playbackItems", "nativeRequests", "playbackRequests", "cacheRequests"],
    },
    "mobile-video-glow-hd": {
        "suite": "ui", "platforms": ["iOS"],
        "test": "LiveTVPreviewPresentationTests/testPerformanceHDVideoGlow",
        "file": "Tests/iOSPresentationTests/LiveTVPreviewPresentationTests.swift",
        "description": "Play 1080p30 synthetic video with light preview color sampling; require advancing playback and bounded completed samples.",
        "counters": ["players", "visiblePreviews", "windowMilliseconds"],
    },
    "mobile-video-glow-hd-disabled": {
        "suite": "ui", "platforms": ["iOS"],
        "test": "LiveTVPreviewPresentationTests/testPerformanceHDVideoWithoutGlow",
        "file": "Tests/iOSPresentationTests/LiveTVPreviewPresentationTests.swift",
        "description": "Play the same 1080p30 fixture without glow as the sampling-cost control.",
        "counters": ["players", "visiblePreviews", "windowMilliseconds"],
    },
    "mobile-video-glow": {
        "suite": "ui", "platforms": ["iOS"],
        "test": "LiveTVPreviewPresentationTests/testPerformanceLightVideoPreview",
        "file": "Tests/iOSPresentationTests/LiveTVPreviewPresentationTests.swift",
        "description": "Play the native synthetic video in a visible light-mode preview with surrounding glow over 2.3-second windows; require advancing playback and one retained surface.",
        "counters": ["players", "visiblePreviews", "windowMilliseconds"],
    },
    "live-tv-schedule-capture": {
        "suite": "core", "target": "AppRuntimeTests",
        "test": "LiveTVPortableCapturePerformanceTests/testPerformanceDefinitionOnlyCaptures",
        "file": "Tests/AppRuntimeTests/LiveTVPortableCapturePerformanceTests.swift",
        "description": "Capture 12,000 immutable schedule inputs, advance the published guide five times, then capture changed inputs.",
        "counters": ["captures", "fullSnapshotEncodes", "initialItems", "changedItems", "initialEncodedBytes"],
    },
    "guide-large-batches": {
        "suite": "network", "target": "ProviderIPTVTests",
        "test": "IPTVPerformanceProbeTests/testPerformanceLargeGuideBatches",
        "file": "Tests/ProviderIPTVTests/IPTVPerformanceProbeTests.swift",
        "description": "Two 2,000-channel batches from one 6,000-channel, 48,000-programme XMLTV document above the small-body cache limit.",
        "counters": ["guideBytes", "httpRequests", "downloadedBytes", "parseInvocations",
                     "retainedRows", "requestedChannels"],
    },
    "live-tv-schedule-sync": {
        "suite": "core", "target": "FeatureLiveTVCoreTests",
        "test": "LibraryChannelSyncSizeTests/testPerformanceLibrarySyncPayload",
        "file": "Tests/FeatureLiveTVCoreTests/LibraryChannelSyncSizeTests.swift",
        "description": "Plan five distinct channels from 4,000 films, refresh metadata spelling, and serialize preserved broadcast revisions.",
        "counters": ["channels", "snapshots", "snapshotItemReferences", "encodedSnapshotBytes"],
    },
    "poster-preview-admission": {
        "suite": "core", "target": "CoreUITests",
        "test": "PosterPreviewAdmissionTests/testPerformanceOverlappingPosterWindows",
        "file": "Tests/CoreUITests/PosterPreviewAdmissionTests.swift",
        "description": "Traverse 181 posters forward/backward with repeated overlapping windows across Jellyfin, Emby, Plex, and TMDB URLs.",
        "counters": ["candidateVisits", "distinctURLChecks", "queuedPreviews"],
    },
    "collection-discovery": {
        "suite": "network", "target": "ProviderJellyfinTests",
        "test": "CollectionDiscoveryPerformanceTests/testPerformanceCollectionDiscovery",
        "file": "Tests/ProviderJellyfinTests/CollectionDiscoveryPerformanceTests.swift",
        "description": "Native listing of all 356 collections in one request, with 5-ms latency and no membership scans.",
        "counters": ["collections", "requests", "libraryRequests", "memberRequests", "firstItemsNanoseconds"],
    },
    "watchlist-artwork-rehydration": {
        "suite": "core", "target": "AppRuntimeTests",
        "test": "UniversalWatchlistMembershipTests/testPerformanceWatchlistArtworkRehydration",
        "file": "Tests/AppRuntimeTests/UniversalWatchlistMembershipTests.swift",
        "description": "Rehydrate 180 titles and 11,520 cast credits for each of Plex and Jellyfin through the live watchlist runtime.",
        "counters": ["items", "credits", "providers"],
    },
    "sync-unchanged": {
        "suite": "core", "target": "FeatureSyncCloudTests",
        "test": "CloudSyncPersistenceStateTests/testPerformanceUnchangedLedger",
        "file": "Tests/FeatureSyncCloudTests/CloudSyncPersistenceStateTests.swift",
        "description": "1,000 unchanged persistence checks over 10,000 records; then a real edit.",
        "counters": ["checks", "records", "persistenceCalls"],
    },
    "library-unchanged": {
        "suite": "core", "target": "ProviderShareTests",
        "test": "ShareScannerIncrementalTests/testPerformanceUnchangedLibrary",
        "file": "Tests/ProviderShareTests/ShareScannerIncrementalTests.swift",
        "description": "Warm incremental scan of 1,000 films; then verify a newly added file.",
        "counters": ["directoryListings", "assets", "inventoryUpdates"],
    },
    "catalog-import": {
        "suite": "core", "target": "ProviderIPTVTests",
        "test": "IPTVPerformanceProbeTests/testPerformanceCatalogImport",
        "file": "Tests/ProviderIPTVTests/IPTVPerformanceProbeTests.swift",
        "description": "Fresh local SQLite import of 10,000 generated records per sample.",
        "counters": ["records"],
    },
    "catalog-cached-refresh": {
        "suite": "network", "target": "ProviderIPTVTests",
        "test": "IPTVPerformanceProbeTests/testPerformanceCachedPlaylistRefresh",
        "file": "Tests/ProviderIPTVTests/IPTVPerformanceProbeTests.swift",
        "description": "1,000-channel loopback import, then held expired-catalog refresh; cached reads must not await replacement.",
        "counters": ["channels", "cachedReads", "replacementChannels", "httpRequests", "refreshRequests",
                     "coldForegroundNanoseconds", "cachedForegroundNanoseconds"],
    },
    "network-file-read-ahead": {
        "suite": "network", "target": "EnginePlozzigenTests",
        "test": "TransportReadAheadPerformanceTests/testPerformanceRandomAndSequentialReads",
        "file": "Tests/EnginePlozzigenTests/TransportReadAheadPerformanceTests.swift",
        "description": "Four sparse disc-metadata probes then 64 MiB sequential playback through the production reader; 5-ms synthetic request latency.",
        "counters": ["metadataReads", "consumedBytes", "transportReads", "transportBytes", "largestRequest"],
    },
    "disc-probe-cache": {
        "suite": "network", "target": "EnginePlozzigenTests",
        "test": "TransportReadAheadPerformanceTests/testPerformanceRepeatedDiscMetadataProbes",
        "file": "Tests/EnginePlozzigenTests/TransportReadAheadPerformanceTests.swift",
        "description": "Twenty-one scattered, overlapping disc metadata probes through the production reader; 5-ms synthetic request latency.",
        "counters": ["metadataReads", "transportReads", "transportBytes", "largestRequest"],
    },
    "http-response-assembly": {
        "suite": "network", "target": "MediaTransportHTTPTests",
        "test": "TransportResponsePerformanceTests/testPerformanceChunkedResponseAssembly",
        "file": "Tests/MediaTransportHTTPTests/TransportResponsePerformanceTests.swift",
        "description": "Assemble and verify a 32 MiB HTTP body delivered in 16 KiB callbacks through the production session delegate.",
        "counters": ["responseBytes", "callbacks"],
    },
    "webdav-playback-window": {
        "suite": "network", "target": "MediaTransportWebDAVTests",
        "test": "WebDAVMediaTransportTests/testPerformancePlaybackWindow",
        "file": "Tests/MediaTransportWebDAVTests/WebDAVMediaTransportTests.swift",
        "description": "Read and verify a 32 MiB production WebDAV window with synthetic per-connection delivery delay.",
        "counters": ["consumedBytes", "transportReads"],
    },
    "webdav-paced-playback": {
        "suite": "network", "target": "EnginePlozzigenTests",
        "test": "TransportReadAheadPerformanceTests/testPerformancePacedWebDAVPlayback",
        "file": "Tests/EnginePlozzigenTests/TransportReadAheadPerformanceTests.swift",
        "description": "Consume 128 MiB through the production WebDAV reader at 32 MiB/s with synthetic 100-ms request latency and bounded transfer delay.",
        "counters": ["consumedBytes", "requestedRangeBytes", "cachedProbes", "transportReads", "readerWaitNanoseconds"],
    },
    "webdav-cached-seeks": {
        "suite": "network", "target": "EnginePlozzigenTests",
        "test": "TransportReadAheadPerformanceTests/testPerformanceCachedWebDAVSeeks",
        "file": "Tests/EnginePlozzigenTests/TransportReadAheadPerformanceTests.swift",
        "description": "Paced 128 MiB WebDAV consumption with 31 cached back-and-forth probes; count cancelled/repeated range requests.",
        "counters": ["consumedBytes", "requestedRangeBytes", "cachedProbes", "transportReads", "readerWaitNanoseconds"],
    },
    "diagnostics-disabled": {
        "suite": "diagnostics", "target": "CoreModelsTests",
        "test": "PerformanceDiagnosticsProbeTests/testPerformanceDisabledOperations",
        "file": "Tests/CoreModelsTests/PerformanceDiagnosticsProbeTests.swift",
        "description": "10,000 begin/finish attempts with diagnostic consent disabled.",
        "counters": ["attempts", "accepted", "retained", "dropped"],
    },
    "diagnostics-enabled": {
        "suite": "diagnostics", "target": "CoreModelsTests",
        "test": "PerformanceDiagnosticsProbeTests/testPerformanceEnabledOperations",
        "file": "Tests/CoreModelsTests/PerformanceDiagnosticsProbeTests.swift",
        "description": "10,000 recorded operations with fixed in-memory retention; no Sentry upload.",
        "counters": ["attempts", "accepted", "retained", "dropped"],
    },
    "diagnostics-snapshot": {
        "suite": "diagnostics", "target": "CoreModelsTests",
        "test": "PerformanceDiagnosticsProbeTests/testPerformanceSnapshotSerialization",
        "file": "Tests/CoreModelsTests/PerformanceDiagnosticsProbeTests.swift",
        "description": "100 full bounded snapshots including serialization at event-capture boundaries.",
        "counters": ["snapshots", "records", "serializedBytes"],
    },
    "playback-journal-disabled": {
        "suite": "diagnostics", "target": "CoreModelsTests",
        "test": "PerformanceDiagnosticsProbeTests/testPerformancePlaybackJournalDisabled",
        "file": "Tests/CoreModelsTests/PerformanceDiagnosticsProbeTests.swift",
        "description": "10,000 lifecycle notifications without recording; control for journal overhead.",
        "counters": ["notifications", "retained", "discarded", "persistedBytes", "enqueueMicroseconds"],
    },
    "playback-journal-enabled": {
        "suite": "diagnostics", "target": "CoreModelsTests",
        "test": "PerformanceDiagnosticsProbeTests/testPerformancePlaybackJournalEnabled",
        "file": "Tests/CoreModelsTests/PerformanceDiagnosticsProbeTests.swift",
        "description": "The same notifications with bounded recording and completed encoding/persistence.",
        "counters": ["notifications", "retained", "discarded", "persistedBytes", "enqueueMicroseconds"],
    },
    "skeletons-idle": {
        "suite": "ui", "test": "ShimmerPerformanceTests/testPerformanceLoadingCards",
        "file": "Tests/PerformancePresentationSupport/ShimmerPerformanceTests.swift",
        "description": "Observe 24 production loading cards over complete 2.3-second shimmer cycles; verify visible motion outside the measurement.",
        "counters": ["placeholders", "observationMilliseconds"], "timing": ["cpuMilliseconds"],
    },
    "skeletons-static": {
        "suite": "ui", "test": "ShimmerPerformanceTests/testPerformanceStaticCards",
        "file": "Tests/PerformancePresentationSupport/ShimmerPerformanceTests.swift",
        "description": "The same 24 loading cards with implicit animations disabled; verify stable pixels before measuring idle CPU.",
        "counters": ["placeholders", "observationMilliseconds"], "timing": ["cpuMilliseconds"],
    },
    "cards-idle": {
        "suite": "ui", "test": "CardPerformanceTests/testPerformanceIdle",
        "file": "Tests/PerformancePresentationSupport/CardPerformanceTests.swift",
        "description": "Settled production media rows, 500 ms idle windows; not whole-app idle.",
        "counters": ["cardInputBuilds"], "timing": ["cpuMilliseconds"],
    },
    "cards-scroll": {
        "suite": "ui", "test": "CardPerformanceTests/testPerformanceScroll",
        "file": "Tests/PerformancePresentationSupport/CardPerformanceTests.swift",
        "description": "Programmatic traversal of mounted production media rows; not hardware frame pacing.",
        "counters": ["scrolls"],
    },
    "cards-lifecycle": {
        "suite": "ui", "test": "CardPerformanceTests/testPerformanceLifecycle",
        "file": "Tests/PerformancePresentationSupport/CardPerformanceTests.swift",
        "description": "Repeated mount/unmount; weak host and view checks must release.",
        "counters": ["cycles", "survivingHosts"],
    },
    "home-artwork-layout": {
        "suite": "ui", "platforms": ["tvOS"],
        "test": "HomeLayoutInvalidationPerformanceTests/testPerformanceArtworkPublicationLayout",
        "file": "Tests/FocusIntegrationTests/HomeLayoutInvalidationPerformanceTests.swift",
        "description": "Production Showcase artwork changes across eight populated rows; observe nested sizing and placement.",
        "counters": ["artworkPublications", "backgroundSamples", "paletteUpdates",
                     "rowContentSizeQueries", "rowContentPlacements", "cardInputBuilds",
                     "outerHostLayoutPasses"] + HOME_HOST_FITTING_COUNTERS,
    },
    "home-artwork-layout-duplicate": {
        "suite": "ui", "platforms": ["tvOS"],
        "test": "HomeLayoutInvalidationPerformanceTests/testPerformanceDuplicateArtworkPublicationLayout",
        "file": "Tests/FocusIntegrationTests/HomeLayoutInvalidationPerformanceTests.swift",
        "description": "Repeat the same Showcase artwork report; verify duplicate suppression and downstream layout work.",
        "counters": ["artworkPublications", "backgroundSamples", "paletteUpdates",
                     "rowContentSizeQueries", "rowContentPlacements", "cardInputBuilds",
                     "outerHostLayoutPasses"] + HOME_HOST_FITTING_COUNTERS,
    },
    "home-artwork-layout-cold": {
        "suite": "ui", "platforms": ["tvOS"],
        "test": "HomeLayoutInvalidationPerformanceTests/testPerformanceColdHomeArtworkLayout",
        "file": "Tests/FocusIntegrationTests/HomeLayoutInvalidationPerformanceTests.swift",
        "description": "New Home view graph with warm artwork; observe actual nested host fitting and automatic artwork publication.",
        "counters": ["realizedArtworkHosts", "rowContentSizeQueries", "rowContentPlacements",
                     "cardInputBuilds", "outerHostLayoutPasses"] + HOME_HOST_FITTING_COUNTERS,
    },
    "home-metadata-publication": {
        "suite": "ui", "test": "HomeMetadataPerformanceTests/testPerformanceHomeMetadataPublication",
        "file": "Tests/PerformancePresentationSupport/HomeMetadataPerformanceTests.swift",
        "description": "Silent Home reloads with independently decoded equal media metadata; observe publication and persistence.",
        "counters": ["refreshes", "providerRequests", "snapshotSaves", "contentPublications",
                     "stateNotifications", "continueWatchingItems", "metadataPeople",
                     "mainActorSchedulingSamples", "mainActorMaxSchedulingDelayMicroseconds"],
    },
    "home-observed-metadata-publication": {
        "suite": "ui", "test": "HomeMetadataPerformanceTests/testPerformanceObservedHomeMetadataPublication",
        "file": "Tests/PerformancePresentationSupport/HomeMetadataPerformanceTests.swift",
        "description": "Changed Home metadata published to an observing production media row; verify completed visible updates.",
        "counters": ["refreshes", "providerRequests", "snapshotSaves", "contentPublications",
                     "stateNotifications", "continueWatchingItems", "metadataPeople",
                     "mainActorSchedulingSamples", "mainActorMaxSchedulingDelayMicroseconds",
                     "observedRowUpdates", "parentBodies", "cardInputBuilds"],
    },
    "home-observed-metadata-diagnostics": {
        "suite": "ui", "test": "HomeMetadataPerformanceTests/testPerformanceObservedHomeMetadataWithDiagnostics",
        "file": "Tests/PerformancePresentationSupport/HomeMetadataPerformanceTests.swift",
        "description": "The same observed Home publication workload with bounded diagnostics enabled; no Sentry upload.",
        "counters": ["refreshes", "providerRequests", "snapshotSaves", "contentPublications",
                     "stateNotifications", "continueWatchingItems", "metadataPeople",
                     "mainActorSchedulingSamples", "mainActorMaxSchedulingDelayMicroseconds",
                     "observedRowUpdates", "parentBodies", "cardInputBuilds"],
    },
    "home-row-metadata-updates": {
        "suite": "ui", "test": "HomeMetadataPerformanceTests/testPerformanceProductionRowMetadataUpdates",
        "file": "Tests/PerformancePresentationSupport/HomeMetadataPerformanceTests.swift",
        "description": "Production media-row updates alternating independently decoded equal snapshots.",
        "counters": ["rootUpdates", "parentBodies", "cardInputBuilds", "rowItems", "metadataPeople"],
    },
    "home-row-metadata-reuse": {
        "suite": "ui", "test": "HomeMetadataPerformanceTests/testPerformanceProductionRowMetadataReuse",
        "file": "Tests/PerformancePresentationSupport/HomeMetadataPerformanceTests.swift",
        "description": "Production media-row updates reusing existing media values with complete metadata.",
        "counters": ["rootUpdates", "parentBodies", "cardInputBuilds", "rowItems", "metadataPeople"],
    },
    "mobile-home-card-routing": {
        "suite": "ui", "platforms": ["iOS"],
        "test": "HomeCardRoutingTests/testPerformanceHomeCardUpdates",
        "file": "Tests/iOSPresentationTests/HomeCardRoutingTests.swift",
        "description": "Update 24 production mobile Home cards against a four-source identity index without activating a card.",
        "counters": ["rootUpdates", "cards", "sourceResolutions", "observedRevision"],
    },
    "mobile-home-rail-prefetch": {
        "suite": "ui", "platforms": ["iOS"],
        "test": "HomeRailPrefetchPerformanceTests/testPerformanceRepeatedRailUpdates",
        "file": "Tests/iOSPresentationTests/HomeRailPrefetchPerformanceTests.swift",
        "description": "Update a production mobile Continue Watching rail 24 times with 180 episodes across twelve synthetic source identities and cached artwork.",
        "counters": ["rootUpdates", "items", "accounts", "seriesSourceBuilds"],
    },
    "mobile-preference-sync": {
        "suite": "ui",
        "platforms": ["iOS"],
        "test": "CloudConfigurationRefreshTests/testPerformancePreferenceSync",
        "file": "Tests/iOSPresentationTests/CloudConfigurationRefreshTests.swift",
        "description": "Apply 24 active/inactive preference batches through the mobile app model; count synchronous account, index and download invalidations.",
        "counters": ["batches", "appliedPreferences", "accountInvalidations", "indexResets", "downloadTransitions"],
    },
    "mobile-profile-selection": {
        "suite": "ui", "platforms": ["iOS"],
        "test": "ProfileSelectionPerformanceTests/testPerformanceProfileSelection",
        "file": "Tests/iOSPresentationTests/ProfileSelectionPerformanceTests.swift",
        "description": "Activate sixteen profiles through the mobile app model and verify current Plex PIN gating; measure synchronous selection separately from 5-ms fixture metadata.",
        "counters": ["selections", "selectionMicroseconds", "maxSelectionMicroseconds"],
    },
    "mobile-profile-pin-handoff": {
        "suite": "ui", "platforms": ["iOS"],
        "test": "ProfileSelectionPerformanceTests/testPerformanceLocalPINHandoff",
        "file": "Tests/iOSPresentationTests/ProfileSelectionPerformanceTests.swift",
        "description": "Unlock a local profile in a sixteen-profile household using the production verifier cost; measure verification duration and main-actor heartbeat gaps.",
        "counters": ["profiles", "verifierIterations", "verificationMicroseconds", "maxMainActorGapMicroseconds"],
    },
    "source-menu-version-presentation": {
        "suite": "ui",
        "test": "PlaybackSourceMenuPerformanceTests/testPerformanceVersionPresentation",
        "file": "Tests/PerformancePresentationSupport/PlaybackSourceMenuPerformanceTests.swift",
        "description": "Build actual source-menu version presentations, preserving every displayed title and supplemental fact.",
        "counters": ["versions", "menuUpdates", "presentedRows"],
    },
    "native-poster-composition": {
        "suite": "ui", "platforms": ["tvOS"],
        "test": "NativePosterCompositionTests/testPerformanceNativePosterComposition",
        "file": "Tests/FocusIntegrationTests/NativePosterCompositionTests.swift",
        "description": "Complete twelve native Home poster conversions, separating request latency from finished bitmap work.",
        "counters": ["completedPosters", "compositions", "mainThreadCompositions", "requestMicroseconds"],
    },
    "native-poster-indicators": {
        "suite": "ui", "platforms": ["tvOS"],
        "test": "NativePosterCompositionTests/testPerformanceNativePosterIndicatorReuse",
        "file": "Tests/FocusIntegrationTests/NativePosterCompositionTests.swift",
        "description": "Render 72 native poster foregrounds with three visible badges and changing playback progress.",
        "counters": ["completedOverlays", "distinctBitmaps"],
    },
    "portrait-reflection-cold": {
        "suite": "ui", "platforms": ["tvOS"],
        "test": "NativePosterCompositionTests/testPerformancePortraitReflectionPreparation",
        "file": "Tests/FocusIntegrationTests/NativePosterCompositionTests.swift",
        "description": "Prepare twelve Detailed portrait reflections through the native coordinator with cold geometry.",
        "counters": ["completedPosters", "maxPreparationMicroseconds"],
    },
    "portrait-reflection-warm": {
        "suite": "ui", "platforms": ["tvOS"],
        "test": "NativePosterCompositionTests/testPerformancePortraitReflectionReuse",
        "file": "Tests/FocusIntegrationTests/NativePosterCompositionTests.swift",
        "description": "Recreate 288 native portrait coordinators and require reuse of their twelve prepared reflection bitmaps.",
        "counters": ["requests", "reusedBitmaps"],
    },
    "runtime-matrix": {
        "suite": "matrix", "target": "AppRuntimeTests",
        "test": "LiveTVAutomaticChannelsRuntimeTests/testPerformanceConfigurationMatrix",
        "file": "Tests/AppRuntimeTests/LiveTVAutomaticChannelsRuntimeTests.swift",
        "description": "16 combinations: 1/4 providers x Plozz Channels x Live TV data x local cloud-sync processing.",
        "counters": ["providers", "automaticChannels", "liveTV", "cloudSync", "refreshes",
                     "providerRequests", "portableRecords", "persistenceCalls"],
        "reports": [f"runtime-p{p}-c{c}-l{l}-s{s}"
                    for p in (1, 4) for c in (0, 1) for l in (0, 1) for s in (0, 1)],
    },
}


class Failure(RuntimeError):
    pass


def load_module(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def select(suite, names, platform=None):
    if names:
        if suite:
            raise Failure("Choose --suite or --scenario, not both.")
        if len(names) != len(set(names)) or not set(names) <= SCENARIOS.keys():
            raise Failure("Unknown or duplicate scenario. Run 'list' for supported names.")
        unsupported = [name for name in names
                       if platform and platform not in SCENARIOS[name].get("platforms", ("tvOS", "iOS"))]
        if unsupported:
            raise Failure(f"Scenarios not supported on {platform}: {', '.join(sorted(unsupported))}.")
        return sorted(names)
    return [name for name, spec in SCENARIOS.items()
            if (suite == "all" or spec["suite"] == (suite or "core"))
            and (not platform or platform in spec.get("platforms", ("tvOS", "iOS")))]


def expected_reports(names):
    return {report: spec for name in names for spec in [SCENARIOS[name]]
            for report in spec.get("reports", [name])}


def validate_report(report, spec):
    if (type(report.get("schema")) is not int or report["schema"] != SCHEMA
            or type(report.get("warmups")) is not int or report["warmups"] != 1):
        raise Failure("Invalid performance report schema/warmup count.")
    samples = report.get("samples")
    if not isinstance(samples, list) or len(samples) != SAMPLES:
        raise Failure(f"Expected exactly {SAMPLES} measured samples.")
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict) or type(sample.get("iteration")) is not int or sample["iteration"] != index:
            raise Failure("Missing, duplicated or unordered measurement.")
        for key in METRICS:
            value = sample.get(key)
            if type(value) not in (int, float) or not math.isfinite(value):
                raise Failure(f"Missing/non-finite measurement: {key}.")
            if key != "residentDeltaBytes" and value < 0:
                raise Failure(f"Negative measurement: {key}.")
        counters = sample.get("counters")
        if not isinstance(counters, dict) or set(counters) != set(spec["counters"]):
            raise Failure("Missing or unexpected workload counters.")
        if any(type(value) is not int or value < 0 for value in counters.values()):
            raise Failure("Workload counters must be non-negative integers.")


def read_attachments(folder, expected):
    reports = {}
    for test in json.loads((folder / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            name = attachment.get("suggestedHumanReadableName", "")
            if not name.startswith("plozz-performance-"):
                continue
            path = (folder / attachment["exportedFileName"]).resolve()
            if path.parent != folder.resolve():
                raise Failure("Attachment path escaped the run directory.")
            report = json.loads(path.read_text())
            scenario = report.get("scenario")
            if scenario not in expected or scenario in reports:
                raise Failure("Unexpected or duplicate scenario attachment.")
            validate_report(report, expected[scenario])
            reports[scenario] = report
    if set(reports) != set(expected):
        raise Failure(f"Incomplete performance evidence: expected {sorted(expected)}, got {sorted(reports)}.")
    return reports


def verify_summary(summary, count):
    fields = ("passedTests", "totalTestCount", "failedTests", "skippedTests", "expectedFailures")
    if not (all(type(summary.get(key)) is int for key in fields)
            and summary.get("result") == "Passed" and summary.get("passedTests") == count
            and summary.get("totalTestCount") == count
            and all(summary.get(key) == 0 for key in ("failedTests", "skippedTests", "expectedFailures"))
            and summary.get("testFailures") == []):
        raise Failure("XCTest did not pass exactly the selected tests, without skips or retries.")


def configure_scheme(tree):
    action = tree.getroot().find("TestAction")
    if action is None:
        raise Failure("Generated scheme has no TestAction.")
    action.set("buildConfiguration", "Debug")
    action.set("shouldUseLaunchSchemeArgsEnv", "NO")
    action.set("selectedDebuggerIdentifier", "")
    action.set("selectedLauncherIdentifier", "Xcode.IDEFoundation.Launcher.PosixSpawn")
    action.set("codeCoverageEnabled", "NO")
    old = action.find("EnvironmentVariables")
    if old is not None:
        action.remove(old)
    variables = ET.SubElement(action, "EnvironmentVariables")
    ET.SubElement(variables, "EnvironmentVariable", key="PLOZZ_PERFORMANCE", value="1", isEnabled="YES")
    return tree


def package_scheme(targets):
    root = ET.Element("Scheme", version="1.7")
    entries = ET.SubElement(ET.SubElement(root, "BuildAction", buildImplicitDependencies="YES"), "BuildActionEntries")
    tests = ET.SubElement(ET.SubElement(root, "TestAction"), "Testables")
    for target in sorted(targets):
        build = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="NO",
                              buildForProfiling="NO", buildForArchiving="NO", buildForAnalyzing="NO")
        test = ET.SubElement(tests, "TestableReference", skipped="NO")
        for parent in (build, test):
            ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary",
                          BlueprintIdentifier=target, BuildableName=target, BlueprintName=target,
                          ReferencedContainer="container:")
    return configure_scheme(ET.ElementTree(root))


def simulator_info(data, runtime_data, sim_id, platform):
    matches = [(runtime, device) for runtime, devices in data["devices"].items()
               for device in devices if device["udid"] == sim_id]
    if len(matches) != 1:
        raise Failure("The explicit UUID is not a local simulator; physical targets are prohibited.")
    runtime, device = matches[0]
    if not device.get("isAvailable") or not runtime.startswith(f"com.apple.CoreSimulator.SimRuntime.{platform}-"):
        raise Failure("Simulator is unavailable or does not match --platform.")
    runtimes = [row for row in runtime_data["runtimes"] if row["identifier"] == runtime]
    if len(runtimes) != 1 or not runtimes[0].get("buildversion") or not device.get("deviceTypeIdentifier"):
        raise Failure("Simulator runtime build/device type cannot be verified.")
    return {
        "runtime": runtime, "runtimeBuild": runtimes[0]["buildversion"],
        "deviceType": device["deviceTypeIdentifier"],
    }, device["state"]


def stop_owned(process):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def stack_sample_summary(path, pid):
    text = path.read_text()
    if not re.search(rf"^Process:\s+FocusHost \[{pid}\]$", text, re.MULTILINE):
        raise Failure("Stack sample belongs to a different process.")
    images_available = "\nBinary Images:" in text
    if "Call graph:\n" not in text or not (
        images_available or text.rstrip().endswith("Binary images description not available")
    ):
        raise Failure("Stack sample did not finalize.")
    thread = None
    frames = []
    background = []
    for line in text.split("Call graph:\n", 1)[1].splitlines():
        if line.startswith(("Total number in stack", "Sort by top of stack", "Binary Images:")):
            break
        header = re.match(r"^\s*\d+\s+(Thread_\S+.*)$", line)
        if header:
            thread = header[1]
            continue
        match = re.match(r"^[\s+!:|]*(\d+)\s+(.+)$", line)
        if thread and match:
            row = {"stackSamples": int(match[1]), "frame": match[2]}
            if "Main Thread" in thread or "com.apple.main-thread" in thread:
                frames.append(row)
            elif "(in FocusHost)" in row["frame"]:
                background.append(dict(row, thread=thread))
    if not frames:
        raise Failure("Stack sample has no main-thread frames.")
    return {
        "binaryImagesAvailable": images_available,
        "mainThreadFrames": sorted(frames, key=lambda row: row["stackSamples"], reverse=True)[:40],
        "appFrames": sorted((row for row in frames if "(in FocusHost)" in row["frame"]),
                            key=lambda row: row["stackSamples"], reverse=True)[:40],
        "backgroundAppFrames": sorted(background, key=lambda row: row["stackSamples"], reverse=True)[:40],
        "note": "Top 40 frames per list. Inclusive thread-stack samples include waiting; they are not CPU time or frame-latency measurements.",
    }


class Lane:
    def __init__(self, root, args, fds):
        self.root, self.args, self.fds = root, args, fds
        self.output = root / ".build/performance/runs" / uuid.uuid4().hex
        self.output.mkdir(parents=True, mode=0o700)
        self.deadline = time.monotonic() + args.timeout
        self.env = dict(os.environ, GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'", PYTHONDONTWRITEBYTECODE="1")
        self.booted = False
        self.record = {"schema": SCHEMA, "status": "failed", "evidenceKind": "simulator",
                       "scenarios": args.names, "simulatorID": args.sim_id, "reports": {}}
        self.sequence = 0
        print(f"Performance evidence: {self.output}", flush=True)

    def command(self, label, argv, timeout=120, check=True, cleanup=False):
        budget = timeout if cleanup else min(timeout, self.deadline - time.monotonic())
        if budget <= 0:
            raise Failure("Whole-run deadline reached; no automatic retry or cleanup of build outputs.")
        self.sequence += 1
        stem = f"{self.sequence:02}-{label}"
        print(f"  {label}", flush=True)
        write_json(self.output / f"{stem}.command.json", argv)
        with (self.output / f"{stem}.log").open("xb") as out, (self.output / f"{stem}.err").open("xb") as err:
            process = subprocess.Popen(argv, cwd=self.root, env=self.env, stdout=out, stderr=err,
                                       pass_fds=self.fds, start_new_session=True)
            try:
                status = process.wait(timeout=budget)
            except BaseException:
                stop_owned(process)
                raise
        text = (self.output / f"{stem}.log").read_text()
        if check and status:
            raise Failure(f"{label} failed ({status}); inspect {stem}.log and .err.")
        return status, text

    def fingerprint(self, label):
        _, tracked = self.command(label + "-files", ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        hashes = {}
        for name in sorted(set(filter(None, tracked.split("\0")))):
            path = self.root / name
            if name.startswith(("Sources/", "Tests/", "tools/", "Config/", "App/", "Vendor/")) or name in ("Package.swift", "Package.resolved", "project.yml"):
                hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "deleted"
        return hashes

    def run_group(self, names, package_args, hosted):
        project = self.root / "Plozz.xcodeproj"
        saved = self.output / "Plozz.xcodeproj"
        target = "PlozzFocusTests" if self.args.platform == "tvOS" else "PlozziOSPresentationTests"
        scheme_name = "_PlozzPerformance_" + self.output.name + ("_ui" if hosted else "_core")
        if hosted:
            source = project / "xcshareddata/xcschemes" / f"{target}.xcscheme"
            tree = configure_scheme(ET.parse(source))
            scheme = source.with_name(scheme_name + ".xcscheme")
        else:
            targets = {SCENARIOS[name]["target"] for name in names}
            tree = package_scheme(targets)
            scheme = self.root / ".swiftpm/xcode/xcshareddata/xcschemes" / f"{scheme_name}.xcscheme"
        folder = self.output / ("ui" if hosted else "core")
        folder.mkdir()
        try:
            scheme.parent.mkdir(parents=True, exist_ok=True)
            with scheme.open("xb") as stream:
                tree.write(stream, encoding="utf-8", xml_declaration=True)
            if not hosted and project.exists():
                if project.is_symlink():
                    raise Failure("Refusing to move a symlinked project.")
                project.rename(saved)
            selectors = [f"-only-testing:{target if hosted else SCENARIOS[name]['target']}/{SCENARIOS[name]['test']}" for name in names]
            command = [
                "xcodebuild", *(["-project", str(project)] if hosted else []), "-scheme", scheme_name,
                "-configuration", "Debug", "-destination", f"platform={self.args.platform} Simulator,id={self.args.sim_id}",
                "-parallel-testing-enabled", "NO", "-enableCodeCoverage", "NO",
                "-enableAddressSanitizer", "NO", "-enableThreadSanitizer", "NO",
                "-enableUndefinedBehaviorSanitizer", "NO",
                "-derivedDataPath", str(self.root / ".build/performance-derived-data" / self.args.platform / folder.name),
                *package_args, *selectors, *FLAGS,
            ]
            self.command(folder.name + "-build", [*command, "build-for-testing", "-resultBundlePath", str(folder / "Build.xcresult")], self.args.timeout)
            status, _ = self.command(folder.name + "-test", [
                *command, "test-without-building", "-collect-test-diagnostics", "never",
                "-resultBundlePath", str(folder / "Test.xcresult"),
            ], self.args.timeout, check=False)
            _, raw = self.command(folder.name + "-summary", [
                "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(folder / "Test.xcresult"),
            ])
            summary = json.loads(raw)
            write_json(folder / "summary.json", summary)
            verify_summary(summary, len(names))
            if status:
                raise Failure("A passing summary cannot override xcodebuild's failed exit.")
            self.command(folder.name + "-attachments", [
                "xcrun", "xcresulttool", "export", "attachments", "--path", str(folder / "Test.xcresult"),
                "--output-path", str(folder / "attachments"),
            ])
            return read_attachments(folder / "attachments", expected_reports(names))
        finally:
            signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
            handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in signals}
            try:
                try:
                    if scheme.exists():
                        scheme.rename(folder / scheme.name)
                finally:
                    if saved.exists():
                        if os.path.lexists(project):
                            raise Failure(f"Project restoration conflict; original retained at {saved}.")
                        saved.rename(project)
            finally:
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)

    def execute(self):
        try:
            self.command("architecture", [sys.executable, "tools/arch-guard.py"], timeout=300)
            self.command("test-hygiene", [sys.executable, "tools/test-hygiene.py"], timeout=300)
            _, devices = self.command("simulators", ["xcrun", "simctl", "list", "devices", "-j"])
            _, runtimes = self.command("runtimes", ["xcrun", "simctl", "list", "runtimes", "-j"])
            simulator, state = simulator_info(json.loads(devices), json.loads(runtimes), self.args.sim_id, self.args.platform)
            if state not in ("Booted", "Shutdown"):
                raise Failure("Simulator must be stably Booted or Shutdown.")
            profiling = getattr(self.args, "operation", "run") == "profile"
            if profiling and state != "Shutdown":
                raise Failure("Navigation profiling requires a shutdown owned simulator, not an existing app session.")
            self.booted = state == "Shutdown"
            self.command("simulator-start", ["xcrun", "simctl", "bootstatus", self.args.sim_id, "-b"], 300)
            self.command("generate-project", ["tools/generate-project.sh"])
            _, options = self.command("package-options", [
                "/bin/bash", "-ec", 'source tools/lib/swift-package-storage.sh; configure_plozz_package_resolution "$1"; '
                'printf "%s\\0" "${PACKAGE_RESOLUTION_ARGS[@]}"', "performance",
                str(self.root / ".build/package-workspaces/performance"),
            ])
            package_args = options.rstrip("\0").split("\0")
            if not package_args or package_args[0] != "-clonedSourcePackagesDirPath":
                raise Failure("Invalid package workspace arguments.")
            _, head = self.command("source-head", ["git", "rev-parse", "HEAD"])
            sources = self.fingerprint("before")
            fixture_paths = {name for name in sources if name.startswith("Tests/")}
            fixtures = {name: sources[name] for name in sorted(fixture_paths)}
            environment = dict(simulator, platform=self.args.platform, architecture=os.uname().machine,
                               flags=FLAGS, runnerHash=sources["tools/performance.py"])
            for key, command in {
                "xcode": ["xcodebuild", "-version"],
                "sdk": ["xcrun", "--sdk", "appletvsimulator" if self.args.platform == "tvOS" else "iphonesimulator", "--show-sdk-version"],
                "macOS": ["sw_vers", "-productVersion"],
                "hardware": ["sysctl", "-n", "hw.model", "hw.memsize", "hw.logicalcpu"],
            }.items():
                _, value = self.command(key, command)
                environment[key] = value.strip()
            self.record.update(environment=environment, source={"head": head.strip(), "files": sources},
                               fixtures=fixtures, startedAt=time.time(), hostLoadStart=list(os.getloadavg()))
            if profiling:
                self.record["evidenceKind"] = "simulator-navigation-profile"
            write_json(self.output / "result.json", self.record)
            if profiling:
                self.record["navigation"] = self.profile_navigation(package_args)
            else:
                for hosted in (False, True):
                    names = [name for name in self.args.names if (SCENARIOS[name]["suite"] == "ui") == hosted]
                    if names:
                        self.record["reports"].update(self.run_group(names, package_args, hosted))
            if sources != self.fingerprint("after"):
                raise Failure("Source changed during measurement; mixed-source evidence is invalid.")
            self.record["status"] = "passed"
        except (Failure, OSError, ValueError, subprocess.TimeoutExpired, ET.ParseError) as error:
            self.record["error"] = str(error)
            raise
        finally:
            try:
                if self.booted:
                    self.command("simulator-shutdown", ["xcrun", "simctl", "shutdown", self.args.sim_id], 60, cleanup=True)
            except (Failure, OSError, subprocess.TimeoutExpired) as error:
                self.record.update(status="failed", error=f"Owned simulator cleanup failed: {error}")
                raise
            finally:
                self.record.update(finishedAt=time.time(), hostLoadEnd=list(os.getloadavg()))
                write_json(self.output / "result.json", self.record)
        if getattr(self.args, "operation", "run") == "profile":
            print("Navigation profile captured; inspect result.json and retained trace.", flush=True)
        else:
            print(f"Measured {len(self.record['reports'])} scenarios. Compare result.json with a separate baseline.", flush=True)

    def profile_navigation(self, package_args):
        folder = self.output / "navigation"
        folder.mkdir()
        project = self.root / "Plozz.xcodeproj"
        source = project / "xcshareddata/xcschemes/PlozzHomeFixtureTests.xcscheme"
        name = "_PlozzNavigation_" + self.output.name
        scheme = source.with_name(name + ".xcscheme")
        tree = configure_scheme(ET.parse(source))
        ET.SubElement(tree.getroot().find("TestAction/EnvironmentVariables"), "EnvironmentVariable",
                      key="PLOZZ_PERFORMANCE_ATTACH", value="1", isEnabled="YES")
        derived = self.root / ".build/performance-derived-data/tvOS/ui"
        bundle_id = "com.thatcube.Plozz.FocusHost"
        workload = getattr(self.args, "workload", "home-navigation")
        test = (
            "DetailReturnFocusRemoteTests/testProfilePopulatedShowcaseDetailReturns"
            if workload == "detail-return"
            else "ProductionHomeNavigationTests/testNavigateProductionHomeWithNativeCards"
        )
        command = [
            "xcodebuild", "-project", str(project), "-scheme", name, "-configuration", "Debug",
            "-destination", f"platform=tvOS Simulator,id={self.args.sim_id}",
            "-derivedDataPath", str(derived), *package_args, *FLAGS,
            "-parallel-testing-enabled", "NO", "-enableCodeCoverage", "NO",
            "-enableAddressSanitizer", "NO", "-enableThreadSanitizer", "NO",
            "-enableUndefinedBehaviorSanitizer", "NO",
            "-only-testing:PlozzHomeRemoteTests/" + test,
        ]
        owned = []
        handles = []
        launched = False
        def start(label, argv):
            if time.monotonic() >= self.deadline:
                raise Failure("Whole-run deadline reached before starting profiler.")
            write_json(folder / f"{label}.command.json", argv)
            handle = (folder / f"{label}.log").open("xb")
            handles.append(handle)
            process = subprocess.Popen(argv, cwd=self.root, env=self.env, stdout=handle, stderr=subprocess.STDOUT,
                                       pass_fds=self.fds, start_new_session=True)
            owned.append(process)
            return process
        try:
            with scheme.open("xb") as stream:
                tree.write(stream, encoding="utf-8", xml_declaration=True)
            self.command("navigation-build", [*command, "build-for-testing",
                         "-resultBundlePath", str(folder / "Build.xcresult")], self.args.timeout)
            app = derived / "Build/Products/Debug-appletvsimulator/PlozzFocusHost.app"
            info = plistlib.loads((app / "Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") != bundle_id or info.get("CFBundleExecutable") != "FocusHost":
                raise Failure("Unexpected navigation fixture identity; refusing to install.")
            self.command("fixture-install", ["xcrun", "simctl", "install", self.args.sim_id, str(app)], 120)
            arguments = ["--production-home-fixture", "--home-performance-fixture", "--distinct-home-artwork",
                         "--home-artwork-cache-namespace=" + self.output.name]
            if workload == "detail-return":
                arguments = [
                    "--production-home-fixture", "--native-top-home", "--return-focus-trace",
                    "--immersive-home", "--progressive-library-rows", "--populated-home-return",
                    "--distinct-home-artwork", "--home-artwork-cache-namespace=" + self.output.name,
                ]
            _, launch = self.command("fixture-launch", ["xcrun", "simctl", "launch", self.args.sim_id, bundle_id, *arguments])
            launched = True
            match = re.fullmatch(re.escape(bundle_id) + r": (\d+)\s*", launch)
            if not match:
                raise Failure("Simulator did not return a unique fixture PID.")
            pid = int(match[1])
            _, container = self.command("fixture-container", ["xcrun", "simctl", "get_app_container",
                                       self.args.sim_id, bundle_id, "app"])
            _, executable = self.command("fixture-process", ["ps", "-p", str(pid), "-o", "comm="])
            if Path(executable.strip()).resolve() != (Path(container.strip()) / "FocusHost").resolve():
                raise Failure("Profiler PID does not belong to the installed fixture.")
            trace = folder / "Navigation.trace"
            sample_path = folder / "thread-stacks.txt"
            if self.args.template == "Process Sample":
                recorder = start("recorder", ["sample", str(pid), "180", "1", "-file", str(sample_path)])
                readiness_deadline = min(self.deadline, time.monotonic() + 20)
                while recorder.poll() is None and "Sampling process" not in (folder / "recorder.log").read_text():
                    if time.monotonic() >= readiness_deadline:
                        raise Failure("Process sampler did not start; navigation input was not sent.")
                    time.sleep(0.1)
                if recorder.poll() is not None:
                    raise Failure("Process sampler exited before navigation.")
            else:
                ready = "com.thatcube.Plozz.Performance." + self.output.name
                listener = start("trace-ready", ["notifyutil", "-1", ready])
                time.sleep(0.2)
                recorder = start("recorder", [
                    "xcrun", "xctrace", "record", "--device", self.args.sim_id,
                    "--template", self.args.template, "--attach", str(pid), "--time-limit", "180s",
                    "--notify-tracing-started", ready, "--output", str(trace),
                ])
                readiness_deadline = min(self.deadline, time.monotonic() + 60)
                while listener.poll() is None and recorder.poll() is None and time.monotonic() < readiness_deadline:
                    time.sleep(0.1)
                if listener.returncode or recorder.poll() is not None or ready not in (folder / "trace-ready.log").read_text():
                    raise Failure("Instruments was not ready; navigation input was not sent.")
            self.command("navigation-test", [*command, "test-without-building", "-collect-test-diagnostics", "never",
                         "-resultBundlePath", str(folder / "Test.xcresult")], 150)
            if recorder.poll() is not None:
                raise Failure("Recording ended before navigation completed.")
            recorder.send_signal(signal.SIGINT)
            recorder.wait(timeout=min(180, max(1, self.deadline - time.monotonic())))
            if recorder.returncode:
                raise Failure("Navigation recording did not finalize successfully.")
            _, summary = self.command("navigation-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary",
                                      "--path", str(folder / "Test.xcresult")])
            verify_summary(json.loads(summary), 1)
            _, current = self.command("fixture-final-process", ["ps", "-p", str(pid), "-o", "comm="])
            if current != executable:
                raise Failure("Navigation did not preserve the profiled app process.")
            _, data_container = self.command("fixture-data-container", [
                "xcrun", "simctl", "get_app_container", self.args.sim_id, bundle_id, "data",
            ])
            journal = Path(data_container.strip()) / "Library/Caches/Plozz/playback-trace.log"
            if workload == "detail-return" and not journal.is_file():
                raise Failure("Detail-return profiling is missing its native focus journal.")
            if journal.is_file():
                shutil.copy2(journal, folder / "handoff-journal.log")
            if self.args.template == "Process Sample":
                return {
                    "pid": pid, "bundleID": bundle_id, "arguments": arguments, "template": self.args.template,
                    "workload": workload,
                    "stacks": stack_sample_summary(sample_path, pid), "sample": str(sample_path),
                    "note": "Sampled simulator navigation, not device frame pacing or a full multi-provider app session.",
                }
            toc = folder / "toc.xml"
            self.command("trace-toc", ["xcrun", "xctrace", "export", "--input", str(trace), "--toc", "--output", str(toc)], 120)
            root = ET.parse(toc).getroot()
            schema = next((s for s in ("time-profile", "time-sample") if root.find(f'.//table[@schema="{s}"]') is not None), None)
            if schema is None:
                raise Failure("The trace has no exportable CPU samples.")
            samples = folder / "cpu-samples.xml"
            self.command("trace-samples", ["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
                         f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]', "--output", str(samples)], 180)
            trace_tools = load_module(self.root / "tools/trace-device.py")
            if trace_tools.failed_recording((folder / "recorder.log").read_text()):
                raise Failure("Instruments reported incomplete recording; raw evidence retained.")
            return {
                "pid": pid, "bundleID": bundle_id, "arguments": arguments, "template": self.args.template,
                "workload": workload,
                "cpu": trace_tools.sample_summary(samples, pid), "trace": str(trace),
                "note": "Instrumented simulator navigation, not device frame pacing or a full multi-provider app session.",
            }
        finally:
            try:
                for process in reversed(owned):
                    if process.poll() is None:
                        stop_owned(process)
            finally:
                for handle in handles:
                    handle.close()
                try:
                    if launched:
                        self.command("fixture-terminate", ["xcrun", "simctl", "terminate", self.args.sim_id, bundle_id],
                                     30, cleanup=True)
                finally:
                    if scheme.exists():
                        scheme.rename(folder / scheme.name)


def read_run(path):
    path = path / "result.json" if path.is_dir() else path
    data = json.loads(path.read_text())
    if data.get("schema") != SCHEMA or data.get("status") != "passed" or data.get("evidenceKind") != "simulator":
        raise Failure("Comparison requires complete passing simulator runs.")
    if not isinstance(data.get("scenarios"), list) or not data["scenarios"]:
        raise Failure("Missing scenario selection.")
    names = select(None, data["scenarios"])
    expected = expected_reports(names)
    if set(data["reports"]) != set(expected):
        raise Failure("Run is missing scenario evidence.")
    for name, report in data["reports"].items():
        if report.get("scenario") != name:
            raise Failure("Mismatched report identity.")
        validate_report(report, expected[name])
    for key in ("environment", "fixtures", "source"):
        if not isinstance(data.get(key), dict) or not data[key]:
            raise Failure(f"Missing run provenance: {key}.")
    for key in ("runtime", "runtimeBuild", "deviceType", "platform", "architecture",
                "runnerHash", "xcode", "sdk", "macOS", "hardware"):
        if not isinstance(data["environment"].get(key), str) or not data["environment"][key]:
            raise Failure(f"Missing environment identity: {key}.")
    if not isinstance(data["environment"].get("flags"), list) or not data["environment"]["flags"]:
        raise Failure("Missing compilation flags.")
    if not re.fullmatch(r"[0-9a-f]{40,64}", data["source"].get("head", "")) or not data["source"].get("files"):
        raise Failure("Missing exact source identity.")
    return data


def summarize(data):
    rows = {}
    for name, report in data["reports"].items():
        samples = report["samples"]
        metrics = {}
        for key in METRICS:
            values = [sample[key] for sample in samples]
            median = statistics.median(values)
            metrics[key] = {"median": median, "mad": statistics.median(abs(v - median) for v in values)}
        rows[name] = {"metrics": metrics, "counters": {
            key: {"min": min(s["counters"][key] for s in samples),
                  "max": max(s["counters"][key] for s in samples)}
            for key in samples[0]["counters"]
        }}
    return {"schema": SCHEMA, "sourceHead": data["source"]["head"], "environment": data["environment"],
            "evidenceKind": "simulator", "scenarios": rows}


def compare(before, after, tolerance):
    if not math.isfinite(tolerance) or not 0 <= tolerance <= 100:
        raise Failure("Regression tolerance must be between 0 and 100 percent.")
    for key in ("environment", "fixtures", "scenarios"):
        if before[key] != after[key]:
            raise Failure(f"Incompatible {key}; capture a separate baseline, do not compare unlike workloads.")
    rows = []
    for name, spec in expected_reports(before["scenarios"]).items():
        a, b = before["reports"][name]["samples"], after["reports"][name]["samples"]
        for metric in METRICS:
            av, bv = ([s[metric] for s in samples] for samples in (a, b))
            am, bm = statistics.median(av), statistics.median(bv)
            mad = max(statistics.median(abs(v - m) for v in values) for values, m in ((av, am), (bv, bm)))
            gated = metric in spec.get("timing", ["wallMilliseconds", "cpuMilliseconds"])
            allowance = max(abs(am) * tolerance / 100, 3 * mad, 1.0)
            noisy = gated and mad > max(abs(am) * 0.20, 1.0)
            verdict = ("inconclusive" if noisy else "regression" if bm - am > allowance else "within-budget") if gated else "informational"
            rows.append({"scenario": name, "metric": metric, "baselineMedian": am, "candidateMedian": bm,
                         "delta": bm - am, "allowance": allowance if gated else None, "verdict": verdict})
        for counter in spec["counters"]:
            am, bm = (statistics.median(s["counters"][counter] for s in samples) for samples in (a, b))
            rows.append({"scenario": name, "metric": counter, "baselineMedian": am, "candidateMedian": bm,
                         "delta": bm - am, "verdict": "work-count"})
    verdict = "regression" if any(r["verdict"] == "regression" for r in rows) else (
        "inconclusive" if any(r["verdict"] == "inconclusive" for r in rows) else "within-budget")
    return {"schema": SCHEMA, "verdict": verdict, "tolerancePercent": tolerance, "rows": rows,
            "note": "Within-budget is not proof of improvement. Memory snapshots and simulator timings are not hardware performance."}


def interrupted(signum, _frame):
    raise Failure(f"Interrupted ({signum}); partial evidence retained.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("list", help="Print the machine-readable scenario inventory.")
    report_command = commands.add_parser("report", help="Print compact metric/counter summaries without source-file manifests.")
    report_command.add_argument("run", type=Path)
    run = commands.add_parser("run", help="Run bounded optimized tests on an explicit owned simulator.")
    run.add_argument("--platform", choices=("tvOS", "iOS"), required=True)
    run.add_argument("--sim-id", required=True)
    run.add_argument("--suite", choices=("core", "ui", "matrix", "diagnostics", "network", "all"))
    run.add_argument("--scenario", nargs="+")
    run.add_argument("--timeout", type=int, default=2400)
    profile = commands.add_parser("profile", help="Profile native Home navigation on an owned tvOS simulator.")
    profile.add_argument("--platform", choices=("tvOS",), required=True)
    profile.add_argument("--sim-id", required=True)
    profile.add_argument("--timeout", type=int, default=2400)
    profile.add_argument("--template", choices=("Time Profiler", "SwiftUI", "Process Sample"), default="Process Sample")
    profile.add_argument("--workload", choices=("home-navigation", "detail-return"), default="home-navigation")
    comparison = commands.add_parser("compare", help="Compare saved runs; never updates a baseline.")
    comparison.add_argument("baseline", type=Path)
    comparison.add_argument("candidate", type=Path)
    comparison.add_argument("--tolerance-percent", type=float, default=15)
    args = parser.parse_args(argv)
    if args.operation == "list":
        print(json.dumps(SCENARIOS, indent=2))
        return 0
    if args.operation == "report":
        path = args.run / "result.json" if args.run.is_dir() else args.run
        data = json.loads(path.read_text())
        if data.get("evidenceKind") == "simulator-navigation-profile":
            navigation = data.get("navigation", {})
            if data.get("status") != "passed" or not (navigation.get("cpu", {}).get("count")
                    or navigation.get("stacks", {}).get("mainThreadFrames")):
                raise Failure("Navigation profile is incomplete.")
            print(json.dumps({key: data[key] for key in ("environment", "navigation")}, indent=2, allow_nan=False))
        else:
            print(json.dumps(summarize(read_run(args.run)), indent=2, allow_nan=False))
        return 0
    if args.operation == "compare":
        result = compare(read_run(args.baseline), read_run(args.candidate), args.tolerance_percent)
        output = ROOT / ".build/performance/comparisons" / (uuid.uuid4().hex + ".json")
        output.parent.mkdir(parents=True, exist_ok=True)
        write_json(output, dict(result, baseline=str(args.baseline.resolve()), candidate=str(args.candidate.resolve())))
        print(f"Comparison: {result['verdict']}; evidence: {output}")
        for row in result["rows"]:
            print(f"{row['scenario']} {row['metric']}: {row['baselineMedian']:.3f} -> {row['candidateMedian']:.3f} [{row['verdict']}]")
        return {"within-budget": 0, "regression": 1, "inconclusive": 2}[result["verdict"]]
    args.names = [] if args.operation == "profile" else select(args.suite, args.scenario, args.platform)
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", args.sim_id):
        raise Failure("--sim-id must be an explicit owned simulator UUID.")
    if not 60 <= args.timeout <= 7200:
        raise Failure("--timeout must be between 60 and 7200 seconds.")
    if Path.cwd().resolve() != ROOT:
        raise Failure("Run from the active Plozz checkout root.")
    if not any(key.startswith("APPLE_BUILD_LEASE_") for key in os.environ):
        os.execv("/bin/bash", ["/bin/bash", str(ROOT / "tools/with-apple-build-lease.sh"),
                 "plozz/performance", "--", sys.executable, str(Path(__file__).resolve()),
                 *(sys.argv[1:] if argv is None else argv)])
    fds = load_module(ROOT / "tools/run-bounded.py").inherited_lease_fds()
    if not fds or os.environ.get("APPLE_BUILD_LEASE_MODE") != "shared":
        raise Failure("An authenticated shared build lease is required.")
    folder = ROOT / ".build/performance"
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "lane.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        handlers = {sig: signal.signal(sig, interrupted) for sig in signals}
        try:
            Lane(ROOT, args, fds).execute()
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Failure, OSError, ValueError, KeyError, subprocess.TimeoutExpired, ET.ParseError) as error:
        print(f"performance: {error}", file=sys.stderr)
        sys.exit(1)
