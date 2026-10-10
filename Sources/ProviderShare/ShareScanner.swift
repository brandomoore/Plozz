import Foundation
import CoreModels
import CoreNetworking
import MediaTransportCore

/// Walks a share's directory tree and populates a `ShareCatalogStore`, so the
/// share can serve Recently Added / Search / indexed libraries without a live walk.
///
/// **Design (per the media-share master plan + SMB-perf research):**
///  * **Parallel, pooled walk.** The `thatcube/SMBClient` library is strictly
///    serial per connection (one in-flight request per `Connection` semaphore), so
///    the ONLY way to parallelise is multiple independent connections. The scanner
///    runs a pool of `concurrency` independent listers (each its own SMB
///    connection) over a **level-by-level BFS** — media trees are wide at the
///    show/season/file levels, so a small pool (default 4) yields ~Nx throughput.
///  * **Foreground, incremental, idempotent.** tvOS has no `BGProcessingTask`, so
///    scanning runs while foregrounded. A re-walk is safe: upserts preserve
///    `first_seen_at`, so "date added" stays first-discovery.
///  * **Bounded memory.** Only the current BFS level's directory listings are held
///    (a few MB at most); each directory's files are committed immediately.
///  * **Cancellation-safe.** On cancel mid-walk it stops without pruning, so a
///    partial pass can't wipe still-present content; the next scan resumes coverage.
///  * **Separate SMB connections.** The pool's listers are dedicated to scanning
///    (not the interactive browser), so a walk never starves live folder browsing.
///
/// The lister *factory* is injected so the walk is unit-testable with a fake tree
/// (each pool slot gets its own lister; fakes can share a concurrency-safe tree).
actor ShareScanner {
    typealias Lister = @Sendable (_ relPath: String) async throws -> [RemoteFileEntry]

    struct FrontierEntry: Codable, Hashable, Sendable {
        var relPath: String
        var extraTraversal: ShareExtraTraversal?

        init(relPath: String, extraTraversal: ShareExtraTraversal? = nil) {
            self.relPath = relPath
            self.extraTraversal = extraTraversal
        }

        static func legacy(relPath: String) -> FrontierEntry {
            let components = relPath.split(separator: "/").map(String.init)
            guard let last = components.last,
                  let folder = ShareExtraDiscoveryPolicy.folderKind(last),
                  components.count > 1 else {
                return FrontierEntry(relPath: relPath)
            }
            let parent = components.dropLast().joined(separator: "/")
            if components.count > 2,
               let generic = ShareExtraDiscoveryPolicy.folderKind(
                   components[components.count - 2]
               ),
               generic.permitsTypedChildren,
               case .typed = folder {
                return FrontierEntry(
                    relPath: relPath,
                    extraTraversal: ShareExtraTraversal(
                        ownerPath: components.dropLast(2).joined(separator: "/"),
                        ownerFileRelPath: nil,
                        defaultKind: folder.defaultKind,
                        permitsTypedChildren: false
                    )
                )
            }
            return FrontierEntry(
                relPath: relPath,
                extraTraversal: ShareExtraTraversal(
                    ownerPath: parent,
                    ownerFileRelPath: nil,
                    defaultKind: folder.defaultKind,
                    permitsTypedChildren: folder.permitsTypedChildren
                )
            )
        }
    }

    /// One pool slot: an independent directory lister + its teardown. In production
    /// each wraps a dedicated transport session (its own SMB connection); in tests a
    /// closure over a shared fake tree with a no-op close.
    struct ScanLister: Sendable {
        let list: Lister
        private let closer: ScanListerCloser

        init(
            list: @escaping Lister,
            close: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            closer = ScanListerCloser(close: close)
        }

        func close() async {
            await closer.close()
        }
    }

    struct SuspensionHandoff: Sendable {
        let listers: [ScanLister]
        let checkpoint: ShareScanResumeCheckpoint?
    }

    private struct ActiveResumeState {
        let scanGeneration: UUID
        let scanID: Int64
        let frontier: [FrontierEntry]
        let deep: Bool
        let startedAt: TimeInterval
        let hasFailures: Bool
    }

    private actor ScanListerCloser {
        private let closeAction: @Sendable () async -> Void
        private var closeTask: Task<Void, Never>?

        init(close: @escaping @Sendable () async -> Void) {
            closeAction = close
        }

        func close() async {
            let task: Task<Void, Never>
            if let closeTask {
                task = closeTask
            } else {
                let closeAction = self.closeAction
                let created = Task.detached(priority: .utility) {
                    await closeAction()
                }
                closeTask = created
                task = created
            }
            await task.value
        }
    }

    private let store: ShareCatalogStore
    private let makeLister: @Sendable () -> ScanLister
    private let concurrency: Int
    private let pacer: ShareScanPacer
    private let shareID: String
    private var name: String
    nonisolated let libraryConfiguration: MediaShareLibraryConfiguration?
    private var reporter: ShareScanReporter
    private var isRunning = false
    private var isInvalidated = false
    private var activeListers: [ScanLister] = []
    private var activeListerGeneration: UUID?
    private var activeResumeState: ActiveResumeState?
    private var backgroundWorkAllowed = true
    private var backgroundWorkRevision: UInt64 = 0

    /// Non-media folder names whose subtree is skipped wholesale. Extras use their
    /// own bounded traversal and never enter the normal asset walk.
    private static let excludedDirs: Set<String> = [
        "sample", "subs", "subtitles", "@eadir", ".actors",
    ]

    init(store: ShareCatalogStore, shareID: String = "", name: String = "",
         reporter: ShareScanReporter = .noop, concurrency: Int = 4,
         libraryConfiguration: MediaShareLibraryConfiguration? = nil,
         makeLister: @escaping @Sendable () -> ScanLister) {
        self.init(
            store: store,
            shareID: shareID,
            name: name,
            reporter: reporter,
            concurrency: concurrency,
            pacer: ShareScanPacer(),
            libraryConfiguration: libraryConfiguration,
            makeLister: makeLister
        )
    }

    /// Test seam for deterministic pacing behavior; production uses `.shared`
    /// through the source-compatible initializer above.
    init(store: ShareCatalogStore, shareID: String = "", name: String = "",
         reporter: ShareScanReporter = .noop, concurrency: Int = 4,
         pacer: ShareScanPacer,
         libraryConfiguration: MediaShareLibraryConfiguration? = nil,
         makeLister: @escaping @Sendable () -> ScanLister) {
        self.store = store
        self.shareID = shareID
        self.name = name
        self.reporter = reporter
        self.concurrency = max(1, concurrency)
        self.pacer = pacer
        self.libraryConfiguration = libraryConfiguration
        self.makeLister = makeLister
    }

    /// Re-point progress reporting after creation, so a scanner built before the
    /// app wired its status reporter (a startup race) still drives the UI. If a scan
    /// is already in flight, replay `scanStarted` so the new reporter learns of it
    /// (its `scanStarted` went to the previous `.noop` reporter and would otherwise
    /// leave later progress/finish events with no state to update).
    func setReporter(_ reporter: ShareScanReporter) {
        self.reporter = reporter
        if isRunning { reporter.scanStarted(shareID, name) }
    }

    func setName(_ name: String) {
        self.name = name
    }

    func invalidate() {
        isInvalidated = true
    }

    func forceCloseActiveListers(scanGeneration: UUID) async {
        guard activeListerGeneration == scanGeneration else { return }
        let listers = activeListers
        activeListers = []
        activeListerGeneration = nil
        await withTaskGroup(of: Void.self) { group in
            for lister in listers {
                group.addTask {
                    await lister.close()
                }
            }
        }
    }

    /// Applies lifecycle admission and, when suspending, snapshots a conservative
    /// whole-level frontier before detaching the exact listers owned by the current
    /// scan. Rewalking part of that level is safe; omitting in-flight directories is
    /// not. Revision fencing keeps stale callbacks out of newer generations.
    func setBackgroundWorkAllowed(
        _ allowed: Bool,
        revision: UInt64
    ) -> SuspensionHandoff {
        guard revision > backgroundWorkRevision
                || (revision == backgroundWorkRevision
                    && allowed == backgroundWorkAllowed) else {
            return SuspensionHandoff(
                listers: [],
                checkpoint: nil
            )
        }
        if revision > backgroundWorkRevision {
            backgroundWorkRevision = revision
        }
        backgroundWorkAllowed = allowed
        guard !allowed else {
            return SuspensionHandoff(
                listers: [],
                checkpoint: nil
            )
        }
        let listers = activeListers
        activeListers = []
        activeListerGeneration = nil
        return SuspensionHandoff(
            listers: listers,
            checkpoint: activeResumeState.flatMap { Self.resumeCheckpoint($0) }
        )
    }

    /// Run a scan unless one already ran within `minInterval` (or is running).
    /// Called fire-and-forget from the Home hot path, so it must be cheap to no-op.
    @discardableResult
    /// Default interval kept in step with the coordinator's spawn coalesce, so a
    /// spawn is only allowed once a walk would actually run.
    func scanIfStale(
        minInterval requestedInterval: TimeInterval = 180,
        scanGeneration: UUID = UUID()
    ) async -> ShareScanOutcome {
        if isRunning { return .freshNoOp }
        if isInvalidated { return .invalidated }
        if Task.isCancelled || !backgroundWorkAllowed {
            return .cancelled(scanGeneration: nil)
        }
        // Developer override so back-to-back measurement passes are possible on a
        // device; `nil` in every normal build. See `ShareScanDebug`.
        let minInterval = ShareScanDebug.scanInterval ?? requestedInterval
        // Force a walk (ignoring the staleness throttle) when the CLASSIFIER changed
        // since the last completed pass, so every already-indexed file is
        // reclassified under the new movie/episode rules right away instead of
        // waiting for it to change on disk (a re-walk re-upserts each file's kind/
        // library/keys). A cheap meta read on the hot path.
        let parserCurrent = String(ShareMediaParser.classifierVersion)
        let parserStored = await store.meta("parser_version")
        // Same idea for the SIDECAR/explicit-id inventory (Step 3): a version bump
        // here forces exactly one re-walk so an already-indexed share discovers
        // existing NFO files / backfills explicit ids without waiting for files to
        // change on disk — independent of the classifier and never forcing
        // external re-enrichment (no `enrich_version`/`ShareEnricher` touch).
        let localInventoryCurrent = String(ShareMediaParser.localInventoryVersion)
        let localInventoryStored = await store.meta("local_inventory_version")
        let configurationStored = await store.meta("library_configuration")
        let requiresCompleteRewalk = parserStored != parserCurrent
            || localInventoryStored != localInventoryCurrent
            || configurationStored != classificationFingerprint
        if requiresCompleteRewalk {
            // A version bump changes what an unchanged directory listing means.
            // Invalidate the completed-mtime stamp so leaf directories cannot take
            // the incremental skip path before the new rules see them once.
            await store.invalidateCompletedDirectoryState()
        }
        if parserStored == parserCurrent,
           localInventoryStored == localInventoryCurrent,
           configurationStored == classificationFingerprint,
           let last = await store.meta("last_full_scan_at"),
           let ts = TimeInterval(last),
           Date().timeIntervalSince1970 - ts < minInterval {
            return .freshNoOp
        }
        // All folders are re-verified on a long cadence rather than every pass.
        // Directory mtimes cannot reveal in-place file edits, and some servers
        // do not update them reliably even when children change. A share that
        // has never completed one is due, so the first pass after upgrading is
        // deep and the incremental state it leaves behind is complete.
        let lastDeep = await store.meta("last_deep_scan_at").flatMap(TimeInterval.init)
        let dueForDeep = lastDeep.map {
            Date().timeIntervalSince1970 - $0 >= Self.deepScanInterval
        } ?? true
        return await scan(deep: ShareScanDebug.forceDeep ?? dueForDeep, scanGeneration: scanGeneration)
    }

    /// How often all directory contents are re-verified without trusting mtimes.
    ///
    /// This is the cadence at which an NFO edited in place, or a poster deleted
    /// without its folder's mtime moving, is noticed. Daily rather than every ten
    /// minutes: those are hand edits on a library the viewer is not usually
    /// watching at the same moment, and the old cadence re-listed essentially
    /// every leaf folder 144 times a day to catch them.
    static let deepScanInterval: TimeInterval = 24 * 60 * 60

    /// Parent directories of `paths` — i.e. every directory known to contain a
    /// subdirectory. A top-level entry's parent is the root, `""`.
    static func parentPaths(of paths: some Sequence<String>) -> Set<String> {
        var out: Set<String> = []
        for path in paths where !path.isEmpty {
            if let slash = path.lastIndex(of: "/") {
                out.insert(String(path[path.startIndex..<slash]))
            } else {
                out.insert("")
            }
        }
        return out
    }

    /// How close to "now" a directory mtime may be and still be trusted for
    /// skipping on a later pass.
    ///
    /// The racy-timestamp problem, and the same one git solves for its index: a
    /// file added in the *same second* the scan reads the directory leaves an
    /// mtime equal to the one recorded, so the directory would look unchanged
    /// forever after. Many filesystems and every SMB/NFS server in practice have
    /// one-second resolution, so the window has to cover a whole tick plus skew.
    static let racyMTimeWindow: TimeInterval = 2

    /// The mtime to persist, or `nil` when it is too fresh to be trusted.
    ///
    /// Recording `nil` costs one listing of that directory on the next pass —
    /// there is no stored mtime to compare against, so it can't be skipped —
    /// which is exactly the conservative outcome wanted, and it self-corrects on
    /// the pass after.
    static func trustworthyMTime(_ mtime: Date?, now: Date = Date()) -> Date? {
        guard let mtime else { return nil }
        return now.timeIntervalSince(mtime) >= racyMTimeWindow ? mtime : nil
    }

    /// Full breadth-first walk from the share root, using a pool of independent
    /// connections to list `concurrency` directories at once. Idempotent.
    @discardableResult
    func scan(deep: Bool = true, scanGeneration: UUID = UUID()) async -> ShareScanOutcome {
        if isRunning { return .freshNoOp }
        if isInvalidated { return .invalidated }
        if Task.isCancelled || !backgroundWorkAllowed {
            return .cancelled(scanGeneration: nil)
        }
        isRunning = true
        activeResumeState = nil
        await store.activateScanGeneration(scanGeneration)
        let storedParserVersion = await store.meta("parser_version")
        let storedInventoryVersion = await store.meta("local_inventory_version")
        let storedConfiguration = await store.meta("library_configuration")
        let configurationChanged = storedConfiguration != classificationFingerprint
        let externalContextChanged = configurationChanged
            && (storedConfiguration != nil || libraryConfiguration != nil)
        let rulesChanged = storedParserVersion != String(ShareMediaParser.classifierVersion)
            || storedInventoryVersion != String(ShareMediaParser.localInventoryVersion)
            || configurationChanged
        // An interrupted pass can leave newly discovered rows unreconciled even
        // when its checkpoint is unusable and the next walk finds the same count.
        let completedScan = await store.meta(ShareCatalogStore.completedDirectoryStateScanKey)
        let hasCompletedBaseline = Int64(completedScan ?? "") != nil
        // Snapshot the previous clean pass's incremental state before invalidating
        // the completion proof used by the next scanner.
        let storedDirectoryMTimes = rulesChanged ? [:] : await store.directoryModifiedSeconds()
        let recordedDirectoryPaths = await store.recordedDirectoryPaths()
        let directoriesWithRecordedFiles = await store.directoriesWithRecordedFiles()
        await store.invalidateCompletedDirectoryState()
        if rulesChanged {
            // Manual scans must receive the same one-time full rewalk as the stale
            // scheduler. Old resume/frontier and completed-leaf stamps describe the
            // previous classifier and cannot safely skip directories under new rules.
            await Self.clearResumeState(store: store, scanGeneration: scanGeneration)
        }
        let started = Date()
        guard !Task.isCancelled, backgroundWorkAllowed, !isInvalidated else {
            await finishScan(listers: [])
            return isInvalidated ? .invalidated : .cancelled(scanGeneration: scanGeneration)
        }
        reporter.scanStarted(shareID, name)

        if libraryConfiguration?.contentType == .personalVideos {
            // Personal Videos use the live file tree directly. Do not walk the
            // share or build movie/show assets, and retain any prior path aliases
            // long enough to carry existing watch progress onto raw file ids.
            // All provider read/enrichment paths are independently gated off for
            // this configuration, so retained rows are never presented as media.
            await Self.clearResumeState(store: store, scanGeneration: scanGeneration)
            let now = String(Date().timeIntervalSince1970)
            await store.setMeta("last_full_scan_at", now, scanGeneration: scanGeneration)
            if deep {
                await store.setMeta("last_deep_scan_at", now, scanGeneration: scanGeneration)
            }
            await store.setMeta(
                "parser_version",
                String(ShareMediaParser.classifierVersion),
                scanGeneration: scanGeneration
            )
            await store.setMeta(
                "local_inventory_version",
                String(ShareMediaParser.localInventoryVersion),
                scanGeneration: scanGeneration
            )
            let configurationApplied: Bool
            if externalContextChanged {
                configurationApplied = await store.resetExternalEnrichment(
                    scanGeneration: scanGeneration
                )
            } else {
                configurationApplied = true
            }
            if configurationApplied {
                await store.setMeta(
                    "library_configuration",
                    classificationFingerprint,
                    scanGeneration: scanGeneration
                )
                await store.setLibraryAnimeContext(false, scanGeneration: scanGeneration)
            }
            PlozzLog.boot(
                "share.scan personal-videos live-tree-only elapsed=\(Int(Date().timeIntervalSince(started) * 1_000))ms"
            )
            await finishScan(listers: [], completed: true)
            return configurationApplied ? .completedClean : .completedPartial
        }

        // Pre-build the pool of independent listers (each its own SMB connection).
        // `pool` tracks EVERY lister we create (including ones swapped in to replace
        // a wedged connection) so all are torn down when the scan ends. Each close
        // runs in its own task so one hung teardown can't block the others.
        var pool = (0..<concurrency).map { _ in makeLister() }
        activeListers = pool
        activeListerGeneration = scanGeneration
        // The live free-list of healthy connections, carried ACROSS BFS levels. Every
        // dispatched lister returns here exactly once per level (healthy back as-is; a
        // failed one replaced by a fresh connection), so at each level boundary it
        // holds exactly `concurrency` healthy listers.
        var free = pool

        // Resume an interrupted pass rather than re-walking from the root.
        //
        // CRITICAL: a resume reuses the interrupted pass's scanID. Everything the
        // earlier pass upserted carries that id, and the prune deletes rows whose
        // `last_scan` differs — so allocating a fresh id here would make the
        // completed portion look vanished and delete it. Reusing the id also makes
        // the union of both passes a complete walk, which is exactly what the
        // prune requires to be correct.
        let resumeState = await Self.loadResumeState(store: store, deep: deep)
        let snapshotStartedAt = resumeState?.startedAt ?? started.timeIntervalSince1970
        let scanID: Int64
        var frontier: [FrontierEntry]
        if let resumeState {
            scanID = resumeState.scanID
            frontier = resumeState.frontier
            PlozzLog.boot(
                "share.scan resume scanID=\(scanID) pending=\(frontier.count) concurrency=\(concurrency)"
            )
        } else {
            guard let fresh = await store.nextScanID(for: scanGeneration),
                  !Task.isCancelled,
                  backgroundWorkAllowed,
                  !isInvalidated else {
                await finishScan(listers: pool)
                if isInvalidated { return .invalidated }
                return Task.isCancelled || !backgroundWorkAllowed
                    ? .cancelled(scanGeneration: scanGeneration)
                    : .failedToStart
            }
            scanID = fresh
            frontier = [FrontierEntry(relPath: "")] // "" == share root
            PlozzLog.boot("share.scan begin scanID=\(scanID) concurrency=\(concurrency)")
        }
        activeResumeState = ActiveResumeState(
            scanGeneration: scanGeneration,
            scanID: scanID,
            frontier: frontier,
            deep: deep,
            startedAt: snapshotStartedAt,
            hasFailures: false
        )
        guard !Task.isCancelled, backgroundWorkAllowed, !isInvalidated else {
            await Self.saveResumeState(
                store: store,
                scanID: scanID,
                frontier: frontier,
                scanGeneration: scanGeneration,
                deep: deep,
                startedAt: snapshotStartedAt,
                hasFailures: false
            )
            await finishScan(listers: pool)
            return isInvalidated
                ? .invalidated
                : .cancelled(scanGeneration: scanGeneration)
        }
        // Directories known to CONTAIN a subdirectory, derived from the recorded
        // paths rather than queried per-child.
        //
        // Load-bearing for the skip rule below, and the reason it isn't simply
        // "unchanged ⇒ skip". One listing returns every child *with its mtime*,
        // so listing a parent is what makes skipping all of its children
        // possible. Skipping the parent instead forfeits that: its children's
        // fresh mtimes are unobtainable, so every one of them has to be listed.
        // For a series folder with ten seasons, skipping saved one listing and
        // forced ten — the optimization ran backwards on every interior node.
        // From ALL recorded directories, not just the skippable ones: a child the
        // server gave no mtime for is absent from `storedDirectoryMTimes`, and
        // deriving shape from those keys made its parent look childless and
        // therefore skippable — orphaning the child and pruning its media.
        let directoriesWithSubdirectories =
            Self.parentPaths(of: recordedDirectoryPaths)
        // Directories we have actually indexed files for. Being recorded in
        // `dir_state` only says a listing once succeeded, NOT that the subtree was
        // walked — a scan interrupted between recording a folder and reaching its
        // children leaves it looking like a finished, empty leaf. Since a folder's
        // own mtime never moves when a grandchild changes, the skip below then
        // re-skips it on every later pass and its media stays invisible forever.
        // Requiring positive evidence makes the skip an assertion about content we
        // have, rather than an assumption from content we don't.
        // mtime each directory was reported with by its parent's listing, so the
        // value recorded for a folder is the one a later scan will compare against.
        var listedDirectoryMTimes: [String: Date?] = [:]
        var dirsWalked = 0
        var dirsSkipped = 0
        var filesFound = 0
        var extrasFound = 0
        // Split local bookkeeping from network wait in the scan diagnostics.
        var storeNanos: UInt64 = 0
        var skipStoreNanos: UInt64 = 0
        var listWaitNanos: UInt64 = 0
        var unchangedPass = false
        // Skipped paths are stamped together before each level's checkpoint.
        var skippedDirectories: [FrontierEntry] = []
        // Catalog size before the walk, so an unchanged pass can be recognised
        // and skip the clean-scan reconciliation entirely.
        let priorAssetCount = await store.assetDiscoveryStats(newerThan: 0).total
        let priorExtraCount = await store.extraCount()
        let progressClock = ContinuousClock()
        var lastProgressReport = progressClock.now
        // Set if ANY directory listing failed this pass (transient SMB timeout, auth
        // hiccup, permission-denied folder). A failed listing looks like an empty
        // folder, so pruning on a partial walk would delete still-present content and
        // reset its "date added" on rediscovery — skip the prune when this is set.
        var anyListingFailed = false
        // PATH-FREE aggregate of listing failures by bounded category (C3): no dir/
        // basename/error text is ever recorded — only per-category counts, logged once.
        var listFailureCounts: [ShareScanListFailureCategory: Int] = [:]

        // Level-by-level BFS. Each level's directories are listed in parallel across
        // the pool; a plain free-list of listers (managed here on the actor) bounds
        // concurrency to the pool size with no locks/continuations.
        while !frontier.isEmpty {
            activeResumeState = ActiveResumeState(
                scanGeneration: scanGeneration,
                scanID: scanID,
                frontier: frontier,
                deep: deep,
                startedAt: snapshotStartedAt,
                hasFailures: anyListingFailed
            )
            if Task.isCancelled || !backgroundWorkAllowed {
                await Self.saveResumeState(
                    store: store, scanID: scanID, frontier: frontier,
                    scanGeneration: scanGeneration, deep: deep,
                    startedAt: snapshotStartedAt, hasFailures: anyListingFailed
                )
                PlozzLog.boot(
                    "share.scan cancelled after \(dirsWalked) dirs, \(filesFound) files — "
                        + "no prune, \(frontier.count) dir(s) saved to resume"
                )
                await finishScan(listers: pool)
                return .cancelled(scanGeneration: scanGeneration)
            }
            var nextFrontier: [FrontierEntry] = []
            var completedDirectories: Set<String> = []
            var index = 0                         // next directory in `frontier` to dispatch

            await withTaskGroup(of: DirResult.self) { group in
                func spawnNext() {
                    guard index < frontier.count, let lister = free.popLast() else { return }
                    let entry = frontier[index]
                    index += 1
                    let configuration = libraryConfiguration
                    group.addTask {
                        await Self.processDirectory(
                            entry,
                            using: lister,
                            libraryConfiguration: configuration
                        )
                    }
                }
                // Fill the pool.
                for _ in 0..<concurrency { spawnNext() }
                // Drain results, committing each directory and launching the next.
                var waitStart = DispatchTime.now().uptimeNanoseconds
                while let result = await group.next() {
                    listWaitNanos += DispatchTime.now().uptimeNanoseconds - waitStart
                    guard !Task.isCancelled,
                          backgroundWorkAllowed,
                          !isInvalidated else {
                        group.cancelAll()
                        continue
                    }
                    if result.dir.isEmpty {
                        if result.ok {
                            reporter.reachability(shareID, false)
                        } else if result.failureCategory == .timedOut || result.failureCategory == .connectionLost {
                            reporter.reachability(shareID, true)
                        }
                    }
                    if result.ok {
                        free.append(result.lister)     // healthy — return it to the pool
                    } else {
                        // A failed listing likely left this connection WEDGED: the SMB
                        // library doesn't honour cancellation mid-read, so a timed-out
                        // read keeps holding the connection's lock and every later list
                        // on it also times out (20s each) — one bad socket crawls the
                        // whole walk and it looks stuck. Discard it (fire-and-forget
                        // close, since that may hang too) and swap in a FRESH
                        // connection so throughput recovers immediately.
                        anyListingFailed = true
                        listFailureCounts[result.failureCategory ?? .other, default: 0] += 1
                        let dead = result.lister
                        Task { await dead.close() }
                        let fresh = makeLister()
                        pool.append(fresh)
                        activeListers.append(fresh)
                        free.append(fresh)
                    }
                    dirsWalked += 1
                    let storeStart = DispatchTime.now().uptimeNanoseconds
                    if result.ok {
                        await store.recordDirectory(
                            relPath: result.dir,
                            modifiedAt: Self.trustworthyMTime(
                                listedDirectoryMTimes[result.dir] ?? nil,
                                now: started
                            ),
                            scanID: scanID,
                            scanGeneration: scanGeneration
                        )
                    }
                    // Split this directory's children: an unchanged one keeps its
                    // recorded contents (stamped so the prune spares them) and is
                    // NOT listed, but we still descend into ITS children — a
                    // directory's mtime says nothing about deeper changes.
                    for child in result.subdirectories {
                        let childPath = child.frontier.relPath
                        listedDirectoryMTimes[childPath] = child.modifiedAt
                        if !deep,
                           let mtime = child.modifiedAt,
                           let known = storedDirectoryMTimes[childPath],
                           // Compared as raw seconds, the form persisted, so both
                           // sides take the identical conversion — see
                           // `directoryModifiedSeconds`.
                           known == mtime.timeIntervalSince1970,
                           // Leaves only. A directory with children must be
                           // listed even when unchanged, because that single
                           // listing is what yields their mtimes and lets the
                           // whole level below be skipped.
                           !directoriesWithSubdirectories.contains(childPath),
                           // ...and a leaf we have actually indexed files for. A
                           // folder with neither recorded files nor recorded
                           // subdirectories is not a finished leaf, it is one we
                           // know nothing about — see
                           // `directoriesWithRecordedFiles`.
                           directoriesWithRecordedFiles.contains(childPath) {
                            dirsSkipped += 1
                            // Collected, not stamped here. Stamping per directory
                            // cost five statements each and dominated the whole
                            // scan; one batched pass at the end does the same work
                            // in four. See `touchDirectoryContents(relPaths:)`.
                            skippedDirectories.append(child.frontier)
                            // No `recordedSubdirectories` lookup: the skip
                            // condition above requires this directory to have no
                            // recorded subdirectories, so that query is provably
                            // empty here. It was one actor hop and one LIKE scan
                            // per skip to fetch a guaranteed-empty result.
                        } else {
                            nextFrontier.append(child.frontier)
                        }
                    }
                    if !result.assets.isEmpty {
                        filesFound += result.assets.count
                        await store.upsert(
                            result.assets,
                            scanID: scanID,
                            scanGeneration: scanGeneration,
                            recordPlayableInventory: false
                        )
                    }
                    if !result.playablePaths.isEmpty {
                        let persisted = await store.upsertPlayablePaths(
                            result.playablePaths,
                            scanID: scanID,
                            scanGeneration: scanGeneration
                        )
                        if !persisted {
                            // Without complete playable inventory, folder promotion
                            // could hide an intentionally unclassified file. Treat
                            // this pass as partial and retain the previous catalog.
                            anyListingFailed = true
                        }
                    }
                    if !result.sidecars.isEmpty {
                        await store.upsertSidecars(
                            result.sidecars,
                            scanID: scanID,
                            scanGeneration: scanGeneration
                        )
                    }
                    if !result.artwork.isEmpty {
                        await store.upsertArtwork(
                            result.artwork,
                            scanID: scanID,
                            scanGeneration: scanGeneration
                        )
                    }
                    if !result.extras.isEmpty {
                        extrasFound += result.extras.count
                        await store.upsertExtras(
                            result.extras,
                            scanID: scanID,
                            scanGeneration: scanGeneration,
                            recordPlayableInventory: false
                        )
                    }
                    storeNanos += DispatchTime.now().uptimeNanoseconds - storeStart
                    let now = progressClock.now
                    if dirsWalked == 1
                        || lastProgressReport.duration(to: now) >= .milliseconds(250) {
                        // Everything still queued: this level's undispatched tail
                        // plus the children discovered so far. Walked vs walked +
                        // pending is the walk's REAL completion — the frontier is
                        // the only honest denominator a breadth-first walk has
                        // (the tree's size isn't knowable until it's walked).
                        let pending = (frontier.count - index) + nextFrontier.count
                        reporter.scanFrontierProgress(
                            shareID, dirsWalked, max(0, pending), filesFound
                        )
                        lastProgressReport = now
                    }
                    guard !Task.isCancelled, backgroundWorkAllowed, !isInvalidated else {
                        group.cancelAll()
                        continue
                    }
                    completedDirectories.insert(result.dir)
                    // Never pause for browsing (which could starve a scan forever).
                    // Instead, admit replacement directory requests at a bounded
                    // slower rate while the user is actively navigating the share.
                    if index < frontier.count {
                        await pacer.paceIfBrowsing()
                        spawnNext()
                    }
                    waitStart = DispatchTime.now().uptimeNanoseconds
                }
            }

            // Never force a stamp transaction through cancellation. Unstamped
            // leaves keep their traversal context and are queued for the resume.
            if !skippedDirectories.isEmpty, !Task.isCancelled, backgroundWorkAllowed, !isInvalidated {
                let flushStart = DispatchTime.now().uptimeNanoseconds
                let stamped = await store.touchDirectoryContents(
                    relPaths: skippedDirectories.map(\.relPath),
                    scanID: scanID,
                    scanGeneration: scanGeneration
                )
                if stamped {
                    skippedDirectories.removeAll(keepingCapacity: true)
                } else if !Task.isCancelled, backgroundWorkAllowed, !isInvalidated {
                    anyListingFailed = true
                    skippedDirectories.removeAll(keepingCapacity: true)
                }
                skipStoreNanos += DispatchTime.now().uptimeNanoseconds - flushStart
            }
            if Task.isCancelled || !backgroundWorkAllowed || isInvalidated {
                // Dispatch is not completion: cancelled in-flight results have not
                // been applied. A retried parent will rediscover its own children.
                let pending = frontier.filter { !completedDirectories.contains($0.relPath) }
                    + (nextFrontier + skippedDirectories).filter {
                        completedDirectories.contains(($0.relPath as NSString).deletingLastPathComponent)
                    }
                await Self.saveResumeState(
                    store: store, scanID: scanID, frontier: pending,
                    scanGeneration: scanGeneration, deep: deep,
                    startedAt: snapshotStartedAt, hasFailures: anyListingFailed
                )
                PlozzLog.boot(
                    "share.scan cancelled after \(dirsWalked) dirs, \(filesFound) files — "
                        + "no prune, \(pending.count) dir(s) saved to resume"
                )
                await finishScan(listers: pool)
                return isInvalidated ? .invalidated : .cancelled(scanGeneration: scanGeneration)
            }
            frontier = nextFrontier
            if !frontier.isEmpty {
                activeResumeState = ActiveResumeState(
                    scanGeneration: scanGeneration,
                    scanID: scanID,
                    frontier: frontier,
                    deep: deep,
                    startedAt: snapshotStartedAt,
                    hasFailures: anyListingFailed
                )
            }
            // Checkpoint at every level boundary, not only on graceful
            // cancellation: an app that is force-quit, crashes, or is suspended and
            // reclaimed by iOS never runs the cancellation path at all — which is
            // the common way a scan dies on a phone. One small meta write per BFS
            // level is cheap against a walk measured in minutes.
            await Self.saveResumeState(
                store: store, scanID: scanID, frontier: frontier,
                scanGeneration: scanGeneration, deep: deep,
                startedAt: snapshotStartedAt, hasFailures: anyListingFailed
            )
        }
        reporter.scanFrontierProgress(shareID, dirsWalked, 0, filesFound)

        // Completed a full pass. Only prune (drop assets no longer on the share) when
        // EVERY directory listed cleanly — a partial walk (some listing failed) must
        // not delete content that's merely temporarily unreachable. Still stamp the
        // completion time either way so `scanIfStale` throttles the next walk (a
        // permanently-inaccessible folder can't cause a perpetual re-scan); the next
        // clean pass performs the deferred prune.
        guard !isInvalidated else {
            await finishScan(listers: pool)
            return .invalidated
        }
        if !anyListingFailed {
            // Clean full pass: prune vanished assets AND every orphan row they
            // leave behind (enrichment/metadata_values/state, sidecar inventory +
            // value cache, dead aliases/merges), regroup movies, recompute sidecar
            // associations, and rematerialize local + filename projections — all in
            // ONE atomic transaction. After commit no readable item can resurrect a
            // deleted item's ids/artwork/metadata/state on path/series-key reuse.
            await store.pruneDirectoryStateNotSeen(
                inScan: scanID, scanGeneration: scanGeneration
            )
            // Nothing arrived and nothing vanished: the reconciliation below can
            // only reproduce what is already stored, so skip it. Completion
            // markers are still committed below; the saving is the reconciliation,
            // never the bookkeeping that makes incremental scanning work.
            if rulesChanged || resumeState != nil || !hasCompletedBaseline {
                // Resume-time counts include discoveries from the earlier half,
                // which may not have been reconciled, even if its frontier expired.
                unchangedPass = false
            } else {
                unchangedPass = await store.isMateriallyUnchanged(
                    inScan: scanID,
                    priorAssetCount: priorAssetCount,
                    priorExtraCount: priorExtraCount
                )
            }
            let finalized = unchangedPass ? true : await store.finalizeCleanScan(
                inScan: scanID,
                scanGeneration: scanGeneration
            )
            guard !isInvalidated else {
                await finishScan(listers: pool)
                return .invalidated
            }
            if !finalized {
                // Superseded generation or a rolled-back SQLite failure: the clean
                // transaction made NO change (no partial prune — invariant 9). Still
                // refresh the pure path-derived filename/explicit ids so they stay
                // current; orphan cleanup is deferred to the next clean pass.
                await store.materializeFilenameProviderIDs(scanGeneration: scanGeneration)
                await store.resolveExtraOwners(scanGeneration: scanGeneration)
                anyListingFailed = true
            } else {
                // Commit playable coverage only after asset/extra reconciliation
                // and owner resolution, before publishing a clean scan baseline.
                let inventoryFinalized = await store.finalizePlayableInventory(
                    inScan: scanID,
                    scanGeneration: scanGeneration
                )
                if inventoryFinalized {
                    await store.markDirectoryStateComplete(
                        scanID: scanID,
                        scanGeneration: scanGeneration
                    )
                } else {
                    anyListingFailed = true
                }
            }
        } else {
            // Partial walk: never prune/reconcile. Still refresh pure path-derived
            // filename/folder explicit ids (already persisted on the asset row and
            // independent of the deferred prune) into the same `metadata_values`
            // priority projection NFO ids use.
            guard !isInvalidated else {
                await finishScan(listers: pool)
                return .invalidated
            }
            await store.materializeFilenameProviderIDs(scanGeneration: scanGeneration)
            await store.resolveExtraOwners(scanGeneration: scanGeneration)
        }
        // The walk finished: no partial state to carry forward.
        await Self.clearResumeState(store: store, scanGeneration: scanGeneration)
        await store.setMeta(
            "last_full_scan_at",
            String(Date().timeIntervalSince1970),
            scanGeneration: scanGeneration
        )
        // A partial deep pass still owes verification of its failed folders.
        if deep, !anyListingFailed {
            await store.setMeta(
                "last_deep_scan_at",
                String(Date().timeIntervalSince1970),
                scanGeneration: scanGeneration
            )
        }
        // Record the classifier the catalog was built with, so `scanIfStale` only
        // force-reparses once per classifier bump (and doesn't perpetually re-walk).
        await store.setMeta(
            "parser_version",
            String(ShareMediaParser.classifierVersion),
            scanGeneration: scanGeneration
        )
        await store.setMeta(
            "local_inventory_version",
            String(ShareMediaParser.localInventoryVersion),
            scanGeneration: scanGeneration
        )
        let configurationApplied: Bool
        if externalContextChanged {
            configurationApplied = await store.resetExternalEnrichment(
                scanGeneration: scanGeneration
            )
        } else {
            configurationApplied = true
        }
        if configurationApplied {
            await store.setMeta(
                "library_configuration",
                classificationFingerprint,
                scanGeneration: scanGeneration
            )
            await store.setLibraryAnimeContext(
                libraryConfiguration?.usesAnimeMetadata == true,
                scanGeneration: scanGeneration
            )
        }
        // One-time reread after an NFO PARSER-RULE upgrade (root-gated episode fields,
        // strict date rejection): mark already-processed sidecars whose stored
        // parser_version predates the current parser as pending so the local enricher
        // reparses each existing NFO once under the corrected rules. The UPDATE is
        // table-wide and idempotent; a meta gate keeps it to one pass per bump. Never
        // touches external/local-materialization version or forces a resolver call.
        let nfoParserCurrent = String(ShareNFOParser.parserVersion)
        if await store.meta("nfo_parser_version") != nfoParserCurrent {
            await store.markSidecarsPendingForParserUpgrade()
            await store.setMeta("nfo_parser_version", nfoParserCurrent, scanGeneration: scanGeneration)
        }
        // Only a pass that altered the catalog is worth telling anyone about; a
        // clean no-op pass must not cause any UI work.
        if !unchangedPass, !anyListingFailed {
            reporter.scanChangedCatalog(shareID)
        }
        // Catalog truth, independent of which directories this pass listed.
        let discovery = await store.assetDiscoveryStats(newerThan: 3600)
        let failureSummary = listFailureCounts.isEmpty
            ? "none"
            : listFailureCounts
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue):\($0.value)" }
                .joined(separator: ",")
        PlozzLog.boot(
            "share.scan done scanID=\(scanID) deep=\(deep) dirs=\(dirsWalked) skipped=\(dirsSkipped) storeMs=\(storeNanos / 1_000_000) skipStoreMs=\(skipStoreNanos / 1_000_000) listWaitMs=\(listWaitNanos / 1_000_000) interior=\(directoriesWithSubdirectories.count) files=\(filesFound) extras=\(extrasFound) catalog=\(discovery.total) newLastHour=\(discovery.recent) unchanged=\(unchangedPass) pruned=\(!anyListingFailed) failed=\(listFailureCounts.values.reduce(0, +)) failures=[\(failureSummary)] elapsed=\(Int(Date().timeIntervalSince(started) * 1_000))ms"
        )
        activeResumeState = nil
        await finishScan(listers: pool, completed: true)
        // A completed pass earns a completion stamp. When some listing failed the pass
        // stayed unpruned (partial), but it is still a *completed* pass under the
        // approved partial throttle — the coordinator distinguishes this from a
        // cancelled/superseded pass via the explicit outcome.
        return anyListingFailed ? .completedPartial : .completedClean
    }

    private func finishScan(listers: [ScanLister], completed: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for lister in listers {
                group.addTask {
                    await lister.close()
                }
            }
        }
        activeListers = []
        activeResumeState = nil
        activeListerGeneration = nil
        isRunning = false
        if completed, !Task.isCancelled, !isInvalidated {
            reporter.scanFinished(shareID)
        } else {
            reporter.scanPaused(shareID)
        }
    }

    /// Result of listing one directory: the connection it used (returned to the
    /// pool), the sub-directories discovered, the playable assets parsed, the NFO
    /// sidecar candidates discovered (pure filename/sibling-stem facts — no read),
    /// and whether the listing actually succeeded (a failed listing must not let
    /// the walk treat the folder as "empty" and prune its still-present content).
    /// A subdirectory seen in a listing, with the mtime used to decide whether it
    /// needs listing on the next scan.
    struct ScannedSubdirectory: Sendable {
        let frontier: FrontierEntry
        let modifiedAt: Date?
    }

    struct DirResult: Sendable {
        let lister: ScanLister
        let dir: String
        let subdirectories: [ScannedSubdirectory]
        /// Every supported playable file observed in this successful listing,
        /// including samples, extras, and files intentionally left unclassified.
        let playablePaths: [String]
        let assets: [CatalogAsset]
        let extras: [CatalogExtraCandidate]
        let sidecars: [LocalSidecarCandidate]
        let artwork: [LocalArtworkCandidate]
        let ok: Bool
        /// Set only when `ok == false`: a bounded, PATH-FREE classification of the
        /// listing failure for aggregate diagnostics (never the directory, basename,
        /// or the error's localized description, which can embed a share path).
        var failureCategory: ShareScanListFailureCategory?
    }

    /// List + classify one directory off the actor (pure I/O + parsing, no shared
    /// state), so the pooled listings run truly in parallel. A per-directory error
    /// is swallowed to an empty result (so one bad folder never aborts the walk) but
    /// is flagged `ok: false` so the caller can skip the global prune.
    static func processDirectory(
        _ frontier: FrontierEntry,
        using lister: ScanLister,
        libraryConfiguration: MediaShareLibraryConfiguration? = nil
    ) async -> DirResult {
        let dir = frontier.relPath
        let entries: [RemoteFileEntry]
        do {
            ShareBackgroundActivity.listStarted()
            defer { ShareBackgroundActivity.listFinished() }
            entries = try await lister.list(dir)
        } catch {
            return DirResult(
                lister: lister, dir: dir, subdirectories: [], playablePaths: [],
                assets: [], extras: [],
                sidecars: [], artwork: [], ok: false,
                failureCategory: ShareScanListFailureCategory(error)
            )
        }
        if let traversal = frontier.extraTraversal {
            return processExtraDirectory(
                dir,
                traversal: traversal,
                entries: entries,
                lister: lister
            )
        }

        var subdirs: [ScannedSubdirectory] = []
        var playablePaths: [String] = []
        var assets: [CatalogAsset] = []
        var extras: [CatalogExtraCandidate] = []
        var movieStemsLower: Set<String> = []
        var episodeStemsLower: Set<String> = []
        var stemToVideoRelPath: [String: String] = [:]
        var nfoEntries: [(entry: RemoteFileEntry, childPath: String)] = []
        var suffixVideos: [(
            entry: RemoteFileEntry,
            childPath: String,
            suffix: ShareExtraDiscoveryPolicy.TerminalSuffix
        )] = []

        for entry in entries {
            let childPath = dir.isEmpty ? entry.name : "\(dir)/\(entry.name)"
            if entry.kind != .directory, ShareMediaParser.isVideoFile(entry.name) {
                playablePaths.append(childPath)
            }
            if entry.kind != .directory,
               ShareMediaParser.isVideoFile(entry.name),
               isSampleFile(entry.name),
               ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: entry.name) == nil {
                continue
            } else if entry.kind != .directory,
               ShareMediaParser.isVideoFile(entry.name),
               let suffix = ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: entry.name) {
                suffixVideos.append((entry, childPath, suffix))
            } else if entry.kind != .directory, ShareMediaParser.isVideoFile(entry.name) {
                guard let parsed = asset(
                    relPath: childPath,
                    entry: entry,
                    libraryConfiguration: libraryConfiguration
                ) else {
                    continue
                }
                let stem = ShareExtraDiscoveryPolicy.stemIdentity(
                    ShareMediaParser.videoStem(entry.name)
                )
                switch parsed.kind {
                case .movie: movieStemsLower.insert(stem)
                case .episode: episodeStemsLower.insert(stem)
                }
                stemToVideoRelPath[stem] = childPath
                assets.append(parsed)
            } else if isNFOFile(entry.name) {
                nfoEntries.append((entry, childPath))
            }
        }

        let localOwnerFile = provenLocalOwnerFile(in: dir, assets: assets)
        for suffixVideo in suffixVideos where suffixVideo.entry.kind == .file {
            let exactOwnerFile = suffixVideo.suffix.baseStemIdentity.flatMap {
                stemToVideoRelPath[$0]
            }
            extras.append(CatalogExtraCandidate(
                relPath: suffixVideo.childPath,
                parentDir: dir,
                basename: suffixVideo.entry.name,
                size: suffixVideo.entry.size ?? 0,
                modifiedAt: suffixVideo.entry.modifiedAt ?? .distantPast,
                kind: suffixVideo.suffix.kind,
                title: ShareExtraDiscoveryPolicy.title(
                    forFileName: suffixVideo.entry.name,
                    fallbackKind: suffixVideo.suffix.kind
                ),
                ownerPath: dir,
                ownerFileRelPath: exactOwnerFile ?? localOwnerFile
            ))
        }

        for entry in entries where entry.kind == .directory {
            let childPath = dir.isEmpty ? entry.name : "\(dir)/\(entry.name)"
            if excludedDirs.contains(entry.name.lowercased()) { continue }
            if let folder = ShareExtraDiscoveryPolicy.folderKind(entry.name) {
                guard !dir.isEmpty else { continue }
                subdirs.append(ScannedSubdirectory(
                    frontier: FrontierEntry(
                        relPath: childPath,
                        extraTraversal: ShareExtraTraversal(
                            ownerPath: dir,
                            ownerFileRelPath: localOwnerFile,
                            defaultKind: folder.defaultKind,
                            permitsTypedChildren: folder.permitsTypedChildren
                        )
                    ),
                    modifiedAt: entry.modifiedAt
                ))
            } else {
                subdirs.append(ScannedSubdirectory(
                    frontier: FrontierEntry(relPath: childPath),
                    modifiedAt: entry.modifiedAt
                ))
            }
        }

        var sidecars: [LocalSidecarCandidate] = []
        for (entry, childPath) in nfoEntries {
            let lowerName = entry.name.lowercased()
            let kind: LocalSidecarKind
            var associatedVideo: String?
            if lowerName == "movie.nfo" {
                kind = .movieGeneric
            } else if lowerName == "tvshow.nfo" {
                kind = .series
            } else {
                let stem = ShareExtraDiscoveryPolicy.stemIdentity(
                    ShareMediaParser.videoStem(entry.name)
                )
                if movieStemsLower.contains(stem) {
                    kind = .movieStem
                    associatedVideo = stemToVideoRelPath[stem]
                } else if episodeStemsLower.contains(stem) {
                    kind = .episodeStem
                    associatedVideo = stemToVideoRelPath[stem]
                } else {
                    continue
                }
            }
            sidecars.append(LocalSidecarCandidate(
                relPath: childPath, parentDir: dir, basename: entry.name, kind: kind,
                size: entry.size ?? 0, modifiedAt: entry.modifiedAt ?? .distantPast,
                stableFileID: entry.stableFileID, strongETag: entry.strongETag,
                changeToken: entry.changeToken, associatedVideoRelPath: associatedVideo
            ))
        }

        let artwork = ShareArtworkInventoryPolicy.candidates(entries: entries, parentDir: dir)
        return DirResult(
            lister: lister, dir: dir, subdirectories: subdirs,
            playablePaths: playablePaths, assets: assets,
            extras: extras, sidecars: sidecars, artwork: artwork, ok: true
        )
    }

    private static func processExtraDirectory(
        _ dir: String,
        traversal: ShareExtraTraversal,
        entries: [RemoteFileEntry],
        lister: ScanLister
    ) -> DirResult {
        let extras = entries.compactMap { entry -> CatalogExtraCandidate? in
            guard entry.kind == .file, ShareMediaParser.isVideoFile(entry.name) else {
                return nil
            }
            let childPath = "\(dir)/\(entry.name)"
            let suffixKind = ShareExtraDiscoveryPolicy
                .terminalSuffix(inFileName: entry.name)?
                .kind
            let kind = traversal.defaultKind == .other
                ? (suffixKind ?? traversal.defaultKind)
                : traversal.defaultKind
            return CatalogExtraCandidate(
                relPath: childPath,
                parentDir: dir,
                basename: entry.name,
                size: entry.size ?? 0,
                modifiedAt: entry.modifiedAt ?? .distantPast,
                kind: kind,
                title: ShareExtraDiscoveryPolicy.title(
                    forFileName: entry.name,
                    fallbackKind: kind
                ),
                ownerPath: traversal.ownerPath,
                ownerFileRelPath: traversal.ownerFileRelPath
            )
        }

        var subdirectories: [ScannedSubdirectory] = []
        if traversal.permitsTypedChildren {
            for entry in entries where entry.kind == .directory {
                guard let folder = ShareExtraDiscoveryPolicy.folderKind(entry.name),
                      case .typed(let kind) = folder else { continue }
                subdirectories.append(ScannedSubdirectory(
                    frontier: FrontierEntry(
                        relPath: "\(dir)/\(entry.name)",
                        extraTraversal: ShareExtraTraversal(
                            ownerPath: traversal.ownerPath,
                            ownerFileRelPath: traversal.ownerFileRelPath,
                            defaultKind: kind,
                            permitsTypedChildren: false
                        )
                    ),
                    modifiedAt: entry.modifiedAt
                ))
            }
        }
        return DirResult(
            lister: lister, dir: dir, subdirectories: subdirectories,
            playablePaths: extras.map(\.relPath),
            assets: [], extras: extras, sidecars: [], artwork: [], ok: true
        )
    }

    static func provenLocalOwnerFile(
        in directory: String,
        assets: [CatalogAsset]
    ) -> String? {
        guard !directory.isEmpty, assets.count == 1, let asset = assets.first else {
            return nil
        }
        let folder = directory.split(separator: "/").last.map(String.init) ?? ""
        switch asset.kind {
        case .movie:
            guard let titleKey = asset.movieTitleKey else { return nil }
            guard ShareExtraDiscoveryPolicy.movieFolderProvesOwner(
                folder,
                titleKey: titleKey,
                year: asset.year
            ) else {
                return nil
            }
        case .episode:
            guard ShareMediaParser.seasonNumber(fromFolder: folder) == nil,
                  asset.metadataRoot != directory,
                  ShareExtraDiscoveryPolicy.stemIdentity(folder)
                    == ShareExtraDiscoveryPolicy.stemIdentity(
                        ShareMediaParser.videoStem(asset.basename)
                    ) else {
                return nil
            }
        }
        return asset.relPath
    }

    // MARK: - Interrupted-scan resume

    /// A partial walk's remaining work, persisted so an interruption costs only
    /// what was left rather than the whole share.
    private struct ResumeState: Codable {
        let scanID: Int64
        let frontier: [FrontierEntry]
        let deep: Bool
        let startedAt: TimeInterval
        let hasFailures: Bool?
    }

    private static let resumeCheckpointKey = "resume_checkpoint"

    /// How long a saved frontier stays usable. A resume reuses the interrupted
    /// pass's scanID, so its already-walked half is never revisited — if that half
    /// is days old it is better to re-walk from scratch than to prune against a
    /// stale picture of the share.
    private static let resumeMaxAge: TimeInterval = 6 * 60 * 60

    private static func loadResumeState(store: ShareCatalogStore, deep: Bool) async -> ResumeState? {
        // Legacy multi-key checkpoints had no depth/failure proof. Re-walk them
        // rather than carrying their potentially incomplete coverage forward.
        guard let json = await store.meta(resumeCheckpointKey),
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(ResumeState.self, from: data),
              !state.frontier.isEmpty,
              state.deep == deep,
              state.hasFailures != true
        else { return nil }
        let age = Date().timeIntervalSince1970 - state.startedAt
        guard age >= 0, age < resumeMaxAge else { return nil }
        return state
    }

    private static func saveResumeState(
        store: ShareCatalogStore,
        scanID: Int64,
        frontier: [FrontierEntry],
        scanGeneration: UUID?,
        deep: Bool,
        startedAt: TimeInterval,
        hasFailures: Bool
    ) async {
        guard let scanGeneration,
              let checkpoint = resumeCheckpoint(
                  scanID: scanID,
                  frontier: frontier,
                  scanGeneration: scanGeneration,
                  deep: deep,
                  startedAt: startedAt,
                  hasFailures: hasFailures
              )
        else {
            await clearResumeState(store: store, scanGeneration: scanGeneration)
            return
        }
        // One atomic value prevents a process death from pairing a new scan id
        // with an old frontier. A failure-bearing checkpoint deliberately replaces
        // any older clean checkpoint; `loadResumeState` rejects it and restarts at
        // the root, so a failed subtree cannot disappear from coverage.
        await store.setMeta(
            resumeCheckpointKey,
            checkpoint.resumeStateJSON ?? "",
            scanGeneration: scanGeneration
        )
    }

    private static func resumeCheckpoint(
        _ state: ActiveResumeState
    ) -> ShareScanResumeCheckpoint? {
        resumeCheckpoint(
            scanID: state.scanID,
            frontier: state.frontier,
            scanGeneration: state.scanGeneration,
            deep: state.deep,
            startedAt: state.startedAt,
            hasFailures: state.hasFailures
        )
    }

    private static func resumeCheckpoint(
        scanID: Int64,
        frontier: [FrontierEntry],
        scanGeneration: UUID,
        deep: Bool,
        startedAt: TimeInterval,
        hasFailures: Bool
    ) -> ShareScanResumeCheckpoint? {
        guard !frontier.isEmpty,
              let frontierData = try? JSONEncoder().encode(frontier),
              let frontierJSON = String(data: frontierData, encoding: .utf8),
              let stateData = try? JSONEncoder().encode(
                  ResumeState(
                      scanID: scanID,
                      frontier: frontier,
                      deep: deep,
                      startedAt: startedAt,
                      hasFailures: hasFailures
                  )
              ),
              let resumeStateJSON = String(data: stateData, encoding: .utf8) else {
            return nil
        }
        return ShareScanResumeCheckpoint(
            scanGeneration: scanGeneration,
            scanID: scanID,
            frontierJSON: frontierJSON,
            savedAt: startedAt,
            resumeStateJSON: resumeStateJSON
        )
    }

    static func decodeFrontier(_ data: Data) -> [FrontierEntry]? {
        if let current = try? JSONDecoder().decode([FrontierEntry].self, from: data) {
            return current
        }
        guard let legacy = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return legacy.map(FrontierEntry.legacy(relPath:))
    }

    private static func clearResumeState(store: ShareCatalogStore, scanGeneration: UUID?) async {
        for key in [resumeCheckpointKey, "resume_scan_id", "resume_frontier", "resume_saved_at"] {
            await store.setMeta(key, "", scanGeneration: scanGeneration)
        }
    }

    /// A supported NFO sidecar filename (any casing).
    private static func isNFOFile(_ name: String) -> Bool {
        (name as NSString).pathExtension.caseInsensitiveCompare("nfo") == .orderedSame
    }

    // MARK: - Parse one file into a catalog asset

    static func asset(relPath: String, entry: RemoteFileEntry) -> CatalogAsset {
        asset(
            relPath: relPath,
            entry: entry,
            libraryConfiguration: nil
        )!
    }

    static func asset(
        relPath: String,
        entry: RemoteFileEntry,
        libraryConfiguration: MediaShareLibraryConfiguration?
    ) -> CatalogAsset? {
        let name = entry.name
        let explicitIDs = ShareMediaParser.embeddedProviderIDs(relPath: relPath)
        guard let classification = ShareMediaParser.classify(
            relPath: relPath,
            configuration: libraryConfiguration
        ) else {
            return nil
        }
        switch classification {
        case .movie(let movie):
            let title = movie.title.isEmpty ? displayTitle(forFileName: name) : movie.title
            let g = ShareMediaParser.movieGrouping(relPath: relPath, parsedTitle: title, parsedYear: movie.year)
            var movieKey = ShareCatalogID.movieKey(fromTitle: g.title, year: g.year)
            var movieTitleKey = ShareCatalogID.seriesKey(fromTitle: g.title)
            if let part = g.part {
                movieKey += "-\(part)"
                movieTitleKey += "-\(part)"
            }
            return CatalogAsset(
                relPath: relPath, basename: name, size: entry.size ?? 0,
                modifiedAt: entry.modifiedAt ?? .distantPast, kind: .movie, library: .movies,
                title: g.title, year: g.year,
                seriesTitle: nil, seriesKey: nil, season: nil, episode: nil,
                movieKey: movieKey, movieTitleKey: movieTitleKey,
                explicitProviderIDs: explicitIDs, metadataRoot: nil
            )
        case .episode(let ep):
            let anime = libraryConfiguration?.contentType == .tvShows
                ? libraryConfiguration?.usesAnimeMetadata == true
                : libraryConfiguration?.usesAnimeMetadata == true || isAnimePath(relPath)
            let library: CatalogLibrary = anime ? .anime : .tv
            let fallback = "S\(ep.season)·E\(String(format: "%02d", ep.episode))"
            return CatalogAsset(
                relPath: relPath, basename: name, size: entry.size ?? 0,
                modifiedAt: entry.modifiedAt ?? .distantPast, kind: .episode, library: library,
                title: ep.title ?? fallback, year: ep.year,
                seriesTitle: ep.series,
                seriesKey: ShareCatalogID.seriesKey(fromTitle: ep.series, providerTag: ep.providerTag),
                season: ep.season, episode: ep.episode,
                movieKey: nil, movieTitleKey: nil,
                explicitProviderIDs: explicitIDs,
                metadataRoot: seriesMetadataRoot(
                    relPath: relPath,
                    libraryConfiguration: libraryConfiguration
                )
            )
        }
    }

    /// The authoritative SHOW FOLDER's full relative path (root-first ancestors
    /// joined up to and including the folder `ShareMediaParser.classify` proved
    /// names the series) — where a `tvshow.nfo` sidecar would live. `nil` when the
    /// folder tree doesn't prove a show folder (mirrors `authoritativeShowFolder`,
    /// so this stays consistent with which folder GROUPING already trusts).
    static func seriesMetadataRoot(
        relPath: String,
        libraryConfiguration: MediaShareLibraryConfiguration? = nil
    ) -> String? {
        let comps = relPath.split(separator: "/").map(String.init)
        guard comps.count > 1 else { return nil }
        let ancestors = Array(comps.dropLast())
        if let showFolder = ShareMediaParser.authoritativeShowFolder(fromAncestors: ancestors),
           let idx = ancestors.lastIndex(of: showFolder) {
            return ancestors[0...idx].joined(separator: "/")
        }
        guard libraryConfiguration?.contentType == .tvShows
                || libraryConfiguration?.contentType == .anime
                || (libraryConfiguration?.contentType == .automatic
                    && libraryConfiguration?.usesAnimeMetadata == true),
              let first = ancestors.first,
              !ShareMediaParser.isSeasonFolder(first) else {
            return nil
        }
        return first
    }

    // MARK: - Heuristics

    /// Best-effort anime detection at scan time: a path segment named "anime"
    /// (case-insensitive). Refined/corrected in Phase 2 once real ids resolve.
    static func isAnimePath(_ relPath: String) -> Bool {
        relPath.split(separator: "/").contains { seg in
            let s = seg.lowercased()
            return s == "anime" || s == "animes" || s == "anime tv" || s == "anime movies"
        }
    }

    /// A common `-sample`/`.sample` throwaway that shouldn't enter the library.
    static func isSampleFile(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        return stem == "sample" || stem.hasSuffix("-sample") || stem.hasSuffix(".sample") || stem.hasSuffix(" sample")
    }

    private var classificationFingerprint: String {
        guard let libraryConfiguration else { return "legacy" }
        return [
            libraryConfiguration.contentType.rawValue,
            libraryConfiguration.usesAnimeMetadata ? "anime" : "standard",
        ].joined(separator: ":")
    }

    private static func displayTitle(forFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    // MARK: - Scan id

}

