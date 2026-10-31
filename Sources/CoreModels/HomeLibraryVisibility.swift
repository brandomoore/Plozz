import Foundation

/// A profile's **Home & library display preferences**: how libraries are laid out
/// on Home, which libraries are available at all, and which rows appear on Home.
///
/// Persisted as one per-profile value so it can be saved, broadcast, and rebuilt
/// on a profile switch in one place.
///
/// - `mergeLibrariesOnHome` — the all-or-nothing "merge every library's content
///   into unified cross-server rows" switch. `true` (the default) is the classic
///   behaviour; `false` lets each library contribute its own opt-in rows.
/// - `disabledKeys` — libraries turned **off** for discovery (Home, Search,
///   Music, browse), not account-wide viewing history. A video library that's on
///   shows on Home + search, a music library that's on shows in the Music tab.
/// - `disabledGlobalHomeRows` — the global Home rows (Continue Watching / Watchlist
///   / Recently Added) the user has turned **off** (opt-out; default all on). The
///   hero's on/off lives in `HeroSettings`, not here.
/// - `enabledLibraryHomeRows` — the per-library rows the user has **opted in** to
///   showing on Home in unmerged mode (default none, so Home stays lean). Keyed
///   `"<accountID>:<libraryID>:<rowKind>"`.
///
/// Library keys are `AggregatedLibrary.key` (`"accountID:libraryID"`).
///
/// ### Predicate vocabulary (read before touching callers)
/// - ``isEnabled(_:)`` — whether the library is on (`!disabledKeys`).
/// - ``isVisibleOnHome(_:)`` — whether it appears on Home. Now simply an alias
///   for ``isEnabled(_:)`` (an enabled video library is on Home; there is no
///   separate Home-only opt-out). ``isVisible(_:)`` is a further alias, kept so
///   existing Home rendering / aggregation callers stay unchanged.
/// Collection tiles also consult live library metadata: confirmed-empty directories
/// are automatically hidden unless the profile explicitly enables their library.
public struct HomeLibraryVisibility: Codable, Equatable, Sendable {
    /// Nil preserves an existing profile's legacy combined/grouped choices.
    public var rowCustomization: HomeRowCustomization?
    public var collectionSections: [CollectionSection]

    public var intent: Self {
        var copy = self
        copy.rowCustomization?.resolvedDefaults = nil
        return copy
    }

    public var usesIndividualHomeRows: Bool {
        rowCustomization != nil || !mergeLibrariesOnHome
    }

    public var separatesNextUp: Bool {
        guard !mergesNextUpRows else { return false }
        return (rowCustomization?.defaults == .matchServer
            && rowCustomization?.resolvedDefaults?.mode != .combined
            && rowCustomization?.availableServerRows.first {
                $0.section.kind == .continueWatching
            }?.section.includesNextUp != true)
            || rowCustomization?.defaults == .provider
            || rowCustomization?.shown.contains { $0.libraryKind == .nextUp } == true
    }

    /// On by default for every layout, independently of the saved row arrangement.
    public var mergeNextUpIntoContinueWatching: Bool
    public var hideWatchedRecentlyAdded: Bool

    public var mergesNextUpRows: Bool {
        mergeNextUpIntoContinueWatching && isGlobalRowEnabled(.continueWatching)
    }

    public func isMergedHomeRow(_ choice: HomeRowChoice) -> Bool {
        mergesNextUpRows
            && (choice.id.libraryKind == .nextUp || choice.serverRow?.section.kind == .nextUp)
    }

    /// Whether Home merges every library's content into unified cross-server rows
    /// (`true`, the classic behaviour) or lets each library contribute its own
    /// opt-in rows (`false`).
    public var mergeLibrariesOnHome: Bool

    /// Keys of libraries turned **off** — hidden from discovery on Home, Search, Music and
    /// browse alike.
    public var disabledKeys: Set<String>

    /// Explicit on choices override automatic hiding of empty collection directories.
    public var explicitlyEnabledKeys: Set<String>

    /// Raw values of the global Home rows the user has turned **off** (opt-out, so
    /// the default empty set = every global row on). See ``HomeGlobalRow``.
    public var disabledGlobalHomeRows: Set<String>

