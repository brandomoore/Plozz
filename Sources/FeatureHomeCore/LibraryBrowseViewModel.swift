import Foundation
import Observation
import CoreModels
import CoreNetworking

public enum LibraryContentMode: String, CaseIterable, Sendable {
    case titles
    case collections

    public var displayName: LocalizedStringResource {
        switch self {
        case .titles: "Titles"
        case .collections: "Collections"
        }
    }
}

public enum LibraryBrowseScope: String, Hashable, Sendable {
    case library
    case collectionMembers
}

/// Drives a *sparse* library grid: it loads the first page to learn the
/// library's total size, then lazily fetches each further page only when a cell
/// that belongs to it scrolls into view. The grid is sized to the full
/// `totalCount` up front (so the scroll bar reflects the whole library and tiles
/// render as placeholders until their page arrives), which keeps libraries with
/// hundreds or thousands of items fast and memory-light — only on-screen pages
/// are ever requested or held.
@MainActor
@Observable
public final class LibraryBrowseViewModel {
    /// State of the *first* page load, whose value is the library's total item
    /// count. Once loaded, individual pages fill in behind the scenes via
    /// `loaded` without disturbing this state, so a late page failure never
    /// wipes the grid.
    public private(set) var state: LoadState<Int> = .idle

    /// Sparse, index-addressed backing store sized to `totalCount`. A `nil`
    /// slot is a not-yet-loaded item that renders as a placeholder tile.
    ///
    /// Each slot is a small `@Observable` reference (``LibrarySlot``) rather than a
    /// bare `MediaItem?` so that filling one page mutates only *those* slots'
    /// `.item` — re-rendering just those cells — instead of touching this array
    /// property and invalidating **every** visible cell that read it. With a fast
    /// SMB library paging in every few milliseconds, whole-array observation churn
    /// was re-diffing the entire visible grid on each page fill (the scroll
    /// choppiness); per-slot observation confines each fill to its own cells. The
    /// array itself is sized once to the library total and never reassigned during
    /// paging, so reading it to subscript never registers a firing dependency.
    public private(set) var loaded: [LibrarySlot] = []
    /// Total items reported by the server (0 until the first page loads).
    public private(set) var totalCount: Int = 0
    /// A non-fatal error from loading a follow-up page, if any. Surfaced for
    /// diagnostics; the failed page is retried when its cells reappear.
    public private(set) var pageError: AppError?
    public private(set) var contentMode: LibraryContentMode = .titles

    public var supportsCollections: Bool {
        browseScope == .library && (containerKind == .movie || containerKind == .series)
            && (provider as? any CapabilityReporting)?.capabilities.contains(.libraryCollections) == true
    }

    /// Invalidates cells only when replacing the browsing destination/order.
    /// Background catalog refreshes retain this generation and existing slots.
    public private(set) var contentGeneration = 0

    public var emptyMessage: LocalizedStringResource {
        if browseScope == .collectionMembers { return "This collection is empty." }
        return contentMode == .collections ? "No collections in this library." : "This library is empty."
    }

    private let provider: any MediaProvider
    private let containerID: String
    private let containerKind: MediaItemKind
    public let browseScope: LibraryBrowseScope
    private let firstPageSize: Int
    private let subsequentPageSize: Int
    private let defaults: UserDefaults
    /// The account this library belongs to, stamped onto every emitted item so a
    /// tapped grid cell routes to the right provider. `nil` outside aggregated flows.
    private let sourceAccountID: String?

    /// The order the grid is currently sorted by. Changing it via `setSort`
    /// restarts paging from the first page and persists the choice per container
    /// kind so it is restored next time a library of that kind is opened.
    public private(set) var sort: CoreModels.SortDescriptor

    /// The A–Z fast-scroll rail's jump targets: for each present letter, the
    /// grid index of its first item in the current sort. Populated (once, off the
    /// first page) only when sorting by **name** and the library is big enough to
    /// be worth an index; empty for every other sort, so the rail simply hides.
    public let alphabet = LibraryAlphabetState()
    public var letterEntries: [LibraryLetterIndexEntry] { alphabet.entries }

    /// Whether the trailing alphabet rail should be shown — true only when a
    /// name-sort letter index resolved with at least a couple of letters.
    public var showsLetterRail: Bool { letterEntries.count > 1 }
    /// Scan-completion refresh is relevant only to the device-local SMB catalog.
    public var isMediaShare: Bool { provider.kind == .mediaShare }
    /// Stable share id used to select this grid's status from ShareScanStatusModel.
    public var sourceServerID: String { provider.session.server.id }

    public var availableSortFields: [SortField] {
        if browseScope == .collectionMembers { return [] }
        if browseKind == .collection { return [.name, .dateAdded] }
        return (provider as? any MediaSortFieldProviding)?
            .supportedSortFields(in: containerID, kind: containerKind)
            ?? SortField.allCases
    }

    private var browseKind: MediaItemKind {
        contentMode == .collections ? .collection : containerKind
    }

