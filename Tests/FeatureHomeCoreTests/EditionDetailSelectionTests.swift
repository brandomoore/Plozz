import Foundation
import XCTest
import CoreModels
@testable import FeatureHomeCore

@MainActor
final class EditionDetailSelectionTests: XCTestCase {
    private func movie(
        _ id: String = "10",
        account: String = "plex",
        edition: String? = "Theatrical",
        height: Int = 720
    ) -> MediaItem {
        MediaItem(
            id: id, title: "Fixture", kind: .movie, resumePosition: 120,
            providerIDs: ["Tmdb": "99"], sourceAccountID: account,
            edition: edition,
            versions: [
                MediaVersion(id: "\(id)-small", edition: edition, height: height, videoCodec: "h264"),
                MediaVersion(id: "\(id)-large", edition: edition, height: height + 360, videoCodec: "h264")
            ]
        )
    }

    private func source(_ item: MediaItem) -> MediaSourceRef {
        MediaSourceRef(
            accountID: item.sourceAccountID!, itemID: item.id, kind: item.kind,
            versions: item.versions, edition: item.edition,
            resumePosition: item.resumePosition
        )
    }

    private func store(namespace: String? = nil, defaults: UserDefaults? = nil) -> VersionPreferenceStore {
        VersionPreferenceStore(
            defaults: defaults ?? UserDefaults(suiteName: "edition-tests-\(UUID().uuidString)")!,
            namespace: namespace
        )
    }

    func testIndividuallyListedEditionOpensItsOwnItemRatherThanHigherQualitySibling() {
        let clicked = movie()
        let better = movie("20", edition: "Extended", height: 1800)
        let selection = DetailOpenEnvironment.initialSourceSelection(
            for: clicked, isDiscovery: false, libraryOrigin: "plex",
            identitySources: { _ in [self.source(better), self.source(clicked)] },
            sourceLocality: { _ in .local }
        )
        XCTAssertEqual(selection.selected?.itemID, clicked.id)
        XCTAssertEqual(selection.sources.count, 2, "Other editions remain on the combined detail page")
        let seeded = DetailOpenEnvironment.initialItem(for: clicked, selectedSource: selection.selected)
        XCTAssertEqual(seeded.editionOpeningSource, .init(accountID: "plex", itemID: "10"))
        XCTAssertEqual(seeded.resumePosition, 120)
    }

    func testMergedHomeOrSearchCardStillChoosesRecommendedSource() throws {
        let clicked = movie()
        let better = movie("20", edition: "Extended", height: 1800)
        let merged = try XCTUnwrap(MediaItemMerger.merge([clicked, better]).first)
        let selection = DetailOpenEnvironment.initialSourceSelection(
            for: merged, isDiscovery: false, libraryOrigin: nil,
            identitySources: { _ in [] }, sourceLocality: { _ in .local }
        )
        XCTAssertTrue(merged.isMergedTitle)
        XCTAssertNil(DetailOpenEnvironment.openingSource(for: merged))
        XCTAssertEqual(selection.selected?.itemID, better.id)
    }

    func testSingletonAggregatedRepresentativeIsNotMistakenForAnEditionClickAfterIndexWarms() throws {
        let representative = try XCTUnwrap(MediaItemMerger.merge([movie()]).first)
        let better = movie("20", edition: "Extended", height: 1800)
        XCTAssertTrue(representative.sources.isEmpty)
        let selection = DetailOpenEnvironment.initialSourceSelection(
            for: representative, isDiscovery: false, libraryOrigin: nil,
            identitySources: { _ in [self.source(self.movie()), self.source(better)] },
            sourceLocality: { _ in .local }
        )
        XCTAssertEqual(selection.selected?.itemID, better.id)
        XCTAssertNil(DetailOpenEnvironment.openingSource(for: representative))
    }

    func testUnlabelledBlankAndExternalItemsDoNotInventEditionIntent() {
        for edition in [String?.none, "", "   "] {
            XCTAssertNil(DetailOpenEnvironment.openingSource(for: movie(edition: edition)))
        }
        var external = movie()
        external.locallyValidatedPlayableSource = false
        XCTAssertNil(DetailOpenEnvironment.openingSource(for: external))
        var unknownAccount = movie()
        unknownAccount.sourceAccountID = nil
        XCTAssertNil(DetailOpenEnvironment.openingSource(for: unknownAccount))
    }