    /// Per-library rows the user has **opted in** to on Home (unmerged mode).
    /// Opt-in, so the default empty set keeps Home lean. Keys are
    /// `"<accountID>:<libraryID>:<rowKind>"` (see ``libraryRowKey(_:kind:)``).
    public var enabledLibraryHomeRows: Set<String>

    /// Whether the one-time per-library row seeding has already run (see
    /// ``seedLibraryRowsIfNeeded(_:)``). Tracked explicitly rather than inferred
    /// from `enabledLibraryHomeRows.isEmpty`, so a user who unmerges and then
    /// turns *every* per-library row off keeps that "nothing on Home" choice
    /// across a later merge on→off re-toggle instead of being re-seeded.
    public var hasSeededLibraryRows: Bool

    /// Whether the Continue Watching row identifies each card by its **show** —
    /// the show's wide artwork with its logo laid over it — rather than by the
    /// episode's own thumbnail. On by default.
    ///
    /// The row is one entry per show, so show-level art is what makes the cards
    /// tell each other apart at a glance; a grid of episode stills from shows you
    /// are mid-way through mostly reads as a row of similar rectangles. It is also
    /// spoiler-safe by construction — there is no episode frame on the card to
    /// hide — so with this on the row never masks and never blurs.
    ///
    /// In Landscape, turning it **off** restores the episode thumbnail and hands the row back to
    /// the spoiler settings, which blur or replace it as configured.
    public var continueWatchingShowsSeriesArtwork: Bool
    public var continueWatchingLayout: ContinueWatchingCardLayout
    public var continueWatchingPlaybackDetails: ContinueWatchingPlaybackDetails
    public var continueWatchingAction: ContinueWatchingAction

    public var continueWatchingUsesSeriesArtwork: Bool {
        continueWatchingLayout == .portrait || continueWatchingShowsSeriesArtwork
    }

    public init(
        mergeLibrariesOnHome: Bool = true,
        disabledKeys: Set<String> = [],
        explicitlyEnabledKeys: Set<String> = [],
        disabledGlobalHomeRows: Set<String> = [],
        enabledLibraryHomeRows: Set<String> = [],
        hasSeededLibraryRows: Bool = false,
        continueWatchingShowsSeriesArtwork: Bool = true,
        continueWatchingLayout: ContinueWatchingCardLayout = .landscape,
        continueWatchingPlaybackDetails: ContinueWatchingPlaybackDetails = .default,
        continueWatchingAction: ContinueWatchingAction = .default,
        rowCustomization: HomeRowCustomization? = nil,
        mergeNextUpIntoContinueWatching: Bool = true,
        collectionSections: [CollectionSection] = [],
        hideWatchedRecentlyAdded: Bool = false
    ) {
        self.mergeLibrariesOnHome = mergeLibrariesOnHome
        self.disabledKeys = disabledKeys
        self.explicitlyEnabledKeys = explicitlyEnabledKeys
        self.disabledGlobalHomeRows = disabledGlobalHomeRows
        self.enabledLibraryHomeRows = enabledLibraryHomeRows
        self.hasSeededLibraryRows = hasSeededLibraryRows
        self.continueWatchingShowsSeriesArtwork = continueWatchingShowsSeriesArtwork
        self.continueWatchingLayout = continueWatchingLayout
        self.continueWatchingPlaybackDetails = continueWatchingPlaybackDetails
        self.continueWatchingAction = continueWatchingAction
        self.rowCustomization = rowCustomization
        self.mergeNextUpIntoContinueWatching = mergeNextUpIntoContinueWatching
        self.collectionSections = collectionSections
        self.hideWatchedRecentlyAdded = hideWatchedRecentlyAdded
    }

    /// Fresh profiles match their server; existing blobs retain legacy behavior.
    public static let `default` = HomeLibraryVisibility(
        mergeLibrariesOnHome: false, rowCustomization: HomeRowCustomization(defaults: .matchServer)
    )

    // MARK: - Library availability predicates

    /// Whether the library with `key` is on (not disabled).
    public func isEnabled(_ key: String) -> Bool {
        !disabledKeys.contains(key)
    }

    /// Whether the library appears on Home. An enabled video library is on Home;
    /// there is no separate Home-only opt-out, so this is just ``isEnabled(_:)``.
    /// (A music library is never on Home regardless — the Home aggregator excludes
    /// `isMusic` — so this predicate is only consulted for non-music libraries.)
    public func isVisibleOnHome(_ key: String) -> Bool {
        isEnabled(key)
    }