    private var currentSortKeySuffix: String? {
        contentMode == .collections ? nil : sortKeySuffix
    }

    public var fileBrowserLibrary: MediaLibrary? {
        guard browseScope == .library else { return nil }
        guard let browser = provider as? any MediaFileBrowsing else { return nil }
        var library = browser.fileBrowserLibrary
        guard library.id != containerID else { return nil }
        if let accountID = sourceAccountID ?? library.sourceAccountID {
            library.sourceAccountID = accountID
            library.sourceContainerIDByAccount[accountID] = library.id
        }
        return library
    }

    /// Below this library size the alphabet rail isn't worth showing (a short
    /// list scrolls fine on its own) or the round-trips to build it.
    private static let minItemsForLetterRail = 2

    /// In-flight letter-index build, cancelled when the sort changes or the grid
    /// reloads so a stale index never lands over a new sort.
    private var letterIndexTask: Task<Void, Never>?

    /// Page indices whose load is in flight — guards against duplicate requests
    /// for the same page when several of its cells appear at once.
    private var pagesInFlight: Set<Int> = []
    /// Page indices that have been fully loaded.
    private var pagesLoaded: Set<Int> = []
    private var failedPages: Set<Int> = []
    /// Page load tasks keyed by page index. Coalesces concurrent requests for a
    /// page and lets stale/off-screen prefetches be cancelled.
    private var pageTasks: [Int: Task<Void, Never>] = [:]
    private var pageRequestIDs: [Int: UUID] = [:]
    /// Visible-cell reference count per page. Used to keep visible-page loads alive
    /// while allowing off-screen page loads to be cancelled.
    private var visibleCellCountsByPage: [Int: Int] = [:]
    /// Tracks the currently visible indices so repeated `.task(id:)` restarts for
    /// the same cell don't inflate `visibleCellCountsByPage`. Kept out of
    /// observation: it mutates on every cell appear/disappear (dozens of times a
    /// second while scrolling), and the only thing the UI cares about — the
    /// top-most visible index — is published separately via `topVisibleIndex`, so
    /// observing this raw set would needlessly churn the alphabet rail.
    @ObservationIgnored private var visibleIndices: Set<Int> = []
    /// Last index whose cell appeared. Large jumps imply a fast scroll and trigger
    /// deeper look-ahead prefetching.
    private var lastAppearedIndex: Int?
    /// Request token for first-page loads and background refreshes, separate from
    /// the still-visible grid's generation. A rapid sort toggle (or a
    /// container change) can leave two first-page loads in flight on a slow/large
    /// library; each runs as its own unstructured `Task`, so neither cancels the
    /// other. Capturing the generation at request time and re-checking it after the
    /// network round-trip guarantees only the newest load applies its results —
    /// otherwise an older response could paint stale-sorted items over the grid.
    @ObservationIgnored private var loadGeneration = 0

    /// Distinguishes this grid's remembered sort from other grids of the same kind.
    ///
    /// Sort is remembered per *kind* so every movie library opens the way the
    /// viewer last left one. The combined "All Libraries" grid isn't a kind, so it
    /// passes a suffix and gets its own remembered sort instead of silently
    /// sharing (and overwriting) the `.unknown` bucket.
    private let sortKeySuffix: String?

    public init(
        provider: any MediaProvider,
        containerID: String,
        containerKind: MediaItemKind,
        pageSize: Int = PageRequest.defaultLimit,
        defaults: UserDefaults = .standard,
        sortKeySuffix: String? = nil,
        sourceAccountID: String? = nil,
        browseScope: LibraryBrowseScope = .library
    ) {
        self.provider = provider
        self.containerID = containerID
        self.containerKind = containerKind
        self.browseScope = browseScope
        let tuned = Self.tunedPageSizes(for: pageSize)
        self.firstPageSize = tuned.first
        self.subsequentPageSize = tuned.subsequent
        self.defaults = defaults
        self.sortKeySuffix = sortKeySuffix
        self.sourceAccountID = sourceAccountID
        self.sort = browseScope == .collectionMembers
            ? .default
            : Self.loadSort(for: containerKind, suffix: sortKeySuffix, from: defaults)
        if !availableSortFields.contains(sort.field) {
            let field = availableSortFields.first ?? .name
            self.sort = CoreModels.SortDescriptor(field: field, direction: field.defaultDirection)
        }
    }

    /// The item at `index`, or `nil` if it hasn't been loaded yet (placeholder).
    public func item(at index: Int) -> MediaItem? {
        guard index >= 0, index < loaded.count else { return nil }
        return loaded[index].item
    }

    /// The observable slot backing `index`, or `nil` when out of range. The grid
    /// passes this into a per-cell view that observes only `slot.item`, so filling
    /// one slot re-renders just that cell. Reading `loaded` here registers a
    /// dependency on the (paging-stable) array, not on any slot's contents.
    public func slot(at index: Int) -> LibrarySlot? {
        guard index >= 0, index < loaded.count else { return nil }
        return loaded[index]
    }

