import XCTest
@testable import CoreModels

final class ArtworkReferenceTests: XCTestCase {
    private let privatePath = "Movies/Example/poster.jpg"

    private func networkReference(
        accountID: String = "share-account",
        revision: CredentialRevision = CredentialRevision(),
        catalogArtworkID: String = "art-00000000-0000-0000-0000-000000000001",
        sourceRevision: String = "revision-1"
    ) throws -> NetworkArtworkReference {
        try NetworkArtworkReference(
            accountID: accountID,
            credentialRevision: revision,
            catalogArtworkID: catalogArtworkID,
            representation: RemoteFileRepresentation(
                size: 4_096,
                identity: RemoteFileIdentity(
                    kind: .modificationTime,
                    modifiedAt: Date(timeIntervalSince1970: 123)
                ),
                consistency: .changeDetecting
            ),
            sourceRevision: sourceRevision,
            contentType: "image/jpeg",
            dimensions: ArtworkDimensions(width: 1_000, height: 1_500)
        )
    }

    func testNetworkReferenceRoundTripsWithoutCredentials() throws {
        let revision = CredentialRevision()
        let network = try networkReference(revision: revision)
        let reference = ArtworkReference.networkFile(network)
        let encoded = try JSONEncoder().encode(reference)

        let decoded = try JSONDecoder().decode(
            ArtworkReference.self,
            from: encoded
        )

        XCTAssertEqual(decoded, reference)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(privatePath))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("relativePath"))
    }

    func testMediaItemPrefersExplicitPlacementThenLegacyRemoteFallback() throws {
        let local = ArtworkReference.networkFile(
            try networkReference(catalogArtworkID: "art-landscape")
        )
        let remote = try XCTUnwrap(URL(string: "https://example.com/backdrop.jpg"))
        let item = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            heroBackdropURL: remote,
            artworkSelections: [
                ArtworkSelection(placement: .homeHero, references: [local, local])
            ]
        )

        XCTAssertEqual(
            item.artworkReferences(for: .homeHero),
            [local, .remote(remote)]
        )
        XCTAssertEqual(
            item.artworkReferences(for: .detailBackdrop),
            [.remote(remote)]
        )
    }

    func testLegacyMediaItemDecodesWithoutArtworkSelections() throws {
        let item = MediaItem(id: "legacy", title: "Legacy", kind: .movie)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        object.removeValue(forKey: "artworkSelections")
        object.removeValue(forKey: "artworkMetadataSourcesByURL")
        object.removeValue(forKey: "artworkLookupSubject")

        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.artworkSelections.isEmpty)
        XCTAssertTrue(decoded.artworkMetadataSourcesByURL.isEmpty)
        XCTAssertNil(decoded.artworkLookupSubject)
    }

    func testCatalogArtworkSubjectRoundTripsWithoutReplacingThePhysicalFolder() throws {
        let catalog = MediaItem(
            id: "catalog-series", title: "Recognized Series", kind: .series,
            productionYear: 2020, providerIDs: ["Tvdb": "42"]
        )
        var folder = MediaItem(
            id: "d:series", title: "Folder Name", kind: .folder,
            sourceAccountID: "share-account", isFavorite: true
        )
        folder.artworkLookupSubject = try XCTUnwrap(ArtworkLookupSubject(catalog: catalog))
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(folder))
        XCTAssertEqual(decoded, folder)
        XCTAssertEqual(decoded.kind, .folder)
        XCTAssertEqual(decoded.id, "d:series")
        XCTAssertEqual(decoded.title, "Folder Name")
        XCTAssertTrue(decoded.isFavorite)
        XCTAssertEqual(decoded.artworkLookupItem.id, catalog.id)
        XCTAssertEqual(decoded.artworkLookupItem.kind, .series)
        XCTAssertEqual(decoded.artworkLookupItem.providerIDs, catalog.providerIDs)
        XCTAssertEqual(decoded.artworkLookupItem.sourceAccountID, "share-account")
        XCTAssertNil(ArtworkLookupSubject(catalog: folder))
    }

    func testLibraryHeroUsesPrimarySidecarAheadOfAlternateAndEnrichedRemoteArtwork() throws {
        let primary = ArtworkReference.networkFile(try networkReference(catalogArtworkID: "primary"))
        let alternate = ArtworkReference.networkFile(try networkReference(catalogArtworkID: "alternate"))
        let online = try XCTUnwrap(URL(string: "https://example.com/enriched.jpg"))
        let item = MediaItem(
            id: "share", title: "Share", kind: .movie, heroBackdropURL: online,
            artworkSelections: [
                .init(placement: .homeHero, references: [primary, alternate]),
                .init(placement: .detailBackdrop, references: [alternate, primary])
            ]
        )
        XCTAssertEqual(item.artworkReferences(for: .detailBackdrop).first, alternate)
        XCTAssertEqual(
            item.artworkReferences(for: .detailBackdrop, preferringLibrarySelection: true),
            [primary, alternate, .remote(online)]
        )
        XCTAssertEqual(
            item.artworkReferences(for: .homeHero, preferringLibrarySelection: true).first,
            primary
        )
    }

    func testEpisodeThumbnailLegacyReferencesStayEpisodeScoped() throws {
        let poster = try XCTUnwrap(URL(string: "https://example.com/episode.jpg"))
        let backdrop = try XCTUnwrap(URL(string: "https://example.com/episode-backdrop.jpg"))
        let seriesArtwork = try XCTUnwrap(URL(string: "https://example.com/series.jpg"))
        let item = MediaItem(
            id: "episode",
            title: "Episode",
            kind: .episode,
            posterURL: poster,
            backdropURL: backdrop,
            fallbackArtworkURL: seriesArtwork
        )

        XCTAssertEqual(
            item.artworkReferences(for: .episodeThumbnail),
            [.remote(poster), .remote(backdrop)]
        )
    }

    func testPosterLegacyReferencesPreserveFallbackOrdering() throws {
        let poster = try XCTUnwrap(URL(string: "https://example.com/poster.jpg"))
        let seriesPoster = try XCTUnwrap(URL(string: "https://example.com/series-poster.jpg"))
        let fallback = try XCTUnwrap(URL(string: "https://example.com/fallback.jpg"))
        let item = MediaItem(
            id: "legacy-posters",
            title: "Legacy Posters",
            kind: .episode,
            posterURL: poster,
            seriesPosterURL: seriesPoster,
            fallbackArtworkURL: fallback
        )

        XCTAssertEqual(item.artworkReferences(for: .poster), [.remote(poster), .remote(fallback)])
        XCTAssertEqual(
            item.artworkReferences(for: .seriesPoster),
            [.remote(seriesPoster), .remote(poster), .remote(fallback)]
        )
    }

    func testSeriesSidecarLeadsLandscapeWithoutLeakingEpisodeStill() throws {
        let sidecar = ArtworkReference.networkFile(try networkReference())
        let still = try XCTUnwrap(URL(string: "https://library.example.test/episode.jpg"))
        let backdrop = try XCTUnwrap(URL(string: "https://library.example.test/series-backdrop.jpg"))
        let poster = try XCTUnwrap(URL(string: "https://library.example.test/series-poster.jpg"))
        var episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            posterURL: still, seriesPosterURL: poster, fallbackArtworkURL: backdrop,
            artworkSelections: [.init(placement: .seriesPoster, references: [sidecar])]
        )
        XCTAssertEqual(episode.seriesArtworkReferences(), [sidecar, .remote(backdrop), .remote(poster)])
        XCTAssertEqual(episode.seriesArtworkReferences(prefersPortrait: true),
                       [sidecar, .remote(poster), .remote(backdrop)])
        episode.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        episode.metadataProvenance[.backdropURL] = MetadataAttribution(source: .tvdb)
        XCTAssertEqual(episode.seriesArtworkReferences(), [sidecar])
        XCTAssertEqual(episode.seriesArtworkReferences(prefersPortrait: true), [sidecar])
        XCTAssertEqual(episode.posterURL, still, "Selecting show art must not modify the playable episode.")
    }

    func testPersistedExternalArtworkIsNotAnImmediateLibraryCandidate() throws {
        let poster = try XCTUnwrap(URL(string: "https://metadata.example.test/poster.jpg"))
        let backdrop = try XCTUnwrap(URL(string: "https://metadata.example.test/backdrop.jpg"))
        var item = MediaItem(
            id: "share-movie", title: "Local title", kind: .movie,
            overview: "Local overview", posterURL: poster, heroBackdropURL: backdrop,
            providerIDs: ["Tmdb": "42"]
        )
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        item.metadataProvenance[.backdropURL] = MetadataAttribution(source: .tvdb)
        item = item.taggingSource("share-account")
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))

        XCTAssertTrue(decoded.artworkReferences(for: .poster).isEmpty)
        XCTAssertTrue(decoded.artworkReferences(for: .homeHero).isEmpty)
        XCTAssertEqual(decoded.metadataArtworkURLs(for: .poster), [.init(value: poster, source: .tmdb)])
        XCTAssertEqual(decoded.metadataArtworkURLs(for: .homeHero), [.init(value: backdrop, source: .tvdb)])
        XCTAssertEqual(decoded.posterURL, poster)
        XCTAssertEqual(decoded.artworkSourceAccountID(for: poster), "share-account")
        XCTAssertEqual(decoded.sourceAccountID, item.sourceAccountID)
        XCTAssertEqual(decoded.providerIDs, item.providerIDs)
        XCTAssertEqual(decoded.title, item.title)
        XCTAssertEqual(decoded.overview, item.overview)
    }

    func testServerArtworkKeepsAuthenticationAndUnknownExternalArtworkCannotMasqueradeAsServerArt() throws {
        let url = try XCTUnwrap(URL(string: "https://library.example.test/poster.jpg?api_key=fixture"))
        var item = MediaItem(id: "server-item", title: "Title", kind: .movie, posterURL: url)
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .server)
        XCTAssertEqual(item.artworkReferences(for: .poster), [.remote(url)])
        XCTAssertTrue(item.metadataArtworkURLs(for: .poster).isEmpty)
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .legacyUnknown)
        XCTAssertTrue(item.artworkReferences(for: .poster).isEmpty)
        XCTAssertNil(item.libraryArtworkURL(url))
        XCTAssertEqual(item.posterURL, url)
    }

    func testDonatedArtworkRetainsItsSourceWithoutChangingNativeArtworkOrAuth() throws {
        let native = try XCTUnwrap(URL(string: "https://library.example.test/poster.jpg?api_key=fixture"))
        let external = try XCTUnwrap(URL(string: "https://art.example.test/backdrop.jpg"))
        var recipient = MediaItem(
            id: "playable", title: "Local title", kind: .movie,
            posterURL: native, backdropURL: native, sourceAccountID: "library-account"
        )
        recipient.metadataProvenance[.backdropURL] = MetadataAttribution(source: .server)
        var donor = MediaItem(id: "other", title: "Other title", kind: .movie, heroBackdropURL: external)
        donor.metadataProvenance[.backdropURL] = MetadataAttribution(source: .tmdb)
        donor = donor.taggingSource("share-account")
        recipient.fillingMissingPresentation(from: donor)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(recipient))
        XCTAssertEqual(decoded.artworkReferences(for: .homeHero), [.remote(native)])
        XCTAssertEqual(decoded.metadataArtworkURLs(for: .homeHero), [.init(value: external, source: .tmdb)])
        XCTAssertEqual(decoded.artworkSourceAccountID(for: external), "share-account")
        XCTAssertEqual(decoded.posterURL, native)
        XCTAssertEqual(decoded.sourceAccountID, "library-account")
        XCTAssertEqual(decoded.id, "playable")
        XCTAssertEqual(decoded.title, "Local title")

        // A native donor also cannot inherit an external sibling field's source.
        var inverse = MediaItem(id: "inverse", title: "Inverse", kind: .movie, backdropURL: external)
        inverse.metadataProvenance[.backdropURL] = MetadataAttribution(source: .tmdb)
        inverse.fillingMissingPresentation(from: .init(
            id: "server", title: "Server", kind: .movie, heroBackdropURL: native
        ))
        XCTAssertEqual(inverse.artworkReferences(for: .homeHero), [.remote(native)])
        XCTAssertEqual(inverse.metadataArtworkURLs(for: .homeHero), [.init(value: external, source: .tmdb)])
    }

    func testNetworkReferencePrivacySafeIdentityExcludesPath() throws {
        let revision = CredentialRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000444"))
        )
        let reference = ArtworkReference.networkFile(
            try networkReference(
                revision: revision,
                catalogArtworkID: "art-private-logo",
                sourceRevision: "opaque-revision"
            )
        )

        XCTAssertFalse(reference.privacySafeIdentity.contains("Private/Folder/logo.png"))
        XCTAssertTrue(reference.privacySafeIdentity.contains("opaque-revision"))
    }

    func testCatalogArtworkIdentityIsAccountScopedByReferenceIdentity() throws {
        let artworkID = "art-00000000-0000-0000-0000-000000000123"
        let first = try networkReference(
            accountID: "account-a",
            catalogArtworkID: artworkID
        )
        let otherAccount = try networkReference(
            accountID: "account-b",
            catalogArtworkID: artworkID
        )

        XCTAssertNotEqual(first, otherAccount)
        XCTAssertNotEqual(
            ArtworkReference.networkFile(first).privacySafeIdentity,
            ArtworkReference.networkFile(otherAccount).privacySafeIdentity
        )
    }

    func testLegacyRelativePathPayloadDropsLocalReferenceAndUsesRemoteFallback() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.com/poster.jpg"))
        let item = MediaItem(
            id: "legacy-path",
            title: "Legacy",
            kind: .movie,
            posterURL: remote,
            artworkSelections: [
                ArtworkSelection(
                    placement: .poster,
                    references: [.networkFile(try networkReference())]
                )
            ]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        var selections = try XCTUnwrap(object["artworkSelections"] as? [[String: Any]])
        var selection = selections[0]
        var references = try XCTUnwrap(selection["references"] as? [[String: Any]])
        var reference = references[0]
        var network = try XCTUnwrap(reference["networkFile"] as? [String: Any])
        network.removeValue(forKey: "catalogArtworkID")
        network["relativePath"] = privatePath
        reference["networkFile"] = network
        references[0] = reference
        selection["references"] = references
        selections[0] = selection
        object["artworkSelections"] = selections

        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.artworkSelections[0].references.isEmpty)
        XCTAssertEqual(decoded.artworkReferences(for: .poster), [.remote(remote)])
    }

    func testMediaItemSerializedArtworkSelectionsNeverContainLibraryPath() throws {
        let item = MediaItem(
            id: "private",
            title: "Private",
            kind: .movie,
            artworkSelections: [
                ArtworkSelection(
                    placement: .poster,
                    references: [.networkFile(try networkReference())]
                )
            ]
        )

        let encoded = try JSONEncoder().encode(item)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains(privatePath))
        XCTAssertFalse(text.contains("relativePath"))
        XCTAssertTrue(text.contains("catalogArtworkID"))
    }

    func testUnvalidatedNetworkHeroFallsBackButPosterRemainsEligible() throws {
        let accountID = "share-account"
        let unvalidated = try NetworkArtworkReference(
            accountID: accountID,
            credentialRevision: CredentialRevision(),
            catalogArtworkID: "art-unvalidated",
            representation: RemoteFileRepresentation(
                size: 100,
                identity: RemoteFileIdentity(
                    kind: .modificationTime,
                    modifiedAt: Date(timeIntervalSince1970: 100)
                ),
                consistency: .changeDetecting
            ),
            sourceRevision: "unvalidated"
        )
        let fallback = try XCTUnwrap(URL(string: "https://example.com/backdrop.jpg"))
        let item = MediaItem(
            id: "unvalidated",
            title: "Unvalidated",
            kind: .movie,
            heroBackdropURL: fallback,
            artworkSelections: [
                ArtworkSelection(
                    placement: .homeHero,
                    references: [.networkFile(unvalidated)]
                ),
                ArtworkSelection(
                    placement: .poster,
                    references: [.networkFile(unvalidated)]
                ),
            ]
        )

        XCTAssertEqual(item.artworkReferences(for: .homeHero), [.remote(fallback)])
        XCTAssertEqual(item.artworkReferences(for: .poster), [.networkFile(unvalidated)])
    }

    func testInvalidPersistedDimensionsAreRejected() throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["width": Int.max, "height": Int.max]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ArtworkDimensions.self, from: data)
        )
    }

    func testMalformedLegacyArtworkSelectionDropsToRemoteFallback() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.com/poster.jpg"))
        let item = MediaItem(
            id: "legacy-malformed",
            title: "Legacy",
            kind: .movie,
            posterURL: remote,
            artworkSelections: [
                ArtworkSelection(
                    placement: .poster,
                    references: [.networkFile(try networkReference())]
                )
            ]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        var selections = try XCTUnwrap(object["artworkSelections"] as? [[String: Any]])
        var selection = selections[0]
        var references = try XCTUnwrap(selection["references"] as? [[String: Any]])
        var reference = references[0]
        var network = try XCTUnwrap(reference["networkFile"] as? [String: Any])
        network.removeValue(forKey: "catalogArtworkID")
        network["relativePath"] = "../private/poster.jpg"
        reference["networkFile"] = network
        references[0] = reference
        selection["references"] = references
        selections[0] = selection
        object["artworkSelections"] = selections

        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.artworkReferences(for: .poster), [.remote(remote)])
    }
}
