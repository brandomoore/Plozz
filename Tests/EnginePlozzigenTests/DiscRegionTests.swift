#if canImport(DiscNavigation)
import XCTest
import DiscNavigation

final class DiscRegionTests: XCTestCase {
    @MainActor
    func testVideoInspectionRejectsOversizedCatalogWithoutReadingOrStartingNavigation() async throws {
        var files = Dictionary(uniqueKeysWithValues: (0...1024).map {
            (String(format: "BDMV/PLAYLIST/%05d.mpls", $0), NSNumber(value: 64))
        })
        files["BDMV/index.bdmv"] = 40
        let session = try XCTUnwrap(HDMVSession(files: files, region: 1, readRange: { _, _, _ in
            XCTFail("An oversized catalog must be rejected before native parsing")
            return nil
        }))
        defer { session.stop() }
        let completion = expectation(description: "Catalog rejects excessive playlists")
        session.listVideos { videos, failure in
            XCTAssertNil(videos)
            XCTAssertNotNil(failure)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 3)
    }

    private func word(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    private func fixtures(region: UInt32, maskedWarning: Bool = true, extraBranch: Bool = false) -> (Data, Data) {
        var index = Array("INDX0200".utf8) + word(40) + [UInt8](repeating: 0, count: 28)
        index += word(38)
        var first = [UInt8](repeating: 0, count: 12)
        first[0] = 0x40
        var menu = first
        menu[7] = 1
        var title = first
        title[7] = 2
        index += first + menu + [0, 1] + title
        var startup: [[UInt32]] = [
            [0x50000001, 37, 0x80000014], [0x50400009, 37, 255],
            [0x48400300, 37, region], [0x21810000, 1, 0],
            [0x22800000, 5, 0], [0x21810000, 0, 0]
        ]
        if extraBranch { startup.insert([0x20810000, 5, 0], at: 0) }
        let loop: [[UInt32]] = [[0x22800000, 7, 0], [0x20810000, 0, 0]]
        var body: [UInt8] = [0, 0, 0, 0, 0, 3]
        for (i, commands) in [startup, loop, loop].enumerated() {
            body += [i == 2 && maskedWarning ? 0x60 : 0, 0, 0, UInt8(commands.count)]
            body += commands.flatMap { $0.flatMap(word) }
        }
        let objects = Array("MOBJ0200".utf8) + [UInt8](repeating: 0, count: 32) + word(UInt32(body.count)) + body
        return (Data(index), Data(objects))
    }

    func testInfersOnlyTheMatchedStartupRegion() {
        for region: UInt32 in [1, 2, 4] {
            let (index, objects) = fixtures(region: region)
            XCTAssertEqual(HDMVPreferredRegion(index, objects), region)
        }
    }

    func testUnrecognizedLogicStaysUnknown() {
        for fixture in [
            fixtures(region: 7), fixtures(region: 1, maskedWarning: false),
            fixtures(region: 1, extraBranch: true)
        ] {
            XCTAssertEqual(HDMVPreferredRegion(fixture.0, fixture.1), 0)
        }
    }

    func testTruncatedInputsCannotProduceARegion() {
        let (index, objects) = fixtures(region: 1)
        for end in 0..<index.count {
            XCTAssertEqual(HDMVPreferredRegion(index.prefix(end), objects), 0)
        }
        for end in 0..<objects.count {
            XCTAssertEqual(HDMVPreferredRegion(index, objects.prefix(end)), 0)
        }
    }

    func testJavaFirstPlayIsNotMisclassifiedAsHDMV() {
        var (index, objects) = fixtures(region: 1)
        index[44] = 0x80
        XCTAssertEqual(HDMVPreferredRegion(index, objects), 0)
    }

    @MainActor
    func testInvalidIndexSurfacesFailureRatherThanSelectingVideo() async throws {
        let failed = expectation(description: "Native navigation reports invalid metadata")
        failed.assertForOverFulfill = true
        let session = try XCTUnwrap(HDMVSession(
            files: ["BDMV/index.bdmv": 40], region: 1,
            readRange: { _, _, length in Data(repeating: 0, count: Int(length)) }
        ))
        defer { session.stop() }
        session.statusChanged = { reason in
            XCTAssertFalse(reason.isEmpty)
            failed.fulfill()
        }
        session.selectionChanged = { _, _, _ in
            XCTFail("Invalid navigation must not silently play a main title")
        }
        session.start()
        await fulfillment(of: [failed], timeout: 5)
        session.stop()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.drain { drained in
                XCTAssertTrue(drained)
                continuation.resume()
            }
        }
    }

    @MainActor
    func testSlowNativeShutdownReportsPendingWithoutReleasingItsOwner() async throws {
        let started = expectation(description: "Native read starts")
        let release = DispatchSemaphore(value: 0)
        let session = try XCTUnwrap(HDMVSession(
            files: ["BDMV/index.bdmv": 40], region: 1,
            readRange: { _, _, length in
                started.fulfill()
                _ = release.wait(timeout: .now() + 15)
                return Data(repeating: 0, count: Int(length))
            }
        ))
        defer { release.signal(); session.stop() }
        session.start()
        await fulfillment(of: [started], timeout: 5)
        session.stop()
        let pending = expectation(description: "Bounded drain reports pending")
        pending.assertForOverFulfill = true
        session.drain { drained in
            XCTAssertFalse(drained)
            pending.fulfill()
        }
        await fulfillment(of: [pending], timeout: 8)
        release.signal()
        let completed = expectation(description: "Native queue eventually drains")
        session.drain { drained in
            XCTAssertTrue(drained)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
    }
}
#endif