/// Bounded scan admission control shared by interactive ShareProvider requests
/// and the background scanner. Recent navigation adds a small delay before each
/// replacement directory request; continuous navigation still makes guaranteed
/// progress because the delay is fixed rather than waiting for an idle window.
actor ShareScanPacer {
    private let activeWindow: Duration
    private let activeDelay: Duration
    private let clock = ContinuousClock()
    private var lastInteractiveActivity: ContinuousClock.Instant?

    init(activeWindow: Duration = .seconds(1), activeDelay: Duration = .milliseconds(60)) {
        self.activeWindow = activeWindow
        self.activeDelay = activeDelay
    }

    func noteInteractiveActivity() {
        lastInteractiveActivity = clock.now
    }

    @discardableResult
    func paceIfBrowsing() async -> Bool {
        guard let lastInteractiveActivity,
              lastInteractiveActivity.duration(to: clock.now) < activeWindow else { return false }
        try? await Task.sleep(for: activeDelay)
        return true
    }
}

/// Bounded, PATH-FREE classification of a directory-listing failure, used only for
/// aggregate scan diagnostics. The raw value is a fixed, library-structure-free token;
/// it is derived solely from the error's domain/code — never its localized description
/// (which can embed a share path/basename) and never any directory string.
enum ShareScanListFailureCategory: String, Sendable, CaseIterable {
    case timedOut
    case connectionLost
    case authFailed
    case permissionDenied
    case notFound
    case cancelled
    case other

