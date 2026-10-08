import CoreModels
import Foundation
import XCTest

final class PlaybackFailureDiagnosticTests: XCTestCase {
    func testConsentRevocationDiscardsRetainedAttemptsEvenAfterReenabling() throws {
        let diagnostics = PlaybackFailureDiagnostics()
        let buffer = PlaybackFailureBuffer()
        XCTAssertNil(diagnostics.begin(layer: .iptvProxy, content: .live))
        diagnostics.start { buffer.append($0) }
        let stale = try XCTUnwrap(diagnostics.begin(layer: .iptvProxy, content: .live))
        diagnostics.stop()
        diagnostics.start { buffer.append($0) }
        stale.fail(stage: .response, reason: .authentication, httpStatus: 403)
        XCTAssertTrue(buffer.values.isEmpty)
        let current = try XCTUnwrap(diagnostics.begin(layer: .iptvProxy, content: .live))
        current.fail(stage: .response, reason: .authentication, httpStatus: 403)
        current.fail(stage: .body, reason: .network)
        XCTAssertEqual(buffer.values.count, 1)
        XCTAssertEqual(buffer.values.first?.httpStatus, 403)
    }

    func testCancellationAndUnboundedCodesCannotBecomeFailureReports() throws {
        let diagnostics = PlaybackFailureDiagnostics()
        let buffer = PlaybackFailureBuffer()
        diagnostics.start { buffer.append($0) }
        let attempt = try XCTUnwrap(diagnostics.begin(layer: .liveEngine, content: .live))
        attempt.fail(stage: .load, reason: .cancelled)
        XCTAssertTrue(buffer.values.isEmpty)
        attempt.fail(stage: .playback, engineFailure: .nativeItemFailed, domain: .avfoundation,
                     code: Int.max, httpStatus: Int.max)
        let diagnostic = try XCTUnwrap(buffer.values.first)
        XCTAssertNil(diagnostic.code)
        XCTAssertNil(diagnostic.httpStatus)
        XCTAssertTrue(diagnostic.isValid)
        XCTAssertEqual(diagnostic.engineFailure, .nativeItemFailed)
    }

    func testUnknownContentTypesAndDomainsNeverRetainFreeFormValues() {
        XCTAssertEqual(PlaybackFailureDiagnostic.Format(mimeType: "video/MP2T; private=secret"), .transportStream)
        XCTAssertEqual(PlaybackFailureDiagnostic.Format(mimeType: "text/html"), .html)
        XCTAssertEqual(PlaybackFailureDiagnostic.Format(mimeType: "https://private.test"), .other)
        XCTAssertEqual(PlaybackFailureDiagnostic.Domain("https://private.test"), .other)
    }
}

private final class PlaybackFailureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PlaybackFailureDiagnostic] = []
    var values: [PlaybackFailureDiagnostic] { lock.withLock { storage } }
    func append(_ value: PlaybackFailureDiagnostic) { lock.withLock { storage.append(value) } }
}