    public func isVisibleOnHome(_ key: String, library: MediaLibrary) -> Bool {
        isEnabled(key) && (library.kind != .collection || library.hasCollections != false
            || explicitlyEnabledKeys.contains(key))
    }

    public func isVisibleOnHome(_ library: AggregatedLibrary) -> Bool {
        isVisibleOnHome(library.key, library: library.library)
    }

    /// Compatibility alias for ``isVisibleOnHome(_:)``.
    public func isVisible(_ key: String) -> Bool {
        isVisibleOnHome(key)
    }

    // MARK: - Library availability mutation

    /// Turns a library on/off.
    public mutating func setEnabled(_ enabled: Bool, for key: String) {
        if enabled {
            disabledKeys.remove(key)
            explicitlyEnabledKeys.insert(key)
        } else {
            disabledKeys.insert(key)
            explicitlyEnabledKeys.remove(key)
        }
    }

    // MARK: - Global Home rows (opt-out)

    /// Whether a global Home row is shown (default on).
    public func isGlobalRowEnabled(_ row: HomeGlobalRow) -> Bool {
        rowCustomization?.isVisible(
            .global(row), providerDefault: rowCustomization?.defaults == .legacy
                ? !disabledGlobalHomeRows.contains(row.rawValue) : row != .recentlyAdded
        )
            ?? !disabledGlobalHomeRows.contains(row.rawValue)
    }

    /// Shows/hides a global Home row.
    public mutating func setGlobalRowEnabled(_ enabled: Bool, for row: HomeGlobalRow) {
        rowCustomization?.setVisible(enabled, for: .global(row))
        if enabled {
            disabledGlobalHomeRows.remove(row.rawValue)
        } else {
            disabledGlobalHomeRows.insert(row.rawValue)
        }
    }

    // MARK: - Per-library Home rows (opt-in)

    /// The persistence key for a per-library row: `"<libraryKey>:<rowKind>"`.
    public static func libraryRowKey(_ libraryKey: String, kind: LibraryHomeRowKind) -> String {
        "\(libraryKey):\(kind.rawValue)"
    }

    /// Whether a per-library row is opted in to Home (default off).
    public func isLibraryRowEnabled(_ libraryKey: String, kind: LibraryHomeRowKind) -> Bool {
        enabledLibraryHomeRows.contains(Self.libraryRowKey(libraryKey, kind: kind))
    }

    public func isHomeRowVisible(_ choice: HomeRowChoice) -> Bool {
        guard !isMergedHomeRow(choice) else { return false }
        if let rowCustomization {
            return rowCustomization.isVisible(
                choice.id, providerDefault: rowCustomization.defaults == .legacy
                    ? (isLegacyRowVisible(choice.id) && choice.isLegacyDefault) : choice.isProviderDefault
            )
        }
        return isLegacyRowVisible(choice.id) && choice.isLegacyDefault
    }

    private func isLegacyRowVisible(_ id: HomeRowID) -> Bool {
        switch id {
        case let .global(row): return isGlobalRowEnabled(row)
        case .libraries: return true
        case .server, .liveTV, .section: return false
        case let .library(key, _):
            return !mergeLibrariesOnHome
                && id.libraryKind.map { isLibraryRowEnabled(key, kind: $0) } == true
        }
    }

    public func requestedRowKinds(for library: AggregatedLibrary) -> [LibraryHomeRowKind] {
        guard usesIndividualHomeRows, isEnabled(library.key) else { return [] }
        return LibraryHomeRowKind.available(for: library).filter { kind in
            if kind == .nextUp, mergesNextUpRows { return false }
            guard let rowCustomization else { return isLibraryRowEnabled(library.key, kind: kind) }
            if kind == .hubs {
                let explicit = rowCustomization.shown.contains {
                    $0.libraryKey == library.key && $0.libraryKind == .hubs && !rowCustomization.hidden.contains($0)
                }
                if explicit { return true }
                let known = rowCustomization.order.filter {
                    $0.libraryKey == library.key && $0.libraryKind == .hubs
                }
                if !known.isEmpty, known.allSatisfy(rowCustomization.hidden.contains) {
                    return false
                }
                let automatic = rowCustomization.defaults == .legacy
                    ? (!mergeLibrariesOnHome && isLibraryRowEnabled(library.key, kind: kind))
                    : rowCustomization.isVisible(
                        .library(library.key, kind: .hubs),
                        providerDefault: library.providerKind == .plex
                    )
                return automatic
            }
            return rowCustomization.isVisible(
                .library(library.key, kind: kind),
                providerDefault: rowCustomization.defaults == .legacy
                    ? (!mergeLibrariesOnHome && isLibraryRowEnabled(library.key, kind: kind)) : true
            )
        }
    }

