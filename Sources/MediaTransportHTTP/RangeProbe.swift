import CoreModels
import Foundation

/// Case-insensitive HTTP header helpers shared by the range/probe logic.
public enum HTTPHeaderUtilities {
    /// Normalizes `HTTPURLResponse.allHeaderFields` (`[AnyHashable: Any]`,
    /// case varies by server) into a lower-cased-key `[String: String]` for
    /// reliable lookup.
    public static func normalizedHeaders(from allHeaderFields: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in allHeaderFields {
            guard let keyString = key as? String else { continue }
            result[keyString.lowercased()] = "\(value)"
        }
        return result
    }

    /// Same normalization for an already-`[String: String]` header map
    /// (e.g. one built by hand in a test).
    public static func normalizedHeaders(from headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            result[key.lowercased()] = value
        }
        return result
    }
}

/// A parsed `Content-Range: bytes start-end/total` response header. A
/// missing or `*` (unknown) total is treated as unparsable — this module
/// requires an exact total on every bounded read, never an approximate one.
struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64

    static func parse(_ value: String) -> ContentRange? {
        let unitAndRange = value.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard unitAndRange.count == 2,
              unitAndRange[0].lowercased() == "bytes" else {
            return nil
        }
        let remainder = unitAndRange[1]
        let parts = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] != "*", let total = Int64(parts[1]) else { return nil }

        let rangeParts = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeParts.count == 2, let start = Int64(rangeParts[0]), let end = Int64(rangeParts[1]) else {
            return nil
        }
        guard start >= 0, end >= start, end < total, total > 0 else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }
}

/// A validator from the actual GET representation, not its DAV listing.
/// Modification dates detect changes at HTTP-date (one-second) precision;
/// they do not provide the byte-identity guarantee of a strong ETag.
public enum RangeValidator: Equatable, Sendable {
    case strongETag(ETag)
    case lastModified(Date)
}

/// Result of successfully probing a resource for range/seek support.
public struct RangeProbeResult: Equatable, Sendable {
    public let validator: RangeValidator
    public let totalLength: Int64
    public let resourceURL: URL
    public let lastModified: Date?
    /// Optional, completely validated prefix retained only for this source lease.
    public let initialData: Data
    let usesAnonymousSession: Bool

    public var etag: ETag? {
        guard case .strongETag(let etag) = validator else { return nil }
        return etag
    }

    public init(etag: ETag, totalLength: Int64, resourceURL: URL) {
        self.init(validator: .strongETag(etag), totalLength: totalLength, resourceURL: resourceURL)
    }

    init(
        validator: RangeValidator,
        totalLength: Int64,
        resourceURL: URL,
        lastModified: Date? = nil,
        usesAnonymousSession: Bool = false,
        initialData: Data = Data()
    ) {
        self.validator = validator
        self.totalLength = totalLength
        self.resourceURL = resourceURL
        if case .lastModified(let date) = validator {
            self.lastModified = date
        } else {
            self.lastModified = lastModified
        }
        self.usesAnonymousSession = usesAnonymousSession
        self.initialData = initialData
    }
}

/// Builds and validates the two request/response pairs a safe ranged read
/// needs: an initial bounded probe that establishes a validator and the
/// resource's total length, and every subsequent bounded read, which must
/// reuse it as an `If-Match` or `If-Unmodified-Since` precondition.
///
/// All of this is pure request-building / response-validation logic with no
/// I/O, so it is exhaustively unit-testable against hand-built
/// status/header/body-length fixtures without a real server.
public enum RangeProbe {
    // MARK: - Probe (establishes seekability)

    // Some SabreDAV servers interpret an end offset of zero as an open-ended range.
    static let probeByteCount = 2
    public static let initialReadByteCount = 256 * 1024