    /// Number of items actually loaded so far (non-placeholder). Test/diagnostic.
    public var loadedCount: Int { loaded.reduce(0) { $0 + ($1.item == nil ? 0 : 1) } }

    /// Called when a cell leaves the visible viewport. Used to cancel stale,
    /// off-screen page loads so bandwidth/CPU goes to visible content.
    public func itemDisappeared(at index: Int, generation: Int? = nil) {
        guard index >= 0, generation == nil || generation == contentGeneration else { return }
        let page = pageForIndex(index)
        guard visibleIndices.remove(index) != nil else { return }
        updateTopVisibleIndex()
        let remaining = max(0, (visibleCellCountsByPage[page] ?? 0) - 1)
        if remaining == 0 {
            visibleCellCountsByPage[page] = nil
            if !pagesLoaded.contains(page) {
                cancelPageLoad(page)
            }
        } else {
            visibleCellCountsByPage[page] = remaining
        }
        let centerPage = lastAppearedIndex.map(pageForIndex) ?? page
        pruneInFlightPages(around: centerPage, lookAhead: 1)
    }

    /// Loads the first page unless this model already holds one.
    ///
    /// SwiftUI cancels a `.task` when its view is covered by a push and runs it
    /// again when the view reappears, so a grid's `.task` fires every time the
    /// user comes back from a detail page. Calling ``loadFirstPage()`` there
    /// re-entered `.loading` and cleared `loaded`, which swapped the whole grid
    /// for a spinner — destroying the `ScrollView` and returning the user to the
    /// top of a library they had scrolled deep into. Reappearing is not a reason
    /// to refetch; a genuine refresh has its own entry points
    /// (``loadFirstPage()`` for pull-to-refresh or a sort change, and
    /// ``refreshAfterCatalogChange()`` after a scan).
    public func loadFirstPageIfNeeded() async {
        switch state {
        case .loaded:
            // Already showing this library. Keep the presentation, and with it the
            // scroll position, exactly as the user left it.
            return
        case .idle, .loading, .empty, .failed:
            // An empty or failed library keeps retrying on reappear: there is no
            // scroll position or content to lose, and a bounce out and back is a
            // reasonable way for the user to ask again. This matches what the tvOS
            // grid already did inline.
            await loadFirstPage()
        }
    }

    /// Loads (or reloads) the first page and sizes the grid to the full library.
    public func loadFirstPage() async {
        loadGeneration += 1
        contentGeneration += 1
        let generation = loadGeneration
        let mode = contentMode
        let request = pageRequest(forPage: 0)
        state = .loading
        loaded = []
        totalCount = 0
        pageError = nil
        cancelAllPageLoads()
        pagesInFlight = []
        pagesLoaded = []
        failedPages = []
        visibleCellCountsByPage = [:]
        visibleIndices = []
        topVisibleIndex = nil
        reportedViewportIndex = nil
        lastAppearedIndex = nil
        letterIndexTask?.cancel()
        alphabet.reset()
        await noteInteractiveBrowseActivity()
        guard !Task.isCancelled, generation == loadGeneration else { return }
        PlozzLog.app.info(
            "LibraryBrowse: loading first page for \(containerID) (\(containerKind.rawValue)) firstPage=\(firstPageSize) steadyPage=\(subsequentPageSize)"
        )
        do {
            let page = try await Self.fetchPage(
                provider: provider,
                containerID: containerID,
                containerKind: containerKind,
                browseScope: browseScope,
                contentMode: mode,
                request: request,
                priority: .userInitiated
            )
            guard !Task.isCancelled, generation == loadGeneration else { return }
            totalCount = page.totalCount
            loaded = Self.makeSlots(count: page.totalCount)
            fill(page)
            pagesLoaded.insert(0)
            state = page.totalCount == 0 ? .empty : .loaded(page.totalCount)
            loadLetterIndexIfNeeded()
        } catch is CancellationError {
            return
        } catch let error as AppError {
            PlozzLog.app.error("LibraryBrowse: first page failed for \(containerID): \(String(describing: error))")
            guard !Task.isCancelled, generation == loadGeneration else { return }
            state = .failed(error)
        } catch {
            PlozzLog.app.error("LibraryBrowse: first page failed for \(containerID): \(String(describing: error))")
            guard !Task.isCancelled, generation == loadGeneration else { return }
            state = .failed(.unknown(""))
        }
    }