    public func rowSections(choices: [HomeRowChoice]) -> OrderedVisibilityList.Sections<HomeRowID> {
        let available = choices.map(\.id)
        let hidden = Set(choices.filter { !isHomeRowVisible($0) }.map(\.id))
        if let rowCustomization {
            return rowCustomization.sections(available: available, hidden: hidden)
        }
        return OrderedVisibilityList.resolving(
            available: available, order: [], hidden: hidden
        )
    }

    public mutating func applyRows(
        _ sections: OrderedVisibilityList.Sections<HomeRowID>, choices: [HomeRowChoice]
    ) {
        var sections = sections
        var unmerged = self
        unmerged.mergeNextUpIntoContinueWatching = false
        let previous = unmerged.rowSections(choices: choices)
        let preserved = Set(choices.filter(isMergedHomeRow).map(\.id))
        if !preserved.isEmpty {
            // Merged rows are absent from the arranger, not explicitly hidden.
            // Restore their saved slots before applying edits to the other rows.
            func restoring(_ old: [HomeRowID], edits: [HomeRowID]) -> [HomeRowID] {
                var iterator = edits.filter { !preserved.contains($0) }.makeIterator()
                let result = old.compactMap { preserved.contains($0) ? $0 : iterator.next() }
                return result + Array(iterator)
            }
            sections.enabled = restoring(previous.enabled, edits: sections.enabled)
            sections.disabled = restoring(previous.disabled, edits: sections.disabled)
        }
        if rowCustomization == nil {
            rowCustomization = HomeRowCustomization(
                defaults: .legacy, order: previous.combined,
                hidden: Set(previous.disabled), shown: Set(previous.enabled)
            )
        }
        let resolvedChoices = choices.map {
            HomeRowChoice(
                id: $0.id, title: $0.title, localizedTitle: $0.localizedTitle,
                library: $0.library,
                isProviderDefault: rowCustomization?.defaults == .legacy
                    ? (isLegacyRowVisible($0.id) && $0.isLegacyDefault) : $0.isProviderDefault,
                serverRow: $0.serverRow, collectionSection: $0.collectionSection
            )
        }
        rowCustomization?.apply(sections, choices: resolvedChoices)
    }

    /// Opts a per-library row in/out of Home.
    public mutating func setLibraryRowEnabled(_ enabled: Bool, libraryKey: String, kind: LibraryHomeRowKind) {
        let key = Self.libraryRowKey(libraryKey, kind: kind)
        if enabled {
            enabledLibraryHomeRows.insert(key)
        } else {
            enabledLibraryHomeRows.remove(key)
        }
    }

    /// Seeds the given per-library rows **on**, but only the first time the user
    /// unmerges (tracked by ``hasSeededLibraryRows``).
    ///
    /// Turning the merge switch **off** is a clear "I want each library's own
    /// rows" signal, so the first time that happens we start with everything on
    /// and let the user pare it back — much better than dropping them onto an
    /// empty Home. Keying off an explicit `hasSeededLibraryRows` flag (rather than
    /// `enabledLibraryHomeRows.isEmpty`) means a later re-toggle (merge on, then
    /// off again) never re-seeds — including when the user has deliberately turned
    /// *every* per-library row off, which an emptiness check couldn't distinguish
    /// from first-run. Only sets the flag when it actually seeds (rows non-empty),
    /// so a toggle made before library discovery finishes is retried later.
    /// Returns `true` when it seeded (so the caller can persist).
    @discardableResult
    public mutating func seedLibraryRowsIfNeeded(_ rows: [(libraryKey: String, kind: LibraryHomeRowKind)]) -> Bool {
        guard !hasSeededLibraryRows, !rows.isEmpty else { return false }
        for row in rows {
            enabledLibraryHomeRows.insert(Self.libraryRowKey(row.libraryKey, kind: row.kind))
        }
        hasSeededLibraryRows = true
        return true
    }

