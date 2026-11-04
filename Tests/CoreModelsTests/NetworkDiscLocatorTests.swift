import CoreModels
import XCTest

final class NetworkDiscLocatorTests: XCTestCase {
    private let revision = CredentialRevision()

    private func file(_ path: String, account: String = "fixture") throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: account, sourceID: account, credentialRevision: revision, relativePath: path,
            representation: .init(
                size: 1024, identity: .init(kind: .strongETag, value: "\"fixture\""), consistency: .changeDetecting
            ),
            formatHint: .init(container: "m2ts")
        )
    }

    func testManifestSupportsMixedCaseAndSourceRootInsideBDMV() throws {
        for root in ["Movie/bDmV/", ""] {
            let anchor = try file(root + "INDEX.bdmv")
            let disc = try NetworkDiscLocator(anchor: anchor, files: [
                .init(path: "BDMV/INDEX.bdmv", locator: anchor),
                .init(path: "BDMV/STREAM/00001.m2ts", locator: file(root + "STREAM/00001.m2ts"))
            ])
            XCTAssertTrue(PlaybackSource.networkDisc(disc).requiresNetworkFileResolver)
            XCTAssertNil(PlaybackSource.networkDisc(disc).publicURL)
        }
    }

    func testManifestRejectsCrossAccountCrossDirectoryAndCaseAliases() throws {
        let anchor = try file("Movie/BDMV/index.bdmv")
        let index = try NetworkDiscLocator.File(path: "BDMV/index.bdmv", locator: anchor)
        for clip in [
            try file("Movie/BDMV/STREAM/00001.m2ts", account: "other"),
            try file("Other/BDMV/STREAM/00001.m2ts")
        ] {
            XCTAssertThrowsError(try NetworkDiscLocator(anchor: anchor, files: [
                index, .init(path: "BDMV/STREAM/00001.m2ts", locator: clip)
            ]))
        }
        XCTAssertThrowsError(try NetworkDiscLocator(anchor: anchor, files: [
            index, .init(path: "bdmv/INDEX.BDMV", locator: anchor)
        ]))
    }
}
