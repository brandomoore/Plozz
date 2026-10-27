import CoreModels
import Foundation
import XCTest
@testable import CoreNetworking

final class DiagnosticActivityExportTests: XCTestCase {
    func testAllFreeFormMessageContentAndUnknownCategoriesStayLocal() throws {
        let privateText = """
        https://alice:password@private.test:8096/items/private-id?api_key=secret
        192.168.1.5 2001:db8::5 account=private-account query=private-search
        /Users/private-person/Movies/private-title.mkv private@example.test
        """
        let now = Date()
        let entry = PlozzLog.LogEntry(
            id: UUID(), date: now, level: .error,
            category: "private-category", message: privateText
        )
        let export = PlozzLog.activityExport(entries: [entry], scope: DiagnosticExportScope(now: now))
        let data = try JSONEncoder().encode(export)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(body["entries"] as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(Set(record.keys), ["ageMilliseconds", "category", "level"])
        XCTAssertEqual(record["ageMilliseconds"] as? Int, 0)
        XCTAssertEqual(record["category"] as? String, "other")
        XCTAssertEqual(record["level"] as? String, "error")
        let text = String(decoding: data, as: UTF8.self)
        for value in ["private", "password", "secret", "192.168", "2001:db8", entry.id.uuidString] {
            XCTAssertFalse(text.contains(value), value)
            XCTAssertFalse(export.supportText.contains(value), value)
        }
        XCTAssertTrue(export.supportText.contains("message_text=excluded"))
    }

    func testCopyAndIssueActivityProjectionUsesTheSameSafeRepresentation() {
        let now = Date()
        let entries = [
            PlozzLog.LogEntry(id: UUID(), date: now, level: .info,
                             category: "networking", message: "query=private-search server=private.test"),
            PlozzLog.LogEntry(id: UUID(), date: now, level: .error,
                             category: "playback", message: "title=Private title token=private-token")
        ]
        let text = PlozzLog.privacyFilteredLogText(entries: entries)
        XCTAssertTrue(text.contains("category=networking level=info"))
        XCTAssertTrue(text.contains("category=playback level=error"))
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("Private"))
        let report = DiagnosticsReport(appVersion: "1.0", appBuild: "1", providers: "Jellyfin",
                                       repoURL: "https://github.com/example/example", recentLogTail: text)
        let body = URLComponents(string: report.newIssueURLString)?.queryItems?
            .first { $0.name == "body" }?.value ?? ""
        XCTAssertTrue(body.contains("message_text=excluded"))
        XCTAssertFalse(body.contains("private"))
        XCTAssertFalse(body.contains("Private"))
    }

    func testExportRemainsBoundedAndDoesNotEmitRawLinesEvenForHugeMessages() throws {
        let entry = PlozzLog.LogEntry(id: UUID(), date: Date(), level: .info, category: "app",
                                     message: String(repeating: "PRIVATE", count: 100_000))
        let export = PlozzLog.activityExport(entries: Array(repeating: entry, count: 1_000))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(export)) as? [String: Any])
        XCTAssertEqual((body["entries"] as? [Any])?.count, 500)
        XCTAssertFalse(export.supportText.contains("PRIVATE"))
    }
}