    /// Two bytes by default, or a 256 KiB initial playback window when requested.
    /// Always identity encoding; no precondition before the GET validator is known.
    public static func probeRequest(url: URL, prefetch: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let length = prefetch ? initialReadByteCount : probeByteCount
        request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// Validates a probe response. Success requires: `206` (not `200` — a
    /// server that ignores `Range` and returns the whole body is not
    /// seekable by this module's definition), a strong `ETag` or valid
    /// `Last-Modified`, a matching `Content-Range`, and the entire requested prefix,
    /// clamped only at EOF.
    public static func validateProbe(
        status: Int,
        headers: [String: String],
        bodyLength: Int,
        resourceURL: URL,
        prefetch: Bool = false
    ) -> Result<RangeProbeResult, TransportError> {
        if status == 412 {
            return .failure(.sourceChanged(reason: "412 Precondition Failed during range probe"))
        }
        if status == 200 {
            return .failure(.rangeNotSupported(reason: "server returned 200 OK — ignored the Range request, not seekable"))
        }
        guard status == 206 else {
            return .failure(.rangeNotSupported(reason: "expected 206 Partial Content for probe, got \(status)"))
        }

        let normalized = HTTPHeaderUtilities.normalizedHeaders(from: headers)
        if let contentEncoding = normalized["content-encoding"],
           contentEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            return .failure(.rangeValidationFailed(reason: "range response used a content encoding"))
        }
        let lastModified = normalized["last-modified"].flatMap(HTTPDate.parse)
        let validator: RangeValidator
        if let raw = normalized["etag"], let etag = ETag(headerValue: raw), etag.isValidStrongValidator {
            validator = .strongETag(etag)
        } else if let date = lastModified {
            validator = .lastModified(date)
        } else {
            return .failure(.seekableRequiresValidator)
        }
        guard let contentRangeHeader = normalized["content-range"], let contentRange = ContentRange.parse(contentRangeHeader) else {
            return .failure(.rangeValidationFailed(reason: "missing/malformed Content-Range on probe"))
        }
        let expectedLength = Int(min(Int64(prefetch ? initialReadByteCount : probeByteCount), contentRange.total))
        guard contentRange.start == 0, contentRange.end == Int64(expectedLength - 1) else {
            return .failure(.rangeValidationFailed(reason: "probe Content-Range did not match the requested prefix"))
        }
        guard bodyLength == expectedLength else {
            return .failure(.rangeValidationFailed(reason: "probe body length \(bodyLength) != \(expectedLength)"))
        }
        return .success(
            RangeProbeResult(
                validator: validator,
                totalLength: contentRange.total,
                resourceURL: resourceURL,
                lastModified: lastModified
            )
        )
    }

    // MARK: - Bounded reads

    /// Default cap on a single ranged read — generous for a playback chunk
    /// while still bounding a caller (or a confused server) from requesting
    /// an unbounded amount into memory at once.
    public static let defaultMaxReadBytes: Int64 = 64 * 1024 * 1024

    /// Builds a bounded-read request for the inclusive byte range
    /// `[start, end]`, gated on the exact strong `ETag` learned from the
    /// probe (`If-Match`). Validates the range arithmetic (no negative/
    /// inverted ranges, no overflow, no exceeding `maxReadBytes`) before
    /// returning a request — this is the "reject before execution" half of
    /// range safety.
    public static func readRequest(
        url: URL,
        start: Int64,
        end: Int64,
        ifMatch etag: ETag,
        maxReadBytes: Int64 = defaultMaxReadBytes
    ) -> Result<URLRequest, TransportError> {
        readRequest(url: url, start: start, end: end, validator: .strongETag(etag), maxReadBytes: maxReadBytes)
    }

