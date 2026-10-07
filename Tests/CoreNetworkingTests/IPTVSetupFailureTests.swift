import CoreModels
import CoreNetworking
import Foundation
import XCTest

final class IPTVSetupFailureTests: XCTestCase {
    func testKnownFailuresRetainOnlyTheirClosedCategoryAndNetworkCode() {
        let cases: [(any Error, IPTVSetupDiagnostic.Failure)] = [
            (URLError(.timedOut), .init(.timeout, networkCode: -1001)),
            (URLError(.notConnectedToInternet), .init(.offline, networkCode: -1009)),
            (URLError(.cannotFindHost), .init(.network, networkCode: -1003)),
            (URLError(.cancelled), .init(.cancelled)),
            (CancellationError(), .init(.cancelled)),
            (AppError.cancelled, .init(.cancelled)),
            (AppError.unknown("https://private.test/password"), .init(.other)),
            (AppError.invalidCredentials, .init(.authentication)),
            (AppError.rateLimited(retryAfter: 30), .init(.rateLimited)),
            (LiveTVSourceImportError.guideWithoutPlaylist, .init(.guideInsteadOfPlaylist)),
            (LiveTVSourceImportError.cacheFailed, .init(.storage)),
            (LiveTVSourceImportError.invalidPlaylist, .init(.malformed)),
            (LiveTVSourceImportError.emptyPlaylist, .init(.empty)),
            (LiveTVSourceImportError.redirectBlocked, .init(.redirectBlocked)),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .init(.storage)),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), .init(.fileUnavailable)),
            (NSError(domain: "private-hostname", code: 123, userInfo: [
                NSLocalizedDescriptionKey: "Private credentials", NSFilePathErrorKey: "/private/file"
            ]), .init(.other))
        ]
        for (error, expected) in cases {
            XCTAssertEqual(IPTVSetupDiagnostic.Failure.sanitized(error), expected)
        }
    }
}