    init(_ error: Error) {
        if let transport = error as? MediaTransportError {
            switch transport {
            case .timeout: self = .timedOut
            case .cancelled: self = .cancelled
            case .authentication: self = .authFailed
            case .permissionDenied: self = .permissionDenied
            case .transport(let code):
                self.init(NSError(
                    domain: code < 0 ? NSURLErrorDomain : NSPOSIXErrorDomain, code: code))
            default: self = .other
            }
            return
        }
        if error is CancellationError {
            self = .cancelled
            return
        }
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            self = .timedOut
        case (NSURLErrorDomain, NSURLErrorCancelled):
            self = .cancelled
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            self = .connectionLost
        case (NSURLErrorDomain, NSURLErrorUserAuthenticationRequired),
             (NSURLErrorDomain, NSURLErrorUserCancelledAuthentication):
            self = .authFailed
        case (NSURLErrorDomain, NSURLErrorNoPermissionsToReadFile):
            self = .permissionDenied
        case (NSURLErrorDomain, NSURLErrorFileDoesNotExist),
             (NSURLErrorDomain, NSURLErrorResourceUnavailable):
            self = .notFound
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
             (NSCocoaErrorDomain, NSFileWriteNoPermissionError):
            self = .permissionDenied
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError):
            self = .notFound
        case (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)):
            self = .permissionDenied
        case (NSPOSIXErrorDomain, Int(ENOENT)):
            self = .notFound
        case (NSPOSIXErrorDomain, Int(ETIMEDOUT)):
            self = .timedOut
        case (NSPOSIXErrorDomain, Int(ECONNRESET)),
             (NSPOSIXErrorDomain, Int(ECONNREFUSED)),
             (NSPOSIXErrorDomain, Int(ENOTCONN)),
             (NSPOSIXErrorDomain, Int(EHOSTUNREACH)),
             (NSPOSIXErrorDomain, Int(ENETUNREACH)),
             (NSPOSIXErrorDomain, Int(ENETDOWN)):
            self = .connectionLost
        default:
            self = .other
        }
    }
}
