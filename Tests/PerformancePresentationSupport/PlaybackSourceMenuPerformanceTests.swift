import CoreModels
@testable import CoreUI
import FeatureHomeCore
import XCTest

@MainActor
final class PlaybackSourceMenuPerformanceTests: XCTestCase {
    func testPerformanceLegacyDetailSelectionComposition() async throws {
        try await measureDetailSelection(resolved: false)
    }

    func testPerformanceResolvedDetailSelectionComposition() async throws {
        try await measureDetailSelection(resolved: true)
    }

    private func measureDetailSelection(resolved: Bool) async throws {
        try PerformanceProbe.requireEnabled()
        let sources = (0..<4).map { account in
            MediaSourceRef(
                accountID: "account-\(account)", itemID: "movie-\(account)", kind: .movie,
                versions: (0..<8).map { file in
                    MediaVersion(id: "file-\(file)", height: 720 + file * 100, duration: 7200)
                }
            )
        }
        let item = MediaItem(
            id: "movie-0", title: "Selection performance", kind: .movie,
            runtime: 7200, sourceAccountID: "account-0", versions: sources[0].versions
        )
        let preferences = SelectionPreferences()
        let capabilities = MediaCapabilities.detected()
        let scenario = resolved ? "detail-selection-resolved" : "detail-selection-legacy"
        try await PerformanceProbe.measure(self, scenario: scenario) {
            var selections = 0
            var presentedVersions = 0
            var playTargets = 0
            for _ in 0..<32 {
                for source in sources {
                    for version in source.selectableVersions {
                        let choices: [MediaSourceRef]
                        let versions: [MediaVersion]
                        let selectedVersionID: String?
                        let play: MediaItem
                        if resolved {
                            let selection = DetailPlaybackSelection.resolve(
                                for: item, sources: sources, sourceOverride: source.accountID,
                                versionOverride: version.id, libraryOrigin: nil,
                                isLibraryOriginPinned: false, preferences: preferences,
                                capabilities: capabilities
                            )
                            choices = selection.serverChoices
                            versions = selection.versions
                            selectedVersionID = selection.selectedVersionID
                            play = selection.playItem
                        } else {
                            choices = DetailPlaybackSelection.serverChoices(from: sources)
                            let selected = DetailPlaybackSelection.preferredSource(
                                sourceOverride: source.accountID, libraryOrigin: nil,
                                itemSourceAccountID: item.sourceAccountID, sources: sources,
                                capabilities: capabilities, openingSource: item.editionOpeningSource
                            )
                            versions = DetailPlaybackSelection.versions(
                                for: item, sources: sources, activeAccountID: selected?.accountID
                            )
                            selectedVersionID = DetailPlaybackSelection.preferredVersionID(
                                for: item, versions: versions, versionOverride: version.id,
                                preferences: preferences, capabilities: capabilities, sources: sources
                            )
                            play = DetailPlaybackSelection.playItem(
                                for: item, sources: sources, activeAccountID: selected?.accountID,
                                versionID: selectedVersionID, explicit: true, explicitVersion: true
                            )
                        }
                        XCTAssertEqual(choices, sources)
                        XCTAssertEqual(Set(versions.map(\.id)), Set(source.selectableVersions.map(\.id)))
                        XCTAssertEqual(selectedVersionID, version.id)
                        XCTAssertEqual(play.sourceAccountID, source.accountID)
                        XCTAssertEqual(play.id, source.itemID)
                        XCTAssertEqual(play.selectedVersionID, version.providerMediaSourceID)
                        selections += 1
                        presentedVersions += versions.count
                        playTargets += 1
                    }
                }
            }
            return ["selections": selections, "presentedVersions": presentedVersions, "playTargets": playTargets]
        }
    }

    private struct SelectionPreferences: VersionPreferenceStoring {
        func preferredVersionID(forTitle titleID: String) -> String? { nil }
        func setPreferredVersionID(_ versionID: String?, forTitle titleID: String) {}
    }

    func testPerformanceVersionPresentation() async throws {
        try PerformanceProbe.requireEnabled()
        let versions = (0..<32).map { index in
            MediaVersion(
                id: "file-\(index)",
                name: "A.Movie.With.A.Long.Release.Name.2026.2160p.WEB-DL.DDP5.1.HEVC-Group\(index)",
                fileName: "A.Movie.With.A.Long.Release.Name.2026.Extended.Directors.Cut.2160p.mkv",
                height: 2160, bitrate: 40_000_000, sizeBytes: 12_000_000_000,
                duration: 7_200, videoRange: "HDR10", audioChannels: 6
            )
        }
        let expected = versions.map { version in
            let title = version.displayLabel
            let facts = Set((title ?? "").components(separatedBy: " · "))
            return (title, version.menuFacts.filter { !facts.contains($0) })
        }
        try await PerformanceProbe.measure(self, scenario: "source-menu-version-presentation") {
            var rows = 0
            for _ in 0..<32 {
                for (index, version) in versions.enumerated() {
                    let presentation = MediaVersion.PickerPresentation(version)
                    XCTAssertEqual(presentation.title, expected[index].0)
                    XCTAssertEqual(presentation.supplementalFacts, expected[index].1)
                    rows += 1
                }
            }
            return ["versions": versions.count, "menuUpdates": 32, "presentedRows": rows]
        }
    }

    func testVersionPresentationPreservesLabelsFactsAndUnknownFallback() {
        for name: String? in [nil, "", "Server Copy", "WEB-DL", "Extended Remux", "5.1", "2h"] {
            for height: Int? in [nil, 1080, 2160] {
                for edition: String? in [nil, "", "  ", "Director's Cut"] {
                    let version = MediaVersion(
                        id: "file", name: name, fileName: "Movie.Theatrical.mkv", edition: edition,
                        height: height, bitrate: 20_000_000, sizeBytes: 8_000_000_000,
                        duration: 7_200, videoRange: "HDR10", audioChannels: 6
                    )
                    let title = version.displayLabel
                    let facts = Set((title ?? "").components(separatedBy: " · "))
                    let result = MediaVersion.PickerPresentation(version)
                    XCTAssertEqual(result.title, title)
                    XCTAssertEqual(result.supplementalFacts, version.menuFacts.filter { !facts.contains($0) })
                }
            }
        }
        XCTAssertNil(MediaVersion.PickerPresentation(MediaVersion(id: "unknown")).title)
        XCTAssertEqual(MediaVersion.PickerPresentation(MediaVersion(id: "unknown")).supplementalFacts, [])
    }
}
