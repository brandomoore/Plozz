#if canImport(SwiftUI)
import CoreModels
import XCTest
@testable import CoreUI

@MainActor
final class DetailInformationPreviewTests: XCTestCase {
    func testSparseContentDoesNotReserveMissingSections() {
        let empty = MediaItem(id: "empty", title: "Video", kind: .video)
        XCTAssertEqual(DetailInformationSections(item: empty, horizontalInset: 24).sectionIDs, [])
        var rated = empty
        rated.ratings = [.init(source: .tmdb, value: 8, scale: .outOfTen)]
        XCTAssertEqual(DetailInformationSections(item: rated, horizontalInset: 24).sectionIDs, ["details"])
    }

    func testSectionsKeepOneReadingOrder() {
        let item = MediaItem(
            id: "film", title: "Film", kind: .movie, overview: "A synopsis.",
            productionYear: 2020, people: [.init(id: "director", name: "Director", kind: "Director")],
            ratings: [.init(source: .tmdb, value: 8, scale: .outOfTen)]
        )
        XCTAssertEqual(
            DetailInformationSections(item: item, horizontalInset: 24).sectionIDs,
            ["about", "details", "crew"]
        )
    }

    func testCrewPreviewRetainsEveryNameForMore() throws {
        let people = (1...60).map { MediaPerson(id: "\($0)", name: "Director \($0)", kind: "Director") }
        let item = MediaItem(id: "series", title: "Series", kind: .series, people: people)
        let group = try XCTUnwrap(DetailInformationSections(item: item, horizontalInset: 24)
            .informationGroups.first { $0.id == "crew" })
        let fact = try XCTUnwrap(group.facts.first)
        XCTAssertEqual(fact.listValues?.count, 60)
        XCTAssertTrue(fact.value.contains("Director 60"))
        XCTAssertFalse(fact.previewValue.contains("Director 4"))
        XCTAssertTrue(fact.needsExpansion(textTruncated: false))
    }

    func testTagsAreNotSilentlyDiscardedAfterSixteen() throws {
        let tags = (1...30).map { "Tag \($0)" }
        let item = MediaItem(id: "film", title: "Film", kind: .movie, tags: tags)
        let group = try XCTUnwrap(DetailInformationSections(item: item, horizontalInset: 24)
            .informationGroups.first { $0.id == "details" })
        let fact = try XCTUnwrap(group.facts.first { $0.id == "tags" })
        XCTAssertEqual(fact.listValues, tags)
        XCTAssertTrue(fact.value.contains("Tag 30"))
        XCTAssertTrue(fact.needsExpansion(textTruncated: false))
    }

    func testShortValuesDoNotOfferRedundantExpansion() {
        let fact = InformationFact(id: "runtime", label: "Runtime", value: "2h")
        XCTAssertFalse(fact.needsExpansion(textTruncated: false))
        XCTAssertTrue(fact.needsExpansion(textTruncated: true))
    }

    func testLongFactGroupsRetainTheirCompleteData() {
        let facts = (1...20).map { InformationFact(id: "\($0)", label: "Released", value: "Date \($0)") }
        let group = InformationGroup(id: "availability", title: "Release & Availability", facts: facts)
        XCTAssertEqual(group.previewFacts.count, 9)
        XCTAssertEqual(group.facts.count, 20)
        XCTAssertTrue(group.hasOmittedFacts)
    }

    func testCastPreviewLimitLeavesTheFullInputIntact() {
        XCTAssertEqual(DetailPreviewLimits.cast, 12)
        let people = (1...30).map { MediaPerson(id: "\($0)", name: "Person \($0)", kind: "Actor") }
        XCTAssertEqual(people.prefix(DetailPreviewLimits.cast).count, 12)
        XCTAssertEqual(people.count, 30)
    }

    func testRequiredAvailabilityAttributionStaysInThePreview() {
        var facts = (1...20).map { InformationFact(id: "\($0)", label: "Released", value: "Date \($0)") }
        facts.append(InformationFact(
            id: "attribution", label: "Availability Data", value: "JustWatch", isRequiredAttribution: true
        ))
        let group = InformationGroup(id: "availability", title: "Release & Availability", facts: facts)
        XCTAssertEqual(group.previewFacts.count, 9)
        XCTAssertEqual(group.previewFacts.last?.value, "JustWatch")
        XCTAssertEqual(group.facts.count, 21)
        XCTAssertTrue(group.hasOmittedFacts)
    }

    func testVisibleServiceLogosDoNotPretendTheirNamesWereHidden() {
        let names = ["One", "Two", "Three", "Four"]
        let logos = names.map {
            WatchProviderLogo(id: $0, name: $0, url: URL(string: "https://example.invalid/logo.png")!)
        }
        var fact = InformationFact(id: "streaming", label: "Streaming", value: names.joined(),
                                   listValues: names, logos: logos)
        XCTAssertFalse(fact.hasOmittedValues)
        fact.listValues?.append("No logo")
        XCTAssertTrue(fact.hasOmittedValues)
    }
}
#endif
