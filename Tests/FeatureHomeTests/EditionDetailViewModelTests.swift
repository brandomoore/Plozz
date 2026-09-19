import Foundation
import XCTest
import CoreModels
import MetadataKit
@testable import FeatureHomeCore

@MainActor
final class EditionDetailViewModelTests: XCTestCase {
    private func movie(
        account: String,
        edition: String,
        mediaID: String
    ) -> MediaItem {
        MediaItem(
            id: "10", title: "Fixture", kind: .movie,
            sourceAccountID: account, edition: edition,
            versions: [
                MediaVersion(id: mediaID, edition: edition, height: 720),
                MediaVersion(id: "\(mediaID)-large", edition: edition, height: 1080)
            ]
        )
    }

    func testProviderRefreshRetainsOpeningEditionIntentAndLabel() async throws {
        let listItem = movie(account: "plex", edition: "Director's Cut", mediaID: "101")
        let seed = DetailOpenEnvironment.initialItem(for: listItem, selectedSource: nil)
        var sparseDetail = listItem
        sparseDetail.edition = nil
        let provider = FakeMediaProvider(allItems: [sparseDetail])
        let model = ItemDetailViewModel(
            provider: provider, itemID: listItem.id, initialItem: seed,
            externalMetadataResolver: { _, region in
                ExternalTitleMetadata(
                    enrichment: MetadataEnrichment(),
                    availability: ExternalTitleAvailability(regionCode: region)
                )
            },
            sourceAccountID: "plex",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        await model.load()
        let detail = try XCTUnwrap(model.state.value?.item)
        XCTAssertEqual(detail.editionOpeningSource, .init(accountID: "plex", itemID: "10"))
        XCTAssertEqual(detail.edition, "Director's Cut")
        XCTAssertEqual(detail.versions.map(\.id), ["101", "101-large"])
    }

    func testSameRatingKeyOnDifferentServersLoadsEachServersOwnFiles() async throws {
        let first = movie(account: "server-a", edition: "Theatrical", mediaID: "101")
        let second = movie(account: "server-b", edition: "Extended", mediaID: "201")
        let firstProvider = FakeMediaProvider(allItems: [first])
        let secondProvider = FakeMediaProvider(allItems: [second])
        let model = ItemDetailViewModel(
            provider: firstProvider, itemID: "10", initialItem: first,
            externalMetadataResolver: { _, region in
                ExternalTitleMetadata(
                    enrichment: MetadataEnrichment(),
                    availability: ExternalTitleAvailability(regionCode: region)
                )
            },
            sourceAccountID: "server-a",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache(),
            initialSources: [
                MediaSourceRef(accountID: "server-a", itemID: "10", kind: .movie),
                MediaSourceRef(accountID: "server-b", itemID: "10", kind: .movie)
            ],
            alternateProviderResolver: { $0 == "server-b" ? secondProvider : firstProvider }
        )
        await model.load()
        for _ in 0..<100 {
            if model.sources.first(where: { $0.accountID == "server-b" })?.edition == "Extended" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let loadedFirst = try XCTUnwrap(model.sources.first { $0.accountID == "server-a" })
        let loadedSecond = try XCTUnwrap(model.sources.first { $0.accountID == "server-b" })
        XCTAssertEqual(loadedFirst.edition, "Theatrical")
        XCTAssertEqual(loadedSecond.edition, "Extended")
        XCTAssertEqual(loadedFirst.versions.map(\.id), ["101", "101-large"])
        XCTAssertEqual(loadedSecond.versions.map(\.id), ["201", "201-large"])
    }

    func testGenericMergedOpenDoesNotGainEditionIntentFromFreshProviderDetail() async throws {
        let item = movie(account: "plex", edition: "Theatrical", mediaID: "101")
        let provider = FakeMediaProvider(allItems: [item])
        let merged = try XCTUnwrap(MediaItemMerger.merge([item]).first)
        let seed = DetailOpenEnvironment.initialItem(for: merged, selectedSource: nil)
        let model = ItemDetailViewModel(
            provider: provider, itemID: item.id, initialItem: seed,
            externalMetadataResolver: { _, region in
                ExternalTitleMetadata(
                    enrichment: MetadataEnrichment(),
                    availability: ExternalTitleAvailability(regionCode: region)
                )
            },
            sourceAccountID: "plex",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        await model.load()
        XCTAssertEqual(model.state.value?.item.edition, "Theatrical")
        XCTAssertNil(model.state.value?.item.editionOpeningSource)
    }

    func testSnapshotRoundTripKeepsEditionMetadataButNotPreviousVisitsChoice() throws {
        var item = movie(account: "plex", edition: "Extended", mediaID: "101")
        item.editionOpeningSource = .init(accountID: "plex", itemID: item.id)
        let source = MediaSourceRef(
            accountID: "plex", itemID: item.id, kind: .movie,
            versions: item.versions, edition: item.edition
        )
        let snapshot = DetailSnapshotCache.Snapshot(item: item, children: [], sources: [source])
        let restored = try JSONDecoder().decode(
            DetailSnapshotCache.Snapshot.self, from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(restored.item.edition, "Extended")
        XCTAssertNil(restored.item.editionOpeningSource)
        XCTAssertEqual(restored.sources[0].edition, "Extended")
        XCTAssertEqual(restored.sources[0].selectableVersions[0].editionLabel, "Extended")
        XCTAssertEqual(restored.sources[0].selectableVersions[0].playbackMediaSourceID, "101")
    }

    func testSparseAlternateRefreshKeepsKnownEditionOnSourceAndPicker() async throws {
        let primary = movie(account: "plex", edition: "Theatrical", mediaID: "101")
        var alternate = movie(account: "plex", edition: "Extended", mediaID: "201")
        alternate.id = "20"
        let known = reference(alternate)
        var sparse = alternate
        sparse.edition = nil
        sparse.versions = sparse.versions.map {
            var version = $0
            version.edition = nil
            return version
        }
        sparse.resumePosition = 321
        let provider = FakeMediaProvider(allItems: [primary, sparse])
        let model = ItemDetailViewModel(
            provider: provider, itemID: primary.id, initialItem: primary,
            sourceAccountID: "plex",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache(),
            initialSources: [reference(primary), known],
            alternateProviderResolver: { _ in provider }
        )
        await model.load()
        for _ in 0..<100 {
            if model.sources.first(where: { $0.itemID == "20" })?.resumePosition == 321 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let refreshed = try XCTUnwrap(model.sources.first { $0.itemID == "20" })
        XCTAssertEqual(refreshed.resumePosition, 321, "Fresh alternate response must have published")
        XCTAssertEqual(refreshed.edition, "Extended")
        XCTAssertEqual(refreshed.versions.map(\.editionLabel), ["Extended", "Extended"])
        let picker = DetailPlaybackSelection.versions(
            for: primary, sources: model.sources, activeAccountID: "plex"
        )
        XCTAssertEqual(picker.filter { $0.sourceItemID == "20" }.map(\.editionLabel),
                       ["Extended", "Extended"])
    }

    func testSparsePrimaryDiscoveryUsesRestoredTaggedEdition() async throws {
        let listed = movie(account: "plex", edition: "Director's Cut", mediaID: "101")
        let seed = DetailOpenEnvironment.initialItem(for: listed, selectedSource: nil)
        var sparse = listed
        sparse.sourceAccountID = nil
        sparse.edition = nil
        sparse.versions = sparse.versions.map {
            var version = $0
            version.edition = nil
            return version
        }
        var alternate = movie(account: "plex", edition: "Extended", mediaID: "201")
        alternate.id = "20"
        let alternateSource = reference(alternate)
        let provider = FakeMediaProvider(allItems: [sparse, alternate])
        let model = ItemDetailViewModel(
            provider: provider, itemID: listed.id, initialItem: seed,
            sourceAccountID: "plex",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache(),
            alternateProviderResolver: { _ in provider },
            crossServerSourceResolver: { primary in
                XCTAssertEqual(primary.sourceAccountID, "plex")
                XCTAssertEqual(primary.edition, "Director's Cut")
                return [
                    MediaSourceRef(accountID: "plex", itemID: "10", kind: .movie),
                    alternateSource
                ]
            }
        )
        await model.load()
        for _ in 0..<100 {
            if model.sources.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let discovered = try XCTUnwrap(model.sources.first { $0.itemID == "10" })
        XCTAssertEqual(discovered.edition, "Director's Cut")
        XCTAssertEqual(discovered.selectableVersions.map(\.editionLabel),
                       ["Director's Cut", "Director's Cut"])
    }

    func testSparseEditionRetentionRequiresExactOwnerAndMatchingFile() {
        let known = MediaSourceRef(
            accountID: "plex", itemID: "20", kind: .movie,
            versions: [MediaVersion(id: "201")], edition: "Extended"
        )
        var sparse = known
        sparse.edition = nil
        let same = ItemDetailViewModel.preservingEditionMetadata(in: sparse, from: known)
        XCTAssertEqual(same.edition, "Extended")
        XCTAssertEqual(same.versions[0].editionLabel, "Extended")
        for (account, item) in [("other-server", "20"), ("plex", "other-item")] {
            var foreign = sparse
            foreign.accountID = account
            foreign.itemID = item
            let result = ItemDetailViewModel.preservingEditionMetadata(in: foreign, from: known)
            XCTAssertNil(result.edition)
            XCTAssertNil(result.versions[0].editionLabel)
        }
        sparse.versions.append(MediaVersion(id: "299"))
        let mixed = ItemDetailViewModel.preservingEditionMetadata(in: sparse, from: known)
        XCTAssertNil(mixed.edition, "A source fallback must not label the newly replaced file")
        XCTAssertEqual(mixed.selectableVersions[0].editionLabel, "Extended")
        XCTAssertNil(mixed.selectableVersions[1].editionLabel)
    }

    func testFreshNonblankEditionsOverrideKnownLabelsAndBlankMetadataRetainsThem() {
        let known = MediaSourceRef(
            accountID: "plex", itemID: "20", kind: .movie,
            versions: [MediaVersion(id: "201", edition: "Extended")], edition: "Extended"
        )
        var fresh = known
        fresh.edition = "Final Cut"
        fresh.versions[0].edition = nil
        var result = ItemDetailViewModel.preservingEditionMetadata(in: fresh, from: known)
        XCTAssertEqual(result.edition, "Final Cut")
        XCTAssertEqual(result.versions[0].editionLabel, "Final Cut")
        fresh.edition = nil
        fresh.versions[0].edition = "Theatrical"
        result = ItemDetailViewModel.preservingEditionMetadata(in: fresh, from: known)
        XCTAssertNil(result.edition, "Do not retain a source label contradicting explicit fresh metadata")
        XCTAssertEqual(result.versions[0].editionLabel, "Theatrical")
        fresh.edition = "  "
        fresh.versions[0].edition = "\n"
        result = ItemDetailViewModel.preservingEditionMetadata(in: fresh, from: known)
        XCTAssertEqual(result.edition, "Extended")
        XCTAssertEqual(result.versions[0].editionLabel, "Extended")
    }

    func testSyntheticItemIdentityAloneDoesNotProveItsLoneFileIsUnchanged() {
        let known = MediaSourceRef(
            accountID: "plex", itemID: "20", kind: .movie,
            versions: [MediaVersion(id: "synth:20", fileName: "original.mkv")], edition: "Extended"
        )
        var fresh = known
        fresh.edition = nil
        XCTAssertEqual(ItemDetailViewModel.preservingEditionMetadata(
            in: fresh, from: known
        ).versions[0].editionLabel, "Extended")
        for filename in [String?.none, "replacement.mkv"] {
            fresh.versions[0].fileName = filename
            let result = ItemDetailViewModel.preservingEditionMetadata(in: fresh, from: known)
            XCTAssertNil(result.edition)
            XCTAssertNil(result.versions[0].editionLabel)
        }
    }

    private func reference(_ item: MediaItem) -> MediaSourceRef {
        MediaSourceRef(
            accountID: item.sourceAccountID!, itemID: item.id, kind: item.kind,
            versions: item.versions, edition: item.edition
        )
    }
}
