import CoreModels
import XCTest
@testable import MediaTransportHTTP

final class RangeProbeTests: XCTestCase {
    private let url = URL(string: "https://nas.example.com/dav/movies/Show.mkv")!
    private let strongETag = ETag(headerValue: "\"strong-etag-1\"")!
    private let weakETag = ETag(headerValue: "W/\"weak-etag-1\"")!

    // MARK: - probeRequest

    func testProbeRequestAvoidsZeroEndOffsetAndSendsIdentityEncoding() {
        let request = RangeProbe.probeRequest(url: url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    // MARK: - validateProbe

    func testPrefetchProbeUsesABoundedPrefixWithoutRelaxingCacheOrEncoding() {
        let request = RangeProbe.probeRequest(url: url, prefetch: true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-262143")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testPrefetchProbeRequiresTheEntireRequestedPrefixClampedOnlyAtEOF() throws {
        for total in [1, 1000, RangeProbe.initialReadByteCount, 1_000_000] {
            let length = min(total, RangeProbe.initialReadByteCount)
            let headers = ["ETag": "\"strong\"", "Content-Range": "bytes 0-\(length - 1)/\(total)"]
            let probe = try RangeProbe.validateProbe(
                status: 206, headers: headers, bodyLength: length, resourceURL: url, prefetch: true
            ).get()
            XCTAssertEqual(probe.totalLength, Int64(total))
            for wrongLength in [length - 1, length + 1] {
                XCTAssertThrowsError(try RangeProbe.validateProbe(
                    status: 206, headers: headers, bodyLength: wrongLength, resourceURL: url, prefetch: true
                ).get())
            }
        }
        for headers in [
            ["ETag": "\"strong\"", "Content-Range": "bytes 0-1/1000000"],
            ["ETag": "\"strong\"", "Content-Range": "bytes 1-262144/1000000"],
            ["ETag": "W/\"weak\"", "Content-Range": "bytes 0-262143/1000000"],
            ["Content-Range": "bytes 0-262143/1000000"],
            ["ETag": "\"strong\"", "Content-Range": "bytes 0-262143/1000000", "Content-Encoding": "gzip"]
        ] {
            XCTAssertThrowsError(try RangeProbe.validateProbe(
                status: 206, headers: headers, bodyLength: RangeProbe.initialReadByteCount,
                resourceURL: url, prefetch: true
            ).get())
        }
        XCTAssertThrowsError(try RangeProbe.validateProbe(
            status: 200, headers: ["ETag": "\"strong\""], bodyLength: RangeProbe.initialReadByteCount,
            resourceURL: url, prefetch: true
        ).get())
    }

    func testValidateProbeSucceedsOn206WithStrongETagAndMatchingContentRange() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 0-1/1000"],
            bodyLength: 2,
            resourceURL: url
        )
        switch result {
        case .success(let probe):
            XCTAssertEqual(probe.etag, strongETag)
            XCTAssertEqual(probe.totalLength, 1000)
            XCTAssertEqual(probe.resourceURL, url)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testValidateProbeRejects200() {
        let result = RangeProbe.validateProbe(
            status: 200,
            headers: ["ETag": "\"e\""],
            bodyLength: 1000,
            resourceURL: url
        )
        guard case .failure(.rangeNotSupported) = result else {
            return XCTFail("expected rangeNotSupported for 200 OK probe response")
        }
    }

    func testValidateProbeRejectsWeakETag() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["ETag": "W/\"weak-etag-1\"", "Content-Range": "bytes 0-1/1000"],
            bodyLength: 2,
            resourceURL: url
        )
        guard case .failure(.seekableRequiresValidator) = result else {
            return XCTFail("expected a usable validator for a weak probe ETag")
        }
    }

    func testValidateProbeRejectsMissingETag() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["Content-Range": "bytes 0-1/1000"],
            bodyLength: 2,
            resourceURL: url
        )
        guard case .failure(.seekableRequiresValidator) = result else {
            return XCTFail("expected a usable validator when ETag header is absent")
        }
    }

    func testProbeUsesLastModifiedWhenETagIsMissingOrWeak() throws {
        let date = try XCTUnwrap(HTTPDate.parse("Wed, 14 Oct 2026 12:00:00 GMT"))
        for etag in [nil, "W/\"weak\""] {
            var headers = [
                "Last-Modified": "Wed, 14 Oct 2026 12:00:00 GMT",
                "Content-Range": "bytes 0-1/1000"
            ]
            headers["ETag"] = etag
            let probe = try RangeProbe.validateProbe(
                status: 206, headers: headers, bodyLength: 2, resourceURL: url
            ).get()
            XCTAssertEqual(probe.validator, .lastModified(date))
            XCTAssertNil(probe.etag)
            XCTAssertEqual(probe.totalLength, 1000)
        }
    }

    func testProbePrefersStrongETagOverLastModified() throws {
        let probe = try RangeProbe.validateProbe(
            status: 206,
            headers: [
                "ETag": strongETag.rawValue, "Last-Modified": "Wed, 14 Oct 2026 12:00:00 GMT",
                "Content-Range": "bytes 0-1/1000"
            ],
            bodyLength: 2, resourceURL: url
        ).get()
        XCTAssertEqual(probe.validator, .strongETag(strongETag))
        XCTAssertEqual(probe.lastModified, HTTPDate.parse("Wed, 14 Oct 2026 12:00:00 GMT"))
    }

    func testProbeRejectsInvalidLastModified() {
        for date in ["", "not a date", "Wed, 99 Oct 2026 12:00:00 GMT"] {
            let result = RangeProbe.validateProbe(
                status: 206, headers: ["Last-Modified": date, "Content-Range": "bytes 0-1/1000"],
                bodyLength: 2, resourceURL: url
            )
            guard case .failure(.seekableRequiresValidator) = result else {
                return XCTFail("invalid date must not enable unvalidated playback")
            }
        }
    }

    func testDateBasedReadSendsOnlyIfUnmodifiedSince() throws {
        let date = try XCTUnwrap(HTTPDate.parse("Wed, 14 Oct 2026 12:00:00 GMT"))
        let request = try RangeProbe.readRequest(
            url: url, start: 100, end: 199, validator: .lastModified(date)
        ).get()
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Unmodified-Since"), "Wed, 14 Oct 2026 12:00:00 GMT")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=100-199")
    }

    func testDateBasedReadRequiresUnchangedDateAndExactRange() throws {
        let date = try XCTUnwrap(HTTPDate.parse("Wed, 14 Oct 2026 12:00:00 GMT"))
        func validate(_ headers: [String: String], count: Int = 100, status: Int = 206) -> Result<Void, TransportError> {
            RangeProbe.validateRead(
                status: status, headers: headers, bodyLength: count,
                expectedStart: 100, expectedEnd: 199, expectedTotal: 1000,
                expectedValidator: .lastModified(date)
            )
        }
        let valid = ["Last-Modified": HTTPDate.string(from: date), "Content-Range": "bytes 100-199/1000"]
        XCTAssertNoThrow(try validate(valid).get())
        for changed in [nil, "Thu, 15 Oct 2026 12:00:00 GMT", "invalid"] {
            var headers = valid
            headers["Last-Modified"] = changed
            guard case .failure(.sourceChanged) = validate(headers) else {
                return XCTFail("changed or missing date must fail")
            }
        }
        for range in ["bytes 0-99/1000", "bytes 100-150/1000", "bytes 100-199/2000"] {
            var headers = valid
            headers["Content-Range"] = range
            XCTAssertThrowsError(try validate(headers).get())
        }
        XCTAssertThrowsError(try validate(valid, count: 99).get())
        XCTAssertThrowsError(try validate(valid, status: 200).get())
        guard case .failure(.sourceChanged) = validate([:], count: 0, status: 412) else {
            return XCTFail("date precondition failure must report a source change")
        }
    }

    func testHTTPDateAcceptsLegacyFormatsAndFormatsCanonicalHeader() throws {
        let date = try XCTUnwrap(HTTPDate.parse("Sun, 06 Nov 1994 08:49:37 GMT"))
        XCTAssertEqual(HTTPDate.parse("Sunday, 06-Nov-94 08:49:37 GMT"), date)
        XCTAssertEqual(HTTPDate.parse("Sun Nov  6 08:49:37 1994"), date)
        XCTAssertEqual(HTTPDate.string(from: date), "Sun, 06 Nov 1994 08:49:37 GMT")
    }

    func testValidateProbeRejectsMismatchedContentRange() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["ETag": "\"e\"", "Content-Range": "bytes 5-10/1000"],
            bodyLength: 2,
            resourceURL: url
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed when Content-Range doesn't match the probe")
        }
    }

    func testValidateProbeRejectsContentEncoding() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: [
                "ETag": "\"e\"",
                "Content-Range": "bytes 0-1/1000",
                "Content-Encoding": "gzip"
            ],
            bodyLength: 2,
            resourceURL: url
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed")
        }
    }

    func testValidateProbeAcceptsCaseInsensitiveRangeUnit() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["ETag": "\"e\"", "Content-Range": "Bytes 0-1/1000"],
            bodyLength: 2,
            resourceURL: url
        )
        guard case .success = result else {
            return XCTFail("expected a valid case-insensitive range unit")
        }
    }

    func testValidateProbeMaps412ToSourceChanged() {
        let result = RangeProbe.validateProbe(
            status: 412,
            headers: [:],
            bodyLength: 0,
            resourceURL: url
        )
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged for a 412 probe response")
        }
    }

    func testProbeAcceptsExactPrefixClampedOnlyAtEOF() throws {
        for total in [1, 2, 1000] {
            let length = min(total, 2)
            let result = try RangeProbe.validateProbe(
                status: 206,
                headers: ["ETag": "\"e\"", "Content-Range": "bytes 0-\(length - 1)/\(total)"],
                bodyLength: length, resourceURL: url
            ).get()
            XCTAssertEqual(result.totalLength, Int64(total))
        }
    }

    func testProbeRejectsShortOversizedAndEmptyPrefixes() {
        for (range, count) in [
            ("bytes 0-0/1000", 1), ("bytes 0-2/1000", 3),
            ("bytes 0-999/1000", 1000), ("bytes 0-1/1000", 1),
            ("bytes 0-1/1000", 3), ("bytes 0-0/1", 2), ("bytes */0", 0)
        ] {
            let result = RangeProbe.validateProbe(
                status: 206, headers: ["ETag": "\"e\"", "Content-Range": range],
                bodyLength: count, resourceURL: url
            )
            guard case .failure(.rangeValidationFailed) = result else {
                return XCTFail("Invalid probe accepted: \(range), \(count) bytes")
            }
        }
    }

    // MARK: - readRequest

    func testReadRequestSendsExactRangeIdentityEncodingAndIfMatch() {
        guard case .success(let request) = RangeProbe.readRequest(url: url, start: 100, end: 199, ifMatch: strongETag) else {
            return XCTFail("expected a valid read request")
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=100-199")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"strong-etag-1\"")
    }

    func testReadRequestRejectsInvertedRange() {
        guard case .failure(.rangeValidationFailed) = RangeProbe.readRequest(url: url, start: 200, end: 100, ifMatch: strongETag) else {
            return XCTFail("expected rangeValidationFailed for end < start")
        }
    }

    func testReadRequestRejectsNegativeStart() {
        guard case .failure(.rangeValidationFailed) = RangeProbe.readRequest(url: url, start: -1, end: 10, ifMatch: strongETag) else {
            return XCTFail("expected rangeValidationFailed for a negative start")
        }
    }

    func testReadRequestRejectsRangeExceedingMaxReadBytes() {
        let result = RangeProbe.readRequest(url: url, start: 0, end: 1_000, ifMatch: strongETag, maxReadBytes: 10)
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed when requested size exceeds maxReadBytes")
        }
    }

    func testReadRequestRejectsOverflowingRange() {
        let result = RangeProbe.readRequest(url: url, start: 0, end: Int64.max, ifMatch: strongETag)
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed for arithmetic overflow")
        }
    }

    func testReadRequestRejectsWeakETag() {
        let result = RangeProbe.readRequest(url: url, start: 0, end: 10, ifMatch: weakETag)
        guard case .failure(.seekableRequiresStrongETag) = result else {
            return XCTFail("expected seekableRequiresStrongETag when If-Match validator is weak")
        }
    }

    // MARK: - validateRead

    func testValidateReadSucceedsOnExactMatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 100-199/1000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .success = result else {
            return XCTFail("expected validateRead to succeed on an exact match")
        }
    }

    func testValidateReadRejects200() {
        let result = RangeProbe.validateRead(
            status: 200,
            headers: ["ETag": "\"strong-etag-1\""],
            bodyLength: 1000,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed when server ignores Range and returns 200")
        }
    }

    func testValidateReadRejectsContentRangeStartMismatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 0-99/1000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed on Content-Range start mismatch")
        }
    }

    func testValidateReadRejectsContentRangeEndMismatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 100-150/1000"],
            bodyLength: 51,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed on Content-Range end mismatch")
        }
    }

    func testValidateReadRejectsContentRangeTotalMismatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 100-199/2000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed on Content-Range total mismatch (source resized)")
        }
    }

    func testValidateReadRejectsBodyLengthMismatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 100-199/1000"],
            bodyLength: 42,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed when body length doesn't match the range size")
        }
    }

    func testValidateReadMapsETagMismatchToSourceChanged() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"different-etag\"", "Content-Range": "bytes 100-199/1000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged when the ETag no longer matches the probe")
        }
    }

    func testValidateReadMaps412ToSourceChanged() {
        let result = RangeProbe.validateRead(
            status: 412,
            headers: [:],
            bodyLength: 0,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged for a 412 Precondition Failed bounded read")
        }
    }

    func testValidateReadRejectsMissingETagOnResponse() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["Content-Range": "bytes 100-199/1000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged when the bounded-read response carries no ETag at all")
        }
    }

    func testValidateReadRejectsContentEncoding() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: [
                "ETag": "\"strong-etag-1\"",
                "Content-Range": "bytes 0-9/100",
                "Content-Encoding": "br"
            ],
            bodyLength: 10,
            expectedStart: 0,
            expectedEnd: 9,
            expectedTotal: 100,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed")
        }
    }

    func testValidateReadRejectsWeakExpectedAndResponseETags() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "W/\"weak-etag-1\"", "Content-Range": "bytes 0-9/100"],
            bodyLength: 10,
            expectedStart: 0,
            expectedEnd: 9,
            expectedTotal: 100,
            expectedETag: weakETag
        )
        guard case .failure(.seekableRequiresStrongETag) = result else {
            return XCTFail("expected seekableRequiresStrongETag")
        }
    }
}
