import CoreModels
import Foundation
import XCTest
@testable import ProviderIPTV

final class IPTVLineupTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("catalog.sqlite")
    }

    private func live(_ id: String, title: String = "Channel", number: Int? = nil) -> IPTVRecord {
        IPTVRecord(
            item: .init(id: id, title: title, kind: .video, libraryID: "live"),
            channelNumber: number, isLive: true
        )
    }

    private func entries() -> [IPTVLineupEntry] {
        var full = live("live:1", title: "Nyheter Ünïcode 📺", number: 12)
        full.item.posterURL = URL(string: "https://logos.example.test/one.png?size=2")
        full.item.tags = ["News", "", "Sverige"]
        full.guideID = "news.se"
        full.guideName = "Nyheter"
        full.guideCountry = "SE"
        return [IPTVLineupEntry(full), IPTVLineupEntry(live("live:2", title: ""))]
    }

    private func replace(library: String, with records: [IPTVRecord], in catalog: IPTVCatalog) throws {
        try catalog.beginImport()
        defer { catalog.discardImport() }
        for record in records { try catalog.insert(record, into: .incoming) }
        try catalog.commitImport(library: library, scope: library)
    }

    func testLineupSurvivesEncodingWithAbsentAndEmptyFields() throws {
        let entries = entries()
        let data = try XCTUnwrap(IPTVLineupEntry.encode(entries))
        XCTAssertEqual(IPTVLineupEntry.decode(data), entries)
        XCTAssertEqual(IPTVLineupEntry.decode(try XCTUnwrap(IPTVLineupEntry.encode([]))), [])
    }

    func testDamagedLineupIsRejectedRatherThanPartlyRead() throws {
        let data = try XCTUnwrap(IPTVLineupEntry.encode(entries()))
        XCTAssertNil(IPTVLineupEntry.decode(Data()))
        XCTAssertNil(IPTVLineupEntry.decode(data.dropLast()))
        XCTAssertNil(IPTVLineupEntry.decode(data + [0]))
        var otherVersion = data
        otherVersion[otherVersion.startIndex] = 2
        XCTAssertNil(IPTVLineupEntry.decode(otherVersion))
        var inflatedCount = data
        inflatedCount.replaceSubrange(1..<5, with: [0xFE, 0xFF, 0xFF, 0xFF])
        XCTAssertNil(IPTVLineupEntry.decode(inflatedCount))
        for length in 0..<data.count { XCTAssertNil(IPTVLineupEntry.decode(data.prefix(length))) }
    }

    func testSavedLineupIsReturnedOnlyForItsCatalogueStateAndKey() throws {
        let url = try location()
        let catalog = try IPTVCatalog(url: url, key: key)
        XCTAssertNil(try catalog.lineup(token: "one"))
        try catalog.saveLineup(entries(), token: "one")
        XCTAssertEqual(try catalog.lineup(token: "one"), entries())
        XCTAssertNil(try catalog.lineup(token: "two"))

        let reopened = try IPTVCatalog(url: url, key: key)
        XCTAssertEqual(try reopened.lineup(token: "one"), entries())
        let otherKey = try IPTVCatalog(url: url, key: Data(repeating: 8, count: 32))
        XCTAssertNil(try otherKey.lineup(token: "one"))
    }

    func testChangingLiveRecordsDiscardsTheSavedLineup() throws {
        let catalog = try IPTVCatalog(url: location(), key: key)
        try replace(library: "live", with: [live("live:1")], in: catalog)

        try catalog.saveLineup(entries(), token: "one")
        let revision = try catalog.state("live-revision")
        try catalog.insert(live("live:1", title: "Renamed"))
        XCTAssertNil(try catalog.lineup(token: "one"))
        XCTAssertNotEqual(try catalog.state("live-revision"), revision)

        try catalog.saveLineup(entries(), token: "one")
        try replace(library: "live", with: [live("live:2")], in: catalog)
        XCTAssertNil(try catalog.lineup(token: "one"))

        try catalog.saveLineup(entries(), token: "one")
        try replace(library: "live", with: [], in: catalog)
        XCTAssertNil(try catalog.lineup(token: "one"), "Removing every channel changes the lineup too.")
    }

    func testChangingOtherLibrariesKeepsTheSavedLineup() throws {
        let catalog = try IPTVCatalog(url: location(), key: key)
        try replace(library: "live", with: [live("live:1")], in: catalog)
        try catalog.saveLineup(entries(), token: "one")
        let revision = try catalog.state("live-revision")

        let movie = IPTVRecord(item: .init(id: "movie:1", title: "Movie", kind: .movie, libraryID: "movies"))
        try replace(library: "movies", with: [movie], in: catalog)
        try catalog.insert(movie)

        XCTAssertEqual(try catalog.lineup(token: "one"), entries())
        XCTAssertEqual(try catalog.state("live-revision"), revision)
    }

    func testGuideLookupInvalidatesOnExternalCommitEvenAtSameRevisionAndCount() async throws {
        let (reader, writer, original) = try await guideLookupFixture()
        let savedRevision = try XCTUnwrap(writer.state("live-revision"))
        try writer.execute("BEGIN IMMEDIATE")
        try writer.insert(live("live:1", title: "Replacement"))
        try writer.setState("live-revision", savedRevision)
        try writer.execute("COMMIT")

        let current = try await reader.isCurrentGuideLineup(original)
        XCTAssertFalse(current)
        let latest = try await reader.savedGuideLineup()
        XCTAssertNotEqual(latest?.revision, original.revision)
        XCTAssertEqual(latest?.ordered.map(\.name), ["Replacement"])
        XCTAssertEqual(latest?.byID["live:1"]?.name, "Replacement")
    }

    func testGuideLookupRemainsCurrentAfterUnrelatedExternalCommit() async throws {
        let (reader, writer, original) = try await guideLookupFixture()
        try writer.setState("unrelated", "1")

        let matches = try await reader.guideLineupStillMatches(original)
        XCTAssertTrue(matches)
    }

    func testGuideLookupRemainsCurrentAfterIdenticalReimport() async throws {
        let (reader, writer, original) = try await guideLookupFixture()
        let savedRevision = try XCTUnwrap(writer.state("live-revision"))
        try replace(library: "live", with: [live("live:1", title: "Original")], in: writer)
        XCTAssertNotEqual(try XCTUnwrap(writer.state("live-revision")), savedRevision)

        let matches = try await reader.guideLineupStillMatches(original)
        XCTAssertTrue(matches)
    }

    func testGuideLineupContentComparisonRejectsChangesAtSameRevisionAndCount() async throws {
        let (reader, writer, original) = try await guideLookupFixture()
        let savedRevision = try XCTUnwrap(writer.state("live-revision"))
        try writer.execute("BEGIN IMMEDIATE")
        try writer.insert(live("live:1", title: "Replacement"))
        try writer.setState("live-revision", savedRevision)
        try writer.execute("COMMIT")

        let matches = try await reader.guideLineupStillMatches(original)
        XCTAssertFalse(matches)
    }

    func testUnversionedGuideLineupValidatesRecordsRatherThanUsingLegacySentinel() async throws {
        let (reader, writer, original) = try await guideLookupFixture()
        let stamp = try XCTUnwrap(writer.state("live"))
        let token = [stamp, "", "", "", "1"].joined(separator: "|")
        try writer.execute("BEGIN IMMEDIATE")
        try writer.insert(live("live:1", title: "Legacy replacement"))
        try writer.execute("DELETE FROM state WHERE key = 'live-revision'")
        try writer.saveLineup([IPTVLineupEntry(live("live:1", title: "Original"))], token: token)
        try writer.execute("COMMIT")
        let legacy = try await reader.savedGuideLineup()
        XCTAssertNotNil(original.revision)
        XCTAssertNil(legacy?.revision)
        XCTAssertEqual(legacy?.ordered.map(\.name), ["Legacy replacement"])
        XCTAssertEqual(legacy?.byID["live:1"]?.name, "Legacy replacement")
    }

    private func guideLookupFixture() async throws -> (IPTVClient, IPTVCatalog, IPTVClient.SavedGuideLineup) {
        let root = try location().deletingLastPathComponent()
        let credential = try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://fixture.test")),
            username: "fixture-user", password: "fixture-password"
        )
        let writer = try IPTVCatalog(url: root.appendingPathComponent(credential.identity.uuidString + ".sqlite"),
                                     key: credential.catalogKey)
        try replace(library: "live", with: [live("live:1", title: "Original")], in: writer)
        let reader = try IPTVClient(credential: credential, directory: root, configuration: .ephemeral)
        addTeardownBlock { await reader.cancel() }
        let saved = try await reader.savedGuideLineup()
        let original = try XCTUnwrap(saved)
        XCTAssertEqual(original.ordered.map(\.name), ["Original"])
        return (reader, writer, original)
    }

    func testAnotherConnectionCommitChangesTheDataVersion() throws {
        let url = try location()
        let catalog = try IPTVCatalog(url: url, key: key)
        let before = try catalog.dataVersion()
        try catalog.insert(live("live:1"))
        XCTAssertEqual(try catalog.dataVersion(), before, "A connection's own writes are tracked by the persisted lineup revision.")

        let other = try IPTVCatalog(url: url, key: key)
        try other.insert(live("live:2"))
        XCTAssertNotEqual(try catalog.dataVersion(), before)
    }
}