    // MARK: - Codable (backward compatible)

    private enum CodingKeys: String, CodingKey {
        case mergeLibrariesOnHome
        case disabledKeys
        case explicitlyEnabledKeys
        case disabledGlobalHomeRows
        case enabledLibraryHomeRows
        case hasSeededLibraryRows
        case continueWatchingShowsSeriesArtwork
        case continueWatchingLayout
        // Preserve the stored preference introduced with portrait cards.
        case continueWatchingPlaybackDetails = "continueWatchingPortraitDetails"
        case continueWatchingAction
        case rowCustomization
        case collectionSections
        case mergeNextUpIntoContinueWatching
        case hideWatchedRecentlyAdded
    }

    /// Decodes leniently so a pre-existing blob still loads: missing fields fall
    /// back to the defaults (merge on, every global row on, no per-library rows),
    /// so an upgrading install sees zero Home behaviour change until it opts in. A
    /// since-removed `excludedKeys` (the old Home-only "hide" opt-out) and
    /// `mergeContinueWatchingOnHome` key are simply ignored — dropping
    /// `excludedKeys` means any library that was excluded-but-enabled now simply
    /// shows on Home again (the axis is retired; use enable/disable instead).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mergeLibrariesOnHome = try container.decodeIfPresent(Bool.self, forKey: .mergeLibrariesOnHome) ?? true
        self.disabledKeys = try container.decodeIfPresent(Set<String>.self, forKey: .disabledKeys) ?? []
        self.explicitlyEnabledKeys = try container.decodeIfPresent(Set<String>.self, forKey: .explicitlyEnabledKeys) ?? []
        self.disabledGlobalHomeRows = try container.decodeIfPresent(Set<String>.self, forKey: .disabledGlobalHomeRows) ?? []
        self.enabledLibraryHomeRows = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLibraryHomeRows) ?? []
        // Migration: a blob predating this flag that already has opted-in rows was
        // clearly seeded before, so treat it as seeded — otherwise the first
        // post-upgrade merge re-toggle would re-seed over its customization.
        self.hasSeededLibraryRows = (try container.decodeIfPresent(Bool.self, forKey: .hasSeededLibraryRows) ?? false)
            || !self.enabledLibraryHomeRows.isEmpty
        // Defaults ON for upgrading installs too. This one is deliberately *not*
        // treated like the conservative "change nothing on upgrade" fields above:
        // the old behaviour is the reported problem (a Continue Watching row that
        // is mostly blurred rectangles once spoiler protection is on), so an
        // upgrading user should get the better row and can switch back.
        self.continueWatchingShowsSeriesArtwork = try container.decodeIfPresent(
            Bool.self,
            forKey: .continueWatchingShowsSeriesArtwork
        ) ?? true
        self.continueWatchingLayout = try container.decodeIfPresent(
            ContinueWatchingCardLayout.self, forKey: .continueWatchingLayout
        ) ?? .landscape
        self.continueWatchingPlaybackDetails = try container.decodeIfPresent(
            ContinueWatchingPlaybackDetails.self, forKey: .continueWatchingPlaybackDetails
        ) ?? .default
        self.continueWatchingAction = try container.decodeIfPresent(
            ContinueWatchingAction.self, forKey: .continueWatchingAction
        ) ?? .default
        self.rowCustomization = try container.decodeIfPresent(HomeRowCustomization.self, forKey: .rowCustomization)
        self.collectionSections = try container.decodeIfPresent([CollectionSection].self, forKey: .collectionSections) ?? []
        self.mergeNextUpIntoContinueWatching = try container.decodeIfPresent(
            Bool.self, forKey: .mergeNextUpIntoContinueWatching
        ) ?? true
        self.hideWatchedRecentlyAdded = try container.decodeIfPresent(
            Bool.self, forKey: .hideWatchedRecentlyAdded
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mergeLibrariesOnHome, forKey: .mergeLibrariesOnHome)
        try container.encode(disabledKeys.sorted(), forKey: .disabledKeys)
        try container.encode(explicitlyEnabledKeys.sorted(), forKey: .explicitlyEnabledKeys)
        try container.encode(disabledGlobalHomeRows.sorted(), forKey: .disabledGlobalHomeRows)
        try container.encode(enabledLibraryHomeRows.sorted(), forKey: .enabledLibraryHomeRows)
        try container.encode(hasSeededLibraryRows, forKey: .hasSeededLibraryRows)
        try container.encode(continueWatchingShowsSeriesArtwork, forKey: .continueWatchingShowsSeriesArtwork)
        try container.encode(continueWatchingLayout, forKey: .continueWatchingLayout)
        try container.encode(continueWatchingPlaybackDetails, forKey: .continueWatchingPlaybackDetails)
        try container.encode(continueWatchingAction, forKey: .continueWatchingAction)
        try container.encodeIfPresent(rowCustomization, forKey: .rowCustomization)
        if !collectionSections.isEmpty { try container.encode(collectionSections, forKey: .collectionSections) }
        try container.encode(mergeNextUpIntoContinueWatching, forKey: .mergeNextUpIntoContinueWatching)
        try container.encode(hideWatchedRecentlyAdded, forKey: .hideWatchedRecentlyAdded)
    }
}