    /// Silently replace stale sparse pages after an SMB catalog scan completes.
    /// Unlike `loadFirstPage`, this keeps the current loaded/empty presentation
    /// until the fresh first page arrives, avoiding a full-screen loading flash.
    /// Resetting `pagesLoaded` ensures any currently-visible deeper page refetches
    /// against the new catalog instead of retaining pre-scan cards.
    public func refreshAfterCatalogChange() async {
        switch state {
        case .idle, .loading: return
        case .loaded, .empty, .failed: break
        }
        loadGeneration += 1
        let generation = loadGeneration
        let mode = contentMode
        let sortAtRequest = sort
        do {
            let firstPage = try await Self.fetchPage(
                provider: provider,
                containerID: containerID,
                containerKind: containerKind,
                browseScope: browseScope,
                contentMode: mode,
                request: pageRequest(forPage: 0),
                priority: .userInitiated
            )
            guard !Task.isCancelled, generation == loadGeneration else { return }
            var refreshed: [Int: MediaPage] = [0: firstPage]
            // The viewport can move while the refresh awaits a page. Include the
            // latest visible pages before committing so focused slots stay loaded.
            while let pageIndex = Set(visibleIndices.map(pageForIndex))
                .subtracting(refreshed.keys)
                .filter({ startIndex(forPage: $0) < firstPage.totalCount })
                .min() {
                let page = try await Self.fetchPage(
                    provider: provider,
                    containerID: containerID,
                    containerKind: containerKind,
                    browseScope: browseScope,
                    contentMode: mode,
                    request: PageRequest(
                        startIndex: startIndex(forPage: pageIndex),
                        limit: pageSpan(forPage: pageIndex),
                        sort: sortAtRequest
                    ),
                    priority: .userInitiated
                )
                guard !Task.isCancelled, generation == loadGeneration else { return }
                refreshed[pageIndex] = page
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            cancelAllPageLoads()
            pagesInFlight = []
            pagesLoaded = []
            failedPages = []
            pageError = nil
            totalCount = firstPage.totalCount
            resize(to: firstPage.totalCount)
            // Native cells observe these objects directly. Replacing the array
            // with new boxes would strand them on the previous catalog snapshot.
            let refreshedIndices = Set(refreshed.values.flatMap { page in
                page.startIndex..<(page.startIndex + page.items.count)
            })
            for (index, slot) in loaded.enumerated() where !refreshedIndices.contains(index) {
                slot.item = nil
            }
            for (index, page) in refreshed.sorted(by: { $0.key < $1.key }) {
                fill(page)
                pagesLoaded.insert(index)
            }
            state = firstPage.totalCount == 0 ? .empty : .loaded(firstPage.totalCount)
            letterIndexTask?.cancel()
            alphabet.reset()
            loadLetterIndexIfNeeded()
        } catch {
            // Keep the still-usable old page on a transient refresh failure; normal
            // page/retry behavior remains available.
            PlozzLog.app.error(
                "LibraryBrowse: catalog refresh failed for \(containerID): \(String(describing: error))"
            )
        }
    }

    /// Applies the app's provider-neutral watch-state mutation directly to loaded
    /// slots. Plex, Jellyfin, SMB, and future share transports all use this path, so
    /// badges and progress bars update immediately without a provider refetch.
    public func applyWatchedState(_ mutation: MediaItemMutation) {
        for slot in loaded {
            guard let item = slot.item else { continue }
            let updated = mutation.applied(to: item)
            if updated != item {
                slot.item = updated
            }
        }
    }

    /// Builds the alphabet fast-scroll index in the background when the grid is
    /// sorted by name and large enough to warrant it. The provider returns an
    /// empty index for any other sort (or when it can't compute one), so the
    /// rail stays hidden. Runs once per browse session — cheap for Plex (one
    /// facet request), a bounded concurrent count fan-out for Jellyfin — and is
    /// cancelled if the sort changes before it lands.
    private func loadLetterIndexIfNeeded() {
        letterIndexTask?.cancel()
        // A library's title-letter offsets do not describe its scoped collections.
        guard browseScope == .library, contentMode == .titles,
              sort.field == .name, totalCount >= Self.minItemsForLetterRail else {
            alphabet.reset()
            return
        }
        alphabet.isLoading = true
        alphabet.message = nil
        let sortAtRequest = sort
        let generation = contentGeneration
        letterIndexTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.provider.letterIndex(
                    in: self.containerID, kind: self.containerKind, sort: sortAtRequest)
                guard !Task.isCancelled, generation == self.contentGeneration,
                      sortAtRequest == self.sort else { return }
                guard Set(entries.map(\.letter)).count == entries.count,
                      entries.allSatisfy({ $0.startIndex.map { $0 >= 0 && $0 < self.totalCount } ?? true }) else {
                    throw AppError.invalidResponse
                }
                self.alphabet.entries = entries
                self.alphabet.isLoading = false
                self.updateAlphabetPosition()
            } catch {
                guard !Task.isCancelled, generation == self.contentGeneration, sortAtRequest == self.sort else { return }
                PlozzLog.app.error("Library alphabet index failed: \(String(describing: error))")
                self.alphabet.isLoading = false
                self.alphabet.message = "Couldn't load the alphabet index. Try again."
            }
        }
    }

    public func retryLetterIndex() { loadLetterIndexIfNeeded() }

    public func cancelLetterJump() {
        if let page = alphabet.landingPage, (visibleCellCountsByPage[page] ?? 0) == 0 {
            cancelPageLoad(page)
        }
        alphabet.cancelJump()
    }

    public func jumpToLetter(_ letter: String, focusesItem: Bool = true) async -> Int? {
        guard let entry = letterEntries.first(where: { $0.letter == letter }) else { return nil }
        alphabet.focusesItem = focusesItem
        if alphabet.jumpingTo == letter, let task = alphabet.jumpTask { return await task.value }
        cancelLetterJump()
        let id = alphabet.jumpID
        let generation = contentGeneration
        let requestedSort = sort
        alphabet.jumpingTo = letter
        alphabet.message = nil
        let task = Task<Int?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                if self.alphabet.jumpID == id {
                    self.alphabet.jumpingTo = nil
                    self.alphabet.jumpTask = nil
                    self.alphabet.landingPage = nil
                }
            }
            do {
                let index: Int?
                if let known = entry.startIndex { index = known }
                else {
                    index = try await self.provider.letterPosition(
                        in: self.containerID, kind: self.containerKind, letter: letter, sort: requestedSort)
                }
                guard !Task.isCancelled, self.alphabet.jumpID == id,
                      self.contentGeneration == generation, self.sort == requestedSort else { return nil }
                guard let index else {
                    self.alphabet.message = "No titles under \(letter) in this library."
                    return nil
                }
                guard index >= 0, index < self.totalCount else { throw AppError.conflict }
                let page = self.pageForIndex(index)
                self.alphabet.landingPage = page
                // Deferred resolution may have reconciled a merged cache since
                // this slot was last viewed. Fetch its current landing window.
                if entry.startIndex == nil { self.pagesLoaded.remove(page) }
                if let load = self.startPageLoadIfNeeded(page, priority: .userInitiated) {
                    await load.value
                }
                guard !Task.isCancelled, self.alphabet.jumpID == id,
                      self.contentGeneration == generation, self.sort == requestedSort else { return nil }
                guard self.pagesLoaded.contains(page), self.item(at: index) != nil else {
                    throw AppError.serverUnreachable
                }
                self.prepareJump(toIndex: index)
                self.alphabet.destination = LibraryAlphabetDestination(
                    index: index, focusesItem: self.alphabet.focusesItem)
                return index
            } catch {
                guard !Task.isCancelled, self.alphabet.jumpID == id else { return nil }
                PlozzLog.app.error("Library alphabet jump failed: \(String(describing: error))")
                self.alphabet.message = "Couldn't jump to \(letter). Try again."
                return nil
            }
        }
        alphabet.jumpTask = task
        return await task.value
    }

    /// The rail letter whose range currently contains `index` — the last entry
    /// whose `startIndex` is `<= index`. Drives the "you are here" highlight as
    /// the grid scrolls. `nil` when there is no index or `index` precedes the
    /// first entry.
    public func letter(forIndex index: Int) -> String? {
        var match: String?
        if letterEntries.contains(where: { $0.startIndex == nil }) {
            return item(at: index).map { MediaItemSortOrder.alphabetBucket(for: $0) }
        }
        for entry in letterEntries {
            guard let start = entry.startIndex else { continue }
            if start <= index { match = entry.letter } else { break }
        }
        return match
    }

    private func updateAlphabetPosition() {
        guard !letterEntries.isEmpty else { return }
        alphabet.updatePosition(letter(forIndex: topVisibleIndex ?? 0))
    }

    /// The top-most currently-visible grid index (smallest visible index), used
    /// to keep the rail's current-letter highlight in sync with a manual scroll.
    /// Stored — not computed off `visibleIndices` — so the alphabet rail (its only
    /// observer) re-renders solely when the top row crosses into a new index, not
    /// on every one of the dozens of cell appear/disappear ticks a scroll fires.
    /// Retains its last non-nil value while the grid momentarily recycles every
    /// visible cell, so the highlight doesn't flash back to the first letter
    /// mid-library.
    public private(set) var topVisibleIndex: Int?
    @ObservationIgnored private var reportedViewportIndex: Int?

    /// UIKit may retain an off-screen focused cell among its visible items.
    /// Native grids report their intersecting layout frames instead of that cache.
    public func reportViewport(firstIndex: Int, generation: Int) {
        guard generation == contentGeneration, firstIndex >= 0, firstIndex < totalCount else { return }
        reportedViewportIndex = firstIndex
        updateTopVisibleIndex()
    }

    public func clearReportedViewport() {
        reportedViewportIndex = nil
        updateTopVisibleIndex()
    }

    /// Recompute `topVisibleIndex` from the live visible set, publishing only a
    /// genuine change and never nil-ing out during a transient empty frame, so the
    /// rail highlight stays put and observers aren't churned needlessly.
    private func updateTopVisibleIndex() {
        guard let newTop = reportedViewportIndex ?? visibleIndices.min() else { return }
        if topVisibleIndex != newTop {
            topVisibleIndex = newTop
            updateAlphabetPosition()
        }
    }

    /// Called when the cell at `index` appears. Loads the page that owns `index`
    /// (and prefetches the next page when `index` is in the back half of its
    /// page) so content arrives just ahead of the user's scroll.
    public func itemAppeared(at index: Int, generation: Int? = nil) async {
        guard !Task.isCancelled, state.value != nil, index >= 0, index < totalCount,
              generation == nil || generation == contentGeneration else { return }
        let generation = contentGeneration
        let page = pageForIndex(index)
        if visibleIndices.insert(index).inserted {
            visibleCellCountsByPage[page, default: 0] += 1
            updateTopVisibleIndex()
        }
        await noteInteractiveBrowseActivity()
        guard !Task.isCancelled, generation == contentGeneration,
              visibleIndices.contains(index) else { return }
        await ensurePageLoaded(page)
        guard !Task.isCancelled, generation == contentGeneration else { return }
        let lookAhead = prefetchLookAheadPages(for: index, inPage: page)
        if lookAhead > 0 {
            for offset in 1...lookAhead {
                schedulePageLoad(page + offset)
            }
        }
        pruneInFlightPages(around: page, lookAhead: lookAhead)
        if visibleIndices.contains(index) { lastAppearedIndex = index }
    }

    private func ensurePageLoaded(_ page: Int) async {
        guard let task = startPageLoadIfNeeded(page) else { return }
        await task.value
    }

    private func schedulePageLoad(_ page: Int) {
        _ = startPageLoadIfNeeded(page)
    }

    /// Kicks off loading for the page a rail jump is about to land on — plus the
    /// following page, which covers the rest of the on-screen viewport after a
    /// `.top`-anchored jump — at interactive priority, *before* the scroll
    /// completes. Without this, a deep jump into a large library lands on
    /// non-focusable placeholder cells (pages only load once their cells appear),
    /// so moving focus into the grid can feel stuck until the round-trip finishes.
    /// The target's cells will re-await this same in-flight task when they appear,
    /// so there is no duplicate request; small libraries jump within the first
    /// (already-loaded) page, so this is effectively a no-op for them.
    public func prepareJump(toIndex index: Int) {
        guard index >= 0, index < totalCount else { return }
        let page = pageForIndex(index)
        _ = startPageLoadIfNeeded(page, priority: .userInitiated)
        _ = startPageLoadIfNeeded(page + 1, priority: .userInitiated)
    }

    /// Applies a new sort order: persists the choice and, if it actually changed,
    /// resets paging and reloads the first page so the grid re-sorts from the
    /// top rather than fetching the whole library at once.
    public func setSort(_ newSort: CoreModels.SortDescriptor) async {
        guard availableSortFields.contains(newSort.field), newSort != sort else { return }
        sort = newSort
        Self.saveSort(newSort, for: browseKind, suffix: currentSortKeySuffix, to: defaults)
        await loadFirstPage()
    }

    /// Mode belongs to this destination, not a global preference. Returning from
    /// detail keeps it; opening another library/account always starts with titles.
    public func setContentMode(_ newMode: LibraryContentMode) async {
        guard newMode != contentMode, newMode == .titles || supportsCollections else { return }
        contentMode = newMode
        let restoredSort = Self.loadSort(for: browseKind, suffix: currentSortKeySuffix, from: defaults)
        let field = availableSortFields.first ?? .name
        sort = availableSortFields.contains(restoredSort.field)
            ? restoredSort
            : CoreModels.SortDescriptor(field: field, direction: field.defaultDirection)
        await loadFirstPage()
    }

    public func retryFailedPages() async {
        let generation = contentGeneration
        for page in failedPages.sorted() {
            guard !Task.isCancelled, generation == contentGeneration else { return }
            await ensurePageLoaded(page)
        }
    }

    private static func defaultsKey(for kind: MediaItemKind, suffix: String?) -> String {
        guard let suffix else { return "LibraryBrowse.sort.\(kind.rawValue)" }
        return "LibraryBrowse.sort.\(suffix)"
    }

    private static func loadSort(
        for kind: MediaItemKind,
        suffix: String?,
        from defaults: UserDefaults
    ) -> CoreModels.SortDescriptor {
        guard
            let data = defaults.data(forKey: defaultsKey(for: kind, suffix: suffix)),
            let descriptor = try? JSONDecoder().decode(CoreModels.SortDescriptor.self, from: data)
        else { return .default }
        return descriptor
    }

    private static func saveSort(
        _ sort: CoreModels.SortDescriptor,
        for kind: MediaItemKind,
        suffix: String?,
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(sort) else { return }
        defaults.set(data, forKey: defaultsKey(for: kind, suffix: suffix))
    }

    /// Tuned paging plan for library browse. The default provider limit (60) is
    /// split into a small first page for near-instant first paint and a larger
    /// steady-state page size for efficient long-scroll throughput.
    static func tunedPageSizes(for requestedPageSize: Int) -> (first: Int, subsequent: Int) {
        let clamped = max(requestedPageSize, 1)
        guard clamped == PageRequest.defaultLimit else { return (clamped, clamped) }
        let first = min(clamped, 7 * 4)        // 4 visible rows in a 7-column grid.
        let subsequent = min(clamped, 7 * 6)   // 6-row steady-state balance.
        return (max(first, 1), max(subsequent, 1))
    }

    private func pageRequest(forPage page: Int) -> PageRequest {
        PageRequest(
            startIndex: startIndex(forPage: page),
            limit: pageSpan(forPage: page),
            sort: sort
        )
    }

    private func startIndex(forPage page: Int) -> Int {
        if page <= 0 { return 0 }
        return firstPageSize + (page - 1) * subsequentPageSize
    }

    private func pageSpan(forPage page: Int) -> Int {
        page <= 0 ? firstPageSize : subsequentPageSize
    }

    private func pageForIndex(_ index: Int) -> Int {
        guard index >= firstPageSize else { return 0 }
        return 1 + ((index - firstPageSize) / max(subsequentPageSize, 1))
    }

    private func maxLookAheadPages(fromPage page: Int) -> Int {
        guard totalCount > 0 else { return 0 }
        let lastPage = pageForIndex(totalCount - 1)
        return max(0, lastPage - page)
    }

    private func prefetchLookAheadPages(for index: Int, inPage page: Int) -> Int {
        let pageStart = startIndex(forPage: page)
        let pageLength = max(pageSpan(forPage: page), 1)
        let indexInPage = index - pageStart
        var lookAhead = indexInPage >= pageLength / 2 ? 1 : 0
        if let previous = lastAppearedIndex {
            let jump = abs(index - previous)
            if jump >= pageLength * 2 {
                lookAhead = max(lookAhead, 3)
            } else if jump >= pageLength {
                lookAhead = max(lookAhead, 2)
            }
        }
        return min(lookAhead, maxLookAheadPages(fromPage: page))
    }

    private func startPageLoadIfNeeded(_ page: Int, priority forcedPriority: TaskPriority? = nil) -> Task<Void, Never>? {
        guard page >= 0 else { return nil }
        let start = startIndex(forPage: page)
        guard start < totalCount else { return nil }
        guard !pagesLoaded.contains(page) else { return nil }
        if let existing = pageTasks[page] { return existing }

        pagesInFlight.insert(page)
        let request = pageRequest(forPage: page)
        let generation = contentGeneration
        let mode = contentMode
        let requestID = UUID()
        pageRequestIDs[page] = requestID
        let priority: TaskPriority = forcedPriority ?? ((visibleCellCountsByPage[page] ?? 0) > 0 ? .userInitiated : .utility)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPageLoad(
                page: page, request: request, priority: priority,
                mode: mode, generation: generation, requestID: requestID
            )
        }
        pageTasks[page] = task
        return task
    }

    private func performPageLoad(
        page: Int, request: PageRequest, priority: TaskPriority,
        mode: LibraryContentMode, generation: Int, requestID: UUID
    ) async {
        defer {
            if pageRequestIDs[page] == requestID { finishPageLoad(page) }
        }
        guard !Task.isCancelled, generation == contentGeneration else { return }
        do {
            let response = try await Self.fetchPage(
                provider: provider,
                containerID: containerID,
                containerKind: containerKind,
                browseScope: browseScope,
                contentMode: mode,
                request: request,
                priority: priority
            )
            guard !Task.isCancelled, generation == contentGeneration else { return }
            if response.totalCount != totalCount {
                totalCount = response.totalCount
                resize(to: response.totalCount)
                pagesLoaded = Set(pagesLoaded.filter { startIndex(forPage: $0) < response.totalCount })
                failedPages = Set(failedPages.filter { startIndex(forPage: $0) < response.totalCount })
                // Keep `state` (which drives the grid's rendered `0..<total` range)
                // in step with the corrected count — otherwise the grid keeps
                // rendering the old total, leaving new items unreachable or stale
                // placeholder slots behind.
                state = response.totalCount == 0 ? .empty : .loaded(response.totalCount)
            }
            fill(response)
            pagesLoaded.insert(page)
            failedPages.remove(page)
            if failedPages.isEmpty { pageError = nil }
            cancelOutOfRangeInFlightPages()
        } catch is CancellationError {
            return
        } catch let error as AppError {
            guard !Task.isCancelled, generation == contentGeneration else { return }
            PlozzLog.app.error("LibraryBrowse: page \(page) failed for \(containerID): \(String(describing: error))")
            failedPages.insert(page)
            pageError = error
        } catch {
            guard !Task.isCancelled, generation == contentGeneration else { return }
            PlozzLog.app.error("LibraryBrowse: page \(page) failed for \(containerID): \(String(describing: error))")
            failedPages.insert(page)
            pageError = .unknown("")
        }
    }

    private func finishPageLoad(_ page: Int) {
        pageTasks[page] = nil
        pageRequestIDs[page] = nil
        pagesInFlight.remove(page)
    }

    private func cancelPageLoad(_ page: Int) {
        guard !pagesLoaded.contains(page) else { return }
        if let task = pageTasks[page] {
            task.cancel()
            pageTasks[page] = nil
        }
        pageRequestIDs[page] = nil
        pagesInFlight.remove(page)
    }

    private func cancelAllPageLoads() {
        for task in pageTasks.values {
            task.cancel()
        }
        pageTasks = [:]
        pageRequestIDs = [:]
    }

    private func pruneInFlightPages(around page: Int, lookAhead: Int) {
        let minKeep = max(0, page - 1)
        let maxKeep = page + max(lookAhead, 1) + 1
        for candidate in Array(pageTasks.keys) {
            if candidate == alphabet.landingPage { continue }
            if (visibleCellCountsByPage[candidate] ?? 0) > 0 { continue }
            if candidate < minKeep || candidate > maxKeep {
                cancelPageLoad(candidate)
            }
        }
    }

    private func cancelOutOfRangeInFlightPages() {
        for page in Array(pageTasks.keys) where startIndex(forPage: page) >= totalCount {
            cancelPageLoad(page)
        }
    }

    private nonisolated static func fetchPage(
        provider: any MediaProvider,
        containerID: String,
        containerKind: MediaItemKind,
        browseScope: LibraryBrowseScope,
        contentMode: LibraryContentMode,
        request: PageRequest,
        priority: TaskPriority
    ) async throws -> MediaPage {
        let task = Task.detached(priority: priority) {
            if browseScope == .collectionMembers {
                return try await fetchCollectionMembers(
                    provider: provider, collectionID: containerID, request: request
                )
            }
            if contentMode == .collections {
                return try await provider.collections(in: containerID, page: request)
            }
            return try await provider.items(in: containerID, kind: containerKind, page: request)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Some servers cap membership pages below the requested sparse-grid span.
    /// Fill that span in server order rather than leaving its tail as permanent
    /// placeholders after marking the page loaded.
    private nonisolated static func fetchCollectionMembers(
        provider: any MediaProvider, collectionID: String, request: PageRequest
    ) async throws -> MediaPage {
        var items: [MediaItem] = []
        var totalCount: Int?
        while items.count < request.limit {
            try Task.checkCancellation()
            let start = request.startIndex + items.count
            if let totalCount, start >= totalCount { break }
            let page = try await provider.collectionMembers(
                of: collectionID,
                page: PageRequest(startIndex: start, limit: request.limit - items.count)
            )
            guard page.startIndex == start, page.totalCount >= 0,
                  page.items.count <= request.limit - items.count,
                  !page.items.isEmpty || start >= page.totalCount else {
                throw AppError.invalidResponse
            }
            totalCount = page.totalCount
            items.append(contentsOf: page.items)
            if page.items.isEmpty { break }
        }
        return MediaPage(items: items, startIndex: request.startIndex, totalCount: totalCount ?? 0)
    }

    /// Writes a fetched page's items into their absolute slots. Mutates each
    /// slot's `.item` (per-slot observation) rather than the `loaded` array, so a
    /// fill re-renders only the affected cells — not the whole visible grid.
    private func fill(_ page: MediaPage) {
        guard !page.items.isEmpty else { return }
        if loaded.count < page.startIndex + page.items.count {
            resize(to: page.startIndex + page.items.count)
        }
        for (offset, item) in page.items.enumerated() {
            loaded[page.startIndex + offset].item = tagged(item)
        }
        updateAlphabetPosition()
    }

    /// Stamps an item with this library's owning account (if any).
    private func tagged(_ item: MediaItem) -> MediaItem {
        guard let sourceAccountID else { return item }
        return item.taggingSource(sourceAccountID)
    }

    private func noteInteractiveBrowseActivity() async {
        guard let interactive = provider as? any InteractiveBrowseActivityReporting else { return }
        await interactive.noteInteractiveBrowseActivity()
    }

    /// A fresh array of `count` empty placeholder slots. Each is a distinct
    /// instance (never `Array(repeating:)`, which would share one slot across
    /// every index).
    private static func makeSlots(count: Int) -> [LibrarySlot] {
        guard count > 0 else { return [] }
        return (0..<count).map { _ in LibrarySlot() }
    }

    private func resize(to count: Int) {
        if count > loaded.count {
            loaded.append(contentsOf: Self.makeSlots(count: count - loaded.count))
        } else if count < loaded.count {
            loaded.removeLast(loaded.count - count)
            for index in visibleIndices.filter({ $0 >= count }) {
                itemDisappeared(at: index, generation: contentGeneration)
            }
        }
    }
}

/// One grid slot's contents: an `@Observable` box holding the loaded `MediaItem`
/// (or `nil` while it's still a placeholder). Boxing each slot separately means a
/// page fill mutates only the touched slots' `.item`, re-rendering just those
/// cells instead of every cell that read the parent `loaded` array. See
/// ``LibraryBrowseViewModel/loaded``.
@MainActor
@Observable
public final class LibrarySlot {
    public var item: MediaItem?
    public init(_ item: MediaItem? = nil) { self.item = item }
}
