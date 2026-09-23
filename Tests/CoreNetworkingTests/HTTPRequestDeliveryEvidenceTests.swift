import CoreModels
import Foundation
import XCTest
@testable import CoreNetworking
#if canImport(Darwin)
import Darwin
#endif

final class HTTPRequestDeliveryEvidenceTests: XCTestCase {
    func testMissingMetricsNeverProveNonDelivery() {
        let evidence = HTTPRequestDeliveryEvidence()
        XCTAssertFalse(evidence.confirmedNotSent)
        evidence.recordTransactions(requestStarted: [])
        XCTAssertFalse(evidence.confirmedNotSent)
    }

    func testEveryAttemptMustHaveStoppedBeforeHTTPTransmission() {
        let evidence = HTTPRequestDeliveryEvidence()
        evidence.recordTransactions(requestStarted: [false])
        XCTAssertTrue(evidence.confirmedNotSent)
        evidence.recordTransactions(requestStarted: [true, false])
        XCTAssertFalse(evidence.confirmedNotSent)
        evidence.recordTransactions(requestStarted: [false])
        XCTAssertFalse(evidence.confirmedNotSent, "A later failed connection cannot erase a possibly delivered attempt.")
    }

    func testSentBodyOverridesIncompleteTransactionTiming() {
        let evidence = HTTPRequestDeliveryEvidence()
        evidence.recordTransactions(requestStarted: [false])
        evidence.recordBodyBytes(1)
        XCTAssertFalse(evidence.confirmedNotSent)
    }

    #if canImport(Darwin)
    func testRealRefusedConnectionCarriesNonDeliveryProofOnlyWhenRequested() async throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        guard socketFD >= 0 else { return }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        XCTAssertEqual(named, 0)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = URLSessionHTTPClient(session: session)
        var endpoint = Endpoint(method: .post, path: "/refresh", body: Data("test".utf8), redirectPolicy: .sameOrigin)
        endpoint.reportsUndeliveredRequests = true
        do {
            _ = try await client.send(endpoint, baseURL: url)
            XCTFail("A bound non-listening socket cannot accept a request.")
        } catch let error as HTTPRequestNotSentError {
            XCTAssertEqual(error.underlying, .serverUnreachable)
        }
        endpoint.reportsUndeliveredRequests = false
        do {
            _ = try await client.send(endpoint, baseURL: url)
            XCTFail("The connection should still be refused.")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
    }
    #endif
}