    public static func readRequest(
        url: URL,
        start: Int64,
        end: Int64,
        validator: RangeValidator,
        maxReadBytes: Int64 = defaultMaxReadBytes
    ) -> Result<URLRequest, TransportError> {
        guard start >= 0, end >= start else {
            return .failure(.rangeValidationFailed(reason: "invalid range \(start)-\(end)"))
        }
        let (sizeMinusOne, subtractOverflowed) = end.subtractingReportingOverflow(start)
        if subtractOverflowed {
            return .failure(.rangeValidationFailed(reason: "range size arithmetic overflowed"))
        }
        let (size, addOverflowed) = sizeMinusOne.addingReportingOverflow(1)
        if addOverflowed {
            return .failure(.rangeValidationFailed(reason: "range size arithmetic overflowed"))
        }
        guard size <= maxReadBytes else {
            return .failure(.rangeValidationFailed(reason: "requested range size \(size) exceeds max \(maxReadBytes)"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        switch validator {
        case .strongETag(let etag):
            guard etag.isValidStrongValidator else {
                return .failure(.seekableRequiresStrongETag)
            }
            request.setValue(etag.rawValue, forHTTPHeaderField: "If-Match")
        case .lastModified(let date):
            guard date.timeIntervalSince1970.isFinite else {
                return .failure(.seekableRequiresValidator)
            }
            request.setValue(HTTPDate.string(from: date), forHTTPHeaderField: "If-Unmodified-Since")
        }
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return .success(request)
    }

    /// Validates a bounded read's response against exactly what was
    /// requested. Every check is exact-match, not "close enough": status
    /// must be `206` (`200` is explicitly rejected), `Content-Range` must
    /// echo the requested start/end and the same total the probe saw, the
    /// `ETag` must be byte-identical to the one the probe pinned, and the
    /// body length must equal `end - start + 1`. `412`, a missing ETag, or
    /// an ETag that no longer matches all map to
    /// ``TransportError/sourceChanged(reason:)`` — the resource changed
    /// since it was probed, not a generic protocol failure.
    public static func validateRead(
        status: Int,
        headers: [String: String],
        bodyLength: Int,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotal: Int64,
        expectedETag: ETag
    ) -> Result<Void, TransportError> {
        validateRead(
            status: status, headers: headers, bodyLength: bodyLength,
            expectedStart: expectedStart, expectedEnd: expectedEnd, expectedTotal: expectedTotal,
            expectedValidator: .strongETag(expectedETag)
        )
    }

    public static func validateRead(
        status: Int,
        headers: [String: String],
        bodyLength: Int,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotal: Int64,
        expectedValidator: RangeValidator
    ) -> Result<Void, TransportError> {
        if status == 412 {
            return .failure(.sourceChanged(reason: "412 Precondition Failed — resource changed since it was probed"))
        }
        if status == 200 {
            return .failure(.rangeValidationFailed(reason: "server returned 200 OK instead of 206 Partial Content for a ranged read"))
        }
        guard status == 206 else {
            return .failure(.rangeValidationFailed(reason: "expected 206 Partial Content, got \(status)"))
        }

        let normalized = HTTPHeaderUtilities.normalizedHeaders(from: headers)
        if let contentEncoding = normalized["content-encoding"],
           contentEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            return .failure(.rangeValidationFailed(reason: "range response used a content encoding"))
        }
        switch expectedValidator {
        case .strongETag(let expectedETag):
            guard expectedETag.isValidStrongValidator else {
                return .failure(.seekableRequiresStrongETag)
            }
            guard let raw = normalized["etag"], let etag = ETag(headerValue: raw),
                  etag.isValidStrongValidator, etag == expectedETag else {
                return .failure(.sourceChanged(reason: "ETag missing or changed since the resource was probed"))
            }
        case .lastModified(let expectedDate):
            guard let raw = normalized["last-modified"], HTTPDate.parse(raw) == expectedDate else {
                return .failure(.sourceChanged(reason: "Last-Modified missing or changed since the resource was probed"))
            }
        }
        guard let contentRangeHeader = normalized["content-range"], let contentRange = ContentRange.parse(contentRangeHeader) else {
            return .failure(.rangeValidationFailed(reason: "missing/malformed Content-Range on bounded read"))
        }
        guard contentRange.start == expectedStart, contentRange.end == expectedEnd, contentRange.total == expectedTotal else {
            return .failure(
                .rangeValidationFailed(
                    reason: "Content-Range bytes \(contentRange.start)-\(contentRange.end)/\(contentRange.total) " +
                        "did not match requested bytes=\(expectedStart)-\(expectedEnd)/\(expectedTotal)"
                )
            )
        }
        guard expectedStart >= 0, expectedEnd >= expectedStart else {
            return .failure(.rangeValidationFailed(reason: "invalid expected range"))
        }
        let (sizeMinusOne, subtractOverflowed) = expectedEnd.subtractingReportingOverflow(expectedStart)
        let (expectedBodyLength, addOverflowed) = sizeMinusOne.addingReportingOverflow(1)
        guard !subtractOverflowed, !addOverflowed else {
            return .failure(.rangeValidationFailed(reason: "expected range size arithmetic overflowed"))
        }
        guard Int64(bodyLength) == expectedBodyLength else {
            return .failure(.rangeValidationFailed(reason: "body length \(bodyLength) != expected \(expectedBodyLength)"))
        }
        return .success(())
    }
}
