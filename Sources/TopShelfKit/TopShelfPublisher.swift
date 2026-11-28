import Foundation
import CoreModels
import Observation
import OSLog
#if os(tvOS)
import TVServices
#endif

/// Maps the app's domain models onto a `TopShelfSnapshot` and publishes it to
/// the shared App Group container for the Top Shelf extension to render.
///
/// This file imports `CoreModels`, so it is compiled **only** into the app (via
/// the `TopShelfKit` package). The extension compiles the snapshot, store and
/// native content builder directly, keeping `CoreModels` out of its memory budget.
public enum TopShelfPublisher {
    public typealias ArtworkResolver = @MainActor @Sendable (MediaItem) async -> Data?
    public typealias MetadataResolver = @MainActor @Sendable (MediaItem) async throws -> MediaItem

    /// Also called at process entry, before launch preparation can suspend or present a gate.
    @MainActor
    public static func revoke() {
        guard let files = TopShelfStore.files else { return }
        files.revoke()
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
        TopShelfStore.pruneArtwork(keeping: [])
    }

    /// Builds and saves a snapshot from the Home screen's two playable rows.
    ///
    /// Continue-Watching items that are mid-playback get a poster with the resume
    /// bar composited into the artwork (posters can't show the native Top Shelf
    /// progress bar — see `TopShelfPosterComposer`). The app resolves each image
    /// using the active profile's policy before exporting it. Empty rows are dropped; if nothing is playable the
    /// authorized snapshot can still be empty. Signing out separately revokes
    /// access even if Home never publishes again. Stale art is pruned each publish.
    /// - Parameter locale: the language the APP is currently showing. The Top
    ///   Shelf extension is a separate process with its own bundle, so it can
    ///   neither read the app's catalog nor know about an in-app language
    ///   override — resolving there would silently fall back to the system
    ///   language and disagree with the app. So the app resolves the section
    ///   titles here and stores finished text; the extension only renders.
    ///   Eager resolution is correct in this one case precisely because the
    ///   value crosses a process boundary.
    @MainActor
    public static func publish(
        for homeScope: String, publication: TopShelfPublication,
        continueWatching: [MediaItem],
        latest: [MediaItem],
        locale: Locale? = nil,
        spoilerSettings: SpoilerSettings = .default,
        showsContentRatings: Bool = true,
        resolveMetadata: MetadataResolver? = nil,
        resolveArtwork: ArtworkResolver? = nil,
        resolveBackdrop: ArtworkResolver? = nil
    ) async {
        await publication.publish(for: homeScope) { settings, accountIDs in
            let authorized: (MediaItem) -> Bool = { $0.sourceAccountID.map(accountIDs.contains) == true }
            return await makeSnapshot(
                continueWatching: continueWatching.filter(authorized), latest: latest.filter(authorized),
                settings: settings,
                locale: locale, spoilerSettings: spoilerSettings,
                showsContentRatings: showsContentRatings,
                resolveMetadata: resolveMetadata,
                resolveArtwork: resolveArtwork, resolveBackdrop: resolveBackdrop
            )
        }
    }

    @MainActor
    fileprivate static func save(_ snapshot: TopShelfSnapshot) {
        guard let files = TopShelfStore.files else { return }
        do { try files.save(snapshot) }
        catch {
            Logger(subsystem: "com.plozz.app", category: "top-shelf")
                .error("Unable to publish the authorized Top Shelf snapshot.")
            return
        }
        let keptArtwork = Set(
            snapshot.sections
                .flatMap(\.items)
                .compactMap(\.imageURL)
                .filter(\.isFileURL)
                .map(\.lastPathComponent)
        )
        TopShelfStore.pruneArtwork(keeping: keptArtwork)
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    static func makeSnapshot(
        continueWatching: [MediaItem],
        latest: [MediaItem],
        settings: TopShelfSettings = .default,
        locale: Locale? = nil,
        spoilerSettings: SpoilerSettings = .default,
        showsContentRatings: Bool = true,
        resolveMetadata: MetadataResolver? = nil,
        resolveArtwork: ArtworkResolver? = nil,
        resolveBackdrop: ArtworkResolver? = nil
    ) async -> TopShelfSnapshot? {
        guard !Task.isCancelled else { return nil }
        guard settings.isEnabled else { return TopShelfSnapshot(sections: []) }
        var sections: [TopShelfSnapshot.Section] = []
        let resumeItems = Array(continueWatching.prefix(settings.continueWatchingItems))
        let recentItems = Array(latest.prefix(settings.recentlyAddedItems))
        var metadata: [String: MediaItem] = [:]
        if settings.usesFullScreen, let resolveMetadata {
            var attempted = Set<String>()
            for item in resumeItems + recentItems {
                guard !Task.isCancelled else { return nil }
                let key = TopShelfSnapshot.Item(id: item.id, accountID: item.sourceAccountID, title: item.title)
                    .shelfIdentifier
                guard attempted.insert(key).inserted else { continue }
                do {
                    let detail = try await resolveMetadata(item)
                    guard !Task.isCancelled else { return nil }
                    guard detail.id == item.id, detail.sourceAccountID == item.sourceAccountID else {
                        throw AppError.invalidResponse
                    }
                    metadata[key] = detail
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError),
                          (error as? AppError) != .cancelled else { return nil }
                    Logger(subsystem: "com.plozz.app", category: "top-shelf")
                        .warning("Full-screen metadata unavailable; retaining the Home item's known information.")
                }
            }
        }

        let resume = await items(
            from: resumeItems,
            compositeProgress: true, usesFullScreen: settings.usesFullScreen,
            spoilerSettings: spoilerSettings, locale: locale, metadata: metadata,
            showsContentRatings: showsContentRatings,
            resolveArtwork: resolveArtwork, resolveBackdrop: resolveBackdrop
        )
        if !resume.isEmpty {
            sections.append(.init(id: "continue",
                                  title: resolved("Continue Watching", locale),
                                  items: resume))
        }

        let recent = await items(
            from: recentItems, usesFullScreen: settings.usesFullScreen,
            spoilerSettings: spoilerSettings, locale: locale, metadata: metadata,
            showsContentRatings: showsContentRatings,
            resolveArtwork: resolveArtwork, resolveBackdrop: resolveBackdrop
        )
        if !recent.isEmpty {
            sections.append(.init(id: "latest",
                                  title: resolved("Recently Added", locale),
                                  items: recent))
        }

        guard !Task.isCancelled else { return nil }
        return TopShelfSnapshot(usesFullScreen: settings.usesFullScreen, sections: sections)
    }

