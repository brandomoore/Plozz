#if canImport(AetherEngine)
import CoreModels
import Foundation
import MediaTransportCore
import XCTest
@testable import EnginePlozzigen

final class TransportDiscDirectoryReaderTests: XCTestCase {
    private struct SuspendedResolver: MediaTransportNetworkFileResolving {
        let started: XCTestExpectation
        let cancelled: XCTestExpectation
        func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
                throw MediaTransportError.timeout
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
    }

    func testStopUnblocksPendingFileOpenAndDrainsItsResolver() async throws {
        let index = try NetworkFileLocator(
            accountID: "fixture", sourceID: "fixture", credentialRevision: CredentialRevision(),
            relativePath: "Movie/BDMV/index.bdmv",
            representation: .init(
                size: 40, identity: .init(kind: .strongETag, value: "\"index\""), consistency: .changeDetecting
            ),
            formatHint: .init(container: "bdmv")
        )
        let locator = try NetworkDiscLocator(anchor: index, files: [.init(path: "BDMV/index.bdmv", locator: index)])
        let started = expectation(description: "resolver started")
        let cancelled = expectation(description: "resolver cancelled")
        let returned = expectation(description: "engine I/O worker unblocked")
        let folder = TransportDiscDirectoryReader(
            locator: locator, resolver: SuspendedResolver(started: started, cancelled: cancelled)
        )
        XCTAssertNotNil(folder.makeIndependentReader())
        let selected = folder.selectingPlaylist(3)
        XCTAssertEqual(selected.preferredPlaylist, "00003.mpls")
        XCTAssertEqual(
            (selected.makeIndependentReader() as? TransportDiscDirectoryReader)?.preferredPlaylist,
            "00003.mpls"
        )
        selected.close()
        XCTAssertNil(folder.preferredPlaylist, "A menu selection must not alter direct-play readers")
        XCTAssertNil(folder.openDiscFile("BDMV/STREAM/missing.m2ts"))
        DispatchQueue.global().async {
            XCTAssertNil(folder.openDiscFile("bdmv/INDEX.BDMV"))
            returned.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        folder.closeAllReaders()
        await fulfillment(of: [returned, cancelled], timeout: 3)
        await folder.waitForFinalShutdown()
        XCTAssertNil(folder.makeIndependentReader())
        XCTAssertNil(folder.openDiscFile("BDMV/index.bdmv"))
    }
}
#endif
