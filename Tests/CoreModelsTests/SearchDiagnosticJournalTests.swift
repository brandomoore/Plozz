import Foundation
import XCTest
@testable import CoreModels

final class SearchDiagnosticJournalTests: XCTestCase {
    func testConsentClearsHistoryAndRejectsLateCompletionsAcrossRestart() throws {
        let journal = SearchDiagnosticJournal()
        XCTAssertNil(journal.beginSearch())
        XCTAssertFalse(journal.export(scope: DiagnosticExportScope()).enabled)
        journal.start()
        let search = try XCTUnwrap(journal.beginSearch())
        let source = try XCTUnwrap(search.source(index: 0, provider: .silo, limit: 40, disabledLibraries: 0))
        XCTAssertEqual(journal.export(scope: DiagnosticExportScope()).entries.first?.facts.outcome, .running)
        journal.stop()
        journal.start()
        XCTAssertNil(search.source(index: 1, provider: .plex, limit: 40, disabledLibraries: 0))
        source.libraries(available: 4, excluded: 1)
        source.finish(error: .unauthorized)
        XCTAssertTrue(journal.export(scope: DiagnosticExportScope()).entries.isEmpty)
        journal.stop()
        XCTAssertFalse(journal.export(scope: DiagnosticExportScope()).enabled)
    }

    func testSeparateSourcesShareOnlyReportLocalSearchAlias() throws {
        let journal = SearchDiagnosticJournal()
        journal.start()
        let search = try XCTUnwrap(journal.beginSearch())
        let first = try XCTUnwrap(search.source(index: 0, provider: .silo, limit: 40, disabledLibraries: 3))
        let second = try XCTUnwrap(search.source(index: 1, provider: .plex, limit: 40, disabledLibraries: 0))
        first.finish(error: .unknown("private-search private-token private-server"))
        second.finish(resultCount: 7)
        first.finish(resultCount: 10)
        let report = journal.export(scope: DiagnosticExportScope())
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries[0].search, report.entries[1].search)
        XCTAssertEqual(report.entries[0].facts.outcome, .failed)
        XCTAssertEqual(report.entries[0].facts.reason, "unknown")
        XCTAssertEqual(report.entries[1].facts.outcome, .results)
        XCTAssertEqual(report.entries[1].facts.resultCount, 7)
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("started"))
    }

    func testCompletedAndActiveRecordsAreBoundedIndependently() throws {
        let journal = SearchDiagnosticJournal()
        journal.start()
        let search = try XCTUnwrap(journal.beginSearch())
        for index in 0..<40 {
            let source = try XCTUnwrap(search.source(index: index, provider: .silo, limit: 40, disabledLibraries: 0))
            source.finish(resultCount: 0)
        }
        var pending: [SearchDiagnosticJournal.Source] = []
        for index in 0..<32 {
            pending.append(try XCTUnwrap(search.source(index: index, provider: .plex, limit: 40, disabledLibraries: 0)))
        }
        XCTAssertNil(search.source(index: 32, provider: .plex, limit: 40, disabledLibraries: 0))
        let report = journal.export(scope: DiagnosticExportScope())
        XCTAssertEqual(report.entries.count, 64)
        XCTAssertEqual(report.dropped, 9)
        XCTAssertEqual(report.entries.filter { $0.facts.outcome == .running }.count, 32)
        pending.forEach { $0.finish(error: .cancelled) }
        let finished = journal.export(scope: DiagnosticExportScope())
        XCTAssertEqual(finished.entries.count, 32)
        XCTAssertTrue(finished.entries.allSatisfy { $0.facts.outcome == .cancelled })
    }

    func testPagesAndRequestsKeepBoundedTailAndTotalCounts() throws {
        let journal = SearchDiagnosticJournal()
        journal.start()
        let source = try XCTUnwrap(journal.beginSearch()?.source(index: 0, provider: .silo, limit: 400, disabledLibraries: 2))
        source.libraries(available: 3, excluded: 2)
        source.beginLibrary(index: 1)
        for index in 0..<20 {
            source.beginPage(limit: 200, usedCursor: index > 0)
            source.finishPage(rows: 20, hasMore: index < 19, hasNextCursor: index < 19, failure: nil)
            source.request(.init(
                route: .searchCatalog, method: "GET", elapsedMilliseconds: 25, httpStatus: 200,
                urlErrorCode: nil, bytes: 500, format: .json,
                requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000
            ))
        }
        source.finish(resultCount: 400)
        let facts = try XCTUnwrap(journal.export(scope: DiagnosticExportScope()).entries.first?.facts)
        XCTAssertEqual(facts.pages.count, 8)
        XCTAssertEqual(facts.requests.count, 8)
        XCTAssertEqual(facts.pageCount, 20)
        XCTAssertEqual(facts.requestCount, 20)
        XCTAssertEqual(facts.pages.first?.number, 13)
        XCTAssertEqual(facts.pages.last?.library, 1)
        XCTAssertEqual(facts.availableLibraryCount, 3)
        XCTAssertEqual(facts.excludedLibraryCount, 2)
        XCTAssertEqual(facts.librariesStarted, 1)
    }
}