    func testEditionSelfReferenceKeepsServerPresentationAndKnownFiles() {
        var clicked = movie()
        let full = source(clicked)
        clicked.versions = []
        var indexed = full
        indexed.providerKind = .plex
        indexed.serverName = "Living Room"
        let sources = DetailOpenEnvironment.initialSources(
            for: clicked, isDiscovery: false, identitySources: { _ in [indexed] }
        )
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].serverName, "Living Room")
        XCTAssertEqual(sources[0].providerKind, .plex)
        XCTAssertEqual(sources[0].versions, full.versions)
        XCTAssertEqual(sources[0].edition, clicked.edition)
    }

    func testClickedEditionConstrainsRecommendationAndRememberedShapeButNotExplicitPickerChoice() throws {
        let clicked = movie()
        let sibling = movie("20", edition: "Extended", height: 1800)
        let sources = [source(clicked), source(sibling)]
        let seeded = DetailOpenEnvironment.initialItem(for: clicked, selectedSource: sources[0])
        let versions = DetailPlaybackSelection.versions(
            for: seeded, sources: sources, activeAccountID: "plex"
        )
        let other = try XCTUnwrap(versions.first { $0.sourceItemID == sibling.id })
        let preferences = store()
        preferences.rememberVersion(other, forTitle: DetailPlaybackSelection.versionPreferenceKey(for: seeded))
        func selected(_ override: String?) -> MediaVersion? {
            let id = DetailPlaybackSelection.preferredVersionID(
                for: seeded, versions: versions, versionOverride: override,
                preferences: preferences, capabilities: .detected()
            )
            return versions.first { $0.id == id }
        }
        XCTAssertEqual(selected(nil)?.sourceItemID, clicked.id)
        XCTAssertEqual(selected("deleted-file")?.sourceItemID, clicked.id)
        XCTAssertEqual(selected(other.id)?.sourceItemID, sibling.id)

        let automatic = DetailPlaybackSelection.playItem(
            for: seeded, sources: sources, activeAccountID: "plex",
            versionID: selected(nil)?.id, explicit: false
        )
        XCTAssertEqual(automatic.id, clicked.id)
        XCTAssertEqual(automatic.selectedVersionID, "10-large")
        XCTAssertTrue(automatic.explicitSourceSelection, "Live best-source routing must honor the edition click")
    }

    func testExplicitServerSelectionOverridesOpeningAccount() {
        let clicked = movie()
        let other = movie("20", account: "jellyfin", height: 1800)
        let sources = [source(other), source(clicked)]
        let opening = MediaItemSourceIdentity(accountID: "plex", itemID: "10")
        let initial = DetailPlaybackSelection.preferredSource(
            sourceOverride: nil, libraryOrigin: nil, itemSourceAccountID: "plex",
            sources: sources, capabilities: .detected(), openingSource: opening
        )
        XCTAssertEqual(initial?.accountID, "plex")
        let picked = DetailPlaybackSelection.preferredSource(
            sourceOverride: "jellyfin", libraryOrigin: nil, itemSourceAccountID: "plex",
            sources: sources, capabilities: .detected(), openingSource: opening
        )
        XCTAssertEqual(picked?.accountID, "jellyfin")
    }

    func testExactPreferenceIsAccountScopedAndProfileScoped() throws {
        let first = movie(edition: nil)
        let second = movie(account: "another-server", edition: nil)
        let key = DetailPlaybackSelection.versionPreferenceKey(for: first)
        XCTAssertNotEqual(key, DetailPlaybackSelection.versionPreferenceKey(for: second))
        let defaults = UserDefaults(suiteName: "edition-profiles-\(UUID().uuidString)")!
        let mom = store(namespace: "mom", defaults: defaults)
        let dad = store(namespace: "dad", defaults: defaults)
        let versions = source(first).selectableVersions
        mom.rememberVersion(versions[0], forTitle: key)
        XCTAssertEqual(DetailPlaybackSelection.preferredVersionID(
            for: first, versions: versions, versionOverride: nil,
            preferences: mom, capabilities: .detected()
        ), versions[0].id)
        XCTAssertEqual(DetailPlaybackSelection.preferredVersionID(
            for: first, versions: versions, versionOverride: nil,
            preferences: dad, capabilities: .detected()
        ), versions[1].id)
        XCTAssertNil(mom.preferredVersionID(forTitle: DetailPlaybackSelection.versionPreferenceKey(for: second)))
    }

    func testLegacyRememberedDescriptorStillSelectsNamedEdition() throws {
        let first = movie()
        let sibling = movie("20", edition: "Extended", height: 1800)
        let versions = [source(first), source(sibling)].flatMap(\.selectableVersions)
        let preferences = store()
        preferences.setPreferredVersionDescriptor(
            .init(edition: "Theatrical", height: 720), forTitle: first.id
        )
        let selected = DetailPlaybackSelection.preferredVersionID(
            for: first, versions: versions, versionOverride: nil,
            preferences: preferences, capabilities: .detected()
        )
        XCTAssertEqual(versions.first { $0.id == selected }?.sourceItemID, first.id)
    }

    func testOneGenuineVersionStillHasNoPickerSelection() {
        let item = movie()
        let single = [source(item).selectableVersions[0]]
        XCTAssertNil(DetailPlaybackSelection.preferredVersionID(
            for: item, versions: single, versionOverride: single[0].id,
            preferences: store(), capabilities: .detected()
        ))
        XCTAssertFalse(MediaItem(id: "single", title: "Single", kind: .movie).hasMultipleVersions)
    }

    func testQualifiedRememberedFileResolvesBackToRawProviderVersionsAndPlaybackReady() {
        var item = movie()
        item.versions = [
            MediaVersion(id: "101", height: 1080, isDefault: true, videoCodec: "h264"),
            MediaVersion(id: "102", height: 1080, videoCodec: "h264")
        ]
        let qualified = source(item).selectableVersions
        let preferences = store()
        preferences.rememberVersion(
            qualified[1], forTitle: DetailPlaybackSelection.versionPreferenceKey(for: item)
        )
        XCTAssertEqual(MediaVersionDescriptor(version: item.versions[0]),
                       MediaVersionDescriptor(version: item.versions[1]))
        let raw = DetailPlaybackSelection.versions(for: item, sources: [], activeAccountID: nil)
        XCTAssertEqual(DetailPlaybackSelection.preferredVersionID(
            for: item, versions: raw, versionOverride: nil,
            preferences: preferences, capabilities: .detected()
        ), "102")
        XCTAssertEqual(DetailPlaybackSelection.playbackReady(
            item, preferences: preferences, capabilities: .detected()
        ).selectedVersionID, "102")
        XCTAssertEqual(DetailPlaybackSelection.preferredVersionID(
            for: item, versions: qualified, versionOverride: "102",
            preferences: store(), capabilities: .detected()
        ), qualified[1].id)
    }

    func testQualifiedRememberedFileRequiresTheSameAccountAndItemProof() {
        var original = movie()
        original.versions = [
            MediaVersion(id: "101", height: 1080, isDefault: true, videoCodec: "h264"),
            MediaVersion(id: "102", height: 1080, videoCodec: "h264")
        ]
        let remembered = source(original).selectableVersions[1]
        for owner in [
            MediaItemSourceIdentity(accountID: "other-server", itemID: original.id),
            MediaItemSourceIdentity(accountID: "plex", itemID: "other-item")
        ] {
            var item = original
            item.id = owner.itemID
            item.sourceAccountID = owner.accountID
            let preferences = store()
            preferences.rememberVersion(
                remembered, forTitle: DetailPlaybackSelection.versionPreferenceKey(for: item)
            )
            XCTAssertEqual(DetailPlaybackSelection.preferredVersionID(
                for: item, versions: item.versions, versionOverride: nil,
                preferences: preferences, capabilities: .detected()
            ), "101")
        }
        var unowned = original
        unowned.sourceAccountID = nil
        XCTAssertEqual(DetailPlaybackSelection.preferredVersionID(
            for: unowned, versions: unowned.versions, versionOverride: remembered.id,
            preferences: store(), capabilities: .detected()
        ), "101")
    }
}