    /// What a half-watched card says beside its progress bar: which episode, and
    /// how much is left — `S1 · E1 · 21m left`.
    ///
    /// A shelf of part-watched titles otherwise shows a name and a picture and
    /// leaves the viewer to remember the rest. Both halves come straight from the
    /// same values the in-app card uses, so the two cannot drift into describing
    /// the same title differently.
    ///
    /// Either half may be missing — a movie has no episode numbering, and a title
    /// whose runtime the server never reported has no remaining time — so this
    /// joins whatever is available and returns `nil` rather than an empty chip.
    static func resumeChipText(for item: MediaItem) -> String? {  // l10n:content — composed from server metadata + a formatted duration
        var parts: [String] = []
        if item.kind == .episode, let episodeLabel = item.subtitle {
            parts.append(episodeLabel)
        }
        if let remaining = item.resumeRemainingText {
            parts.append(remaining)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Maps domain items onto snapshot items. When `compositeProgress` is set, a
    /// mid-playback item's poster has the progress bar burned in. A failed
    /// explicit resolver uses a placeholder, never an unapproved source.
    private static func items(
        from media: [MediaItem],
        compositeProgress: Bool = false,
        usesFullScreen: Bool,
        spoilerSettings: SpoilerSettings,
        locale: Locale?,
        metadata: [String: MediaItem],
        showsContentRatings: Bool,
        resolveArtwork: ArtworkResolver? = nil,
        resolveBackdrop: ArtworkResolver? = nil
    ) async -> [TopShelfSnapshot.Item] {
        var result: [TopShelfSnapshot.Item] = []
        result.reserveCapacity(media.count)

        for item in media {
            guard !Task.isCancelled else { return [] }
            // Composited artwork is cached by this id. A bare item id is unique only
            // within one server (Plex ratingKeys are small per-server integers), so
            // two accounts would otherwise overwrite each other's poster files and a
            // card could show the wrong title's art with the wrong resume bar.
            let artworkID = TopShelfSnapshot.Item(
                id: item.id,
                accountID: item.sourceAccountID,
                title: item.title
            ).shelfIdentifier
            let posterURL = Self.posterArtworkURL(for: item)
            let progress = compositeProgress ? item.playedPercentage : nil
            var imageURL: URL?

            if usesFullScreen {
                if let resolveBackdrop {
                    let data = await resolveBackdrop(item)
                    guard !Task.isCancelled else { return [] }
                    imageURL = TopShelfBackdropComposer.imageURL(data: data)
                } else {
                    imageURL = item.kind == .episode
                        ? item.fallbackArtworkURL : item.heroBackdropURL ?? item.backdropURL
                    if imageURL == nil { imageURL = TopShelfBackdropComposer.imageURL(data: nil) }
                }
            } else if let resolveArtwork {
                if let data = await resolveArtwork(item), !Task.isCancelled {
                    imageURL = TopShelfPosterComposer.selectedPosterURL(
                        id: artworkID, data: data, progress: progress,
                        chip: compositeProgress ? resumeChipText(for: item) : nil
                    )
                }
            } else if let poster = posterURL {
                if let progress,
                   let composited = await TopShelfPosterComposer.compositedPosterURL(
                       id: artworkID,
                       posterURL: poster,
                       progress: progress,
                       chip: resumeChipText(for: item)
                   ) {
                    imageURL = composited
                }
                if imageURL == nil {
                    imageURL = poster
                }
            }
            if !usesFullScreen, imageURL == nil, !Task.isCancelled {
                // No vertical artwork anywhere: render a neutral title-card
                // placeholder (with the resume bar burned in when mid-playback)
                // instead of leaving a blank card or a zoomed backdrop.
                imageURL = TopShelfPosterComposer.placeholderPosterURL(
                    id: artworkID, title: item.title, progress: progress
                )
            }

            var snapshot = TopShelfSnapshot.Item(
                id: item.id, accountID: item.sourceAccountID, title: item.title,
                subtitle: item.subtitle, imageURL: imageURL, playbackProgress: item.playedPercentage
            )
            if usesFullScreen {
                TopShelfMetadata.apply(
                    to: &snapshot, item: item, details: metadata[artworkID],
                    spoilerSettings: spoilerSettings, locale: locale, showsContentRatings: showsContentRatings
                )
            }
            result.append(snapshot)
        }

        return result
    }

    /// Picks true **vertical poster** art (2:3) for the shelf card, mirroring
    /// `PosterCardView.artworkCandidates(for: .poster)`: an episode uses its
    /// *series* poster (never its own 16:9 still), then its own poster, then the
    /// spoiler-safe parent fallback. A 16:9 backdrop is deliberately *not* a
    /// candidate — stretching it into a poster frame is what made some cards look
    /// massively zoomed. May be `nil` when the item has no vertical art at all.
    private static func posterArtworkURL(for item: MediaItem) -> URL? {
        if item.kind == .episode {
            return item.seriesPosterURL ?? item.posterURL ?? item.fallbackArtworkURL
        }
        return item.posterURL ?? item.fallbackArtworkURL
    }

    /// Resolves a section title against the app's current language. `nil` means
    /// "follow the system", which is what `LocalizedStringResource` already does.
    static func resolved(_ resource: LocalizedStringResource, _ locale: Locale?) -> String {
        var resource = resource
        if let locale { resource.locale = locale }
        return String(localized: resource)   // l10n:content — deliberately resolved here: the value is written to an App Group file the Top Shelf extension reads in another process
    }
}

/// One app-side authority, independent of whether Home or Settings is mounted.
@MainActor
@Observable
public final class TopShelfPublication {
    public struct Viewer: Equatable, Sendable {
        public let homeScope: String
        public let accountIDs: Set<String>

        public init(homeScope: String, accountIDs: Set<String>) {
            self.homeScope = homeScope
            self.accountIDs = accountIDs
        }
    }

    public private(set) var authorizationID: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var authorizedViewer: Viewer?
    private let viewer: @MainActor () -> Viewer?
    private let settings: @MainActor () -> TopShelfSettings
    private let save: @MainActor (TopShelfSnapshot) -> Void
    private let revoke: @MainActor () -> Void

    public convenience init(viewer: @escaping @MainActor () -> Viewer?) {
        self.init(viewer: viewer, settings: { TopShelfSettingsModel.shared.settings },
                  save: TopShelfPublisher.save, revoke: TopShelfPublisher.revoke)
    }

    init(viewer: @escaping @MainActor () -> Viewer?, settings: @escaping @MainActor () -> TopShelfSettings,
         save: @escaping @MainActor (TopShelfSnapshot) -> Void, revoke: @escaping @MainActor () -> Void) {
        self.viewer = viewer
        self.settings = settings
        self.save = save
        self.revoke = revoke
    }

    public func start() {
        guard !started else { return }
        started = true
        observe()
    }

    private func observe() {
        let owner = withObservationTracking {
            settings().isEnabled ? viewer() : nil
        } onChange: { [weak self] in
            // All inputs are main-actor-owned. Observation fires before mutation:
            // withdraw first, then evaluate the settled selection on the next turn.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.withdraw()
                Task { @MainActor [weak self] in self?.observe() }
            }
        }
        authorizedViewer = owner
        if owner != nil { authorizationID = UUID() }
    }

    private func withdraw() {
        guard authorizationID != nil else { return }
        authorizedViewer = nil
        authorizationID = nil
        revoke()
    }

    private func currentViewer() -> Viewer? {
        guard let authorizedViewer else { return nil }
        guard settings().isEnabled, viewer() == authorizedViewer else {
            withdraw()
            return nil
        }
        return authorizedViewer
    }

    func publish(for homeScope: String, makeSnapshot: (TopShelfSettings, Set<String>) async -> TopShelfSnapshot?) async {
        guard !Task.isCancelled, let authorization = authorizationID,
              let owner = currentViewer(), owner.homeScope == homeScope else { return }
        let preferences = settings()
        generation = UUID()
        let currentGeneration = generation
        guard var snapshot = await makeSnapshot(preferences, owner.accountIDs),
              currentGeneration == generation, authorization == authorizationID,
              !Task.isCancelled, currentViewer() == owner, settings() == preferences else { return }
        snapshot.authorizationID = authorization
        save(snapshot)
    }
}