public enum ContinueWatchingCardLayout: String, CaseIterable, Codable, Sendable {
    case landscape, portrait
}

public enum ContinueWatchingPlaybackDetails: String, CaseIterable, Codable, Sendable {
    case detailed, progressOnly

    public static let `default`: Self = .detailed
}

public enum ContinueWatchingAction: String, CaseIterable, Codable, Sendable {
    case play, openDetails

    public static let `default`: Self = .play
}

/// A global (cross-server, cross-library) row on Home. The hero is handled
/// separately via `HeroSettings`.
public enum HomeGlobalRow: String, CaseIterable, Codable, Sendable {
    case continueWatching
    case watchlist
    case recentlyAdded

    /// The row's display heading (matches ``HomeRowKind`` titles).
    public var title: LocalizedStringResource {
        switch self {
        case .continueWatching:
            return LocalizedStringResource(
                "homeRow.continueWatching",
                defaultValue: "Continue Watching",
                comment: "Home screen row name, e.g. in Settings > Customize Home."
            )
        case .watchlist:
            return LocalizedStringResource(
                "homeRow.watchlist",
                defaultValue: "Watchlist",
                comment: "Home screen row name, e.g. in Settings > Customize Home."
            )
        case .recentlyAdded:
            return LocalizedStringResource(
                "homeRow.recentlyAdded",
                defaultValue: "Recently Added",
                comment: "Home screen row name, e.g. in Settings > Customize Home."
            )
        }
    }
}

/// A per-library row kind that can be opted in to Home in unmerged mode.
///
/// Continue Watching is deliberately **not** here — it's always the single global
/// Continue Watching row (a per-library duplicate is redundant). `hubs` is the
/// provider's native recommendations. Availability is library- and provider-specific.
public enum LibraryHomeRowKind: String, CaseIterable, Sendable {
    case nextUp
    case recentlyAdded
    case hubs

    public static func available(for library: AggregatedLibrary) -> [Self] {
        guard !library.library.isMusic, !library.library.isServerCollectionDirectory,
              !library.isRetiredCollectionShortcut else { return [] }
        var kinds: [Self] = []
        if library.providerKind.usesMediaBrowserAPI, library.library.kind == .series {
            kinds.append(.nextUp)
        }
        kinds.append(.recentlyAdded)
        if library.providerKind == .plex
            || (library.providerKind.usesMediaBrowserAPI && library.library.kind == .movie) {
            kinds.append(.hubs)
        }
        return kinds
    }

    /// A short label for the Customize Home checklist.
    public var displayName: LocalizedStringResource {
        switch self {
        case .nextUp: return "Next Up"
        case .recentlyAdded:
            return LocalizedStringResource(
                "libraryRowKind.recentlyAdded",
                defaultValue: "Recently Added",
                comment: "Per-library Home row type in Settings > Customize Home."
            )
        case .hubs:
            return LocalizedStringResource(
                "libraryRowKind.hubs",
                defaultValue: "Recommended rows",
                comment: "Per-library Home row type in Settings > Customize Home."
            )
        }
    }
}
