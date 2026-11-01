import CoreModels
import Foundation
import MediaTransportCore
import MediaTransportHTTP

/// A random-access byte source over WebDAV/HTTP `Range` reads.
///
/// Reads outside the validated opening prefix use bounded GETs gated on its ETag
/// (`If-Match`) or Last-Modified (`If-Unmodified-Since`). Changed or missing
/// validators fail closed; date-based detection has one-second precision.
/// The delivery URL and validator remain fixed for this lease, even on expiry.
/// Reads are stateless (no server-side cursor/handle), so —
/// unlike SMB's channel-per-cursor source — no per-cursor isolation is needed:
/// a cancelled read cancels only its own `URLSessionTask`, and the owning
/// ``WebDAVMediaTransportSession`` drains the shared ephemeral session on
/// shutdown.
final class WebDAVByteSource: MediaTransportPreparationFinalizingByteSource, @unchecked Sendable {
    struct PreparedRange: Sendable {
        let offset: Int64
        let data: Data
    }

    private final class PreparedCache: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var ranges: [PreparedRange]
        private var byteCount: Int
        private var isFinished = false

        init(ranges: [PreparedRange], maximumBytes: Int) {
            self.ranges = ranges
            self.maximumBytes = maximumBytes
            self.byteCount = ranges.reduce(0) { $0 + $1.data.count }
        }

        func read(at offset: Int64, through end: Int64) -> Data? {
            let range = lock.withLock {
                ranges.first(where: {
                    offset >= $0.offset && offset - $0.offset < $0.data.count
                })
            }
            guard let range else { return nil }
            let upperBound = min(Int(end - range.offset) + 1, range.data.count)
            return range.data.subdata(in: Int(offset - range.offset)..<upperBound)
        }

        func insert(_ data: Data, at offset: Int64) {
            lock.withLock {
                guard !isFinished, !data.isEmpty, ranges.count < 64,
                      data.count <= maximumBytes - byteCount,
                      !ranges.contains(where: {
                          offset >= $0.offset
                              && offset - $0.offset + Int64(data.count) <= Int64($0.data.count)
                      }) else { return }
                ranges.append(PreparedRange(offset: offset, data: data))
                byteCount += data.count
            }
        }

        func finishPreparation() {
            lock.withLock { isFinished = true }
        }

        func clear() {
            lock.withLock {
                ranges.removeAll()
                byteCount = 0
                isFinished = true
            }
        }
    }

    let byteSize: Int64
    let preferredReadSize = 32 * 1024 * 1024

    private let client: WebDAVClient
    private let resourceURL: URL
    private let representation: RangeProbeResult
    private let sessionKey: TransportSessionKey
    private let credential: WebDAVCredential
    private let trustPolicy: TrustPolicy
    private let preparedCache: PreparedCache?

    init(
        client: WebDAVClient,
        representation: RangeProbeResult,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy,
        preparedRanges: [PreparedRange] = [],
        maximumCachedBytes: Int = 0
    ) {
        self.client = client
        self.resourceURL = representation.resourceURL
        self.representation = representation
        self.sessionKey = sessionKey
        self.credential = credential
        self.trustPolicy = trustPolicy
        self.byteSize = representation.totalLength
        self.preparedCache = maximumCachedBytes > 0
            ? PreparedCache(ranges: preparedRanges, maximumBytes: maximumCachedBytes) : nil
    }

    func preparingOpeningBytes(
        includeTail: Bool, maximumCachedBytes: Int
    ) async throws -> WebDAVByteSource {
        let tailWindow = 4 * 1024 * 1024
        let prefixWindow = includeTail ? 8 * 1024 * 1024 : tailWindow
        var prefix = representation.initialData
        let prefixLength = Int(min(byteSize, Int64(prefixWindow)))
        if prefix.count < prefixLength {
            let remainder = try await read(at: Int64(prefix.count), length: prefixLength - prefix.count)
            prefix.append(remainder)
        }
        var ranges = [PreparedRange(offset: 0, data: prefix)]
        if includeTail, byteSize > Int64(prefix.count) {
            let offset = max(Int64(prefix.count), byteSize - Int64(tailWindow))
            let tail = try await read(at: offset, length: tailWindow)
            ranges.append(PreparedRange(offset: offset, data: tail))
        }
        try Task.checkCancellation()
        return WebDAVByteSource(
            client: client, representation: representation, sessionKey: sessionKey,
            credential: credential, trustPolicy: trustPolicy, preparedRanges: ranges,
            maximumCachedBytes: maximumCachedBytes
        )
    }

    func allowingPreparation(maximumCachedBytes: Int) -> WebDAVByteSource {
        WebDAVByteSource(
            client: client, representation: representation, sessionKey: sessionKey,
            credential: credential, trustPolicy: trustPolicy,
            preparedRanges: representation.initialData.isEmpty
                ? [] : [PreparedRange(offset: 0, data: representation.initialData)],
            maximumCachedBytes: maximumCachedBytes
        )
    }

    static func warmOpeningBytes(source: any MediaTransportByteSource, includeTail: Bool) async throws {
        let tailWindow: Int64 = 4 * 1024 * 1024
        let prefixEnd = min(source.byteSize, includeTail ? 2 * tailWindow : tailWindow)
        var windows: [Range<Int64>] = [0..<prefixEnd]
        if includeTail, source.byteSize > prefixEnd {
            windows.append(max(prefixEnd, source.byteSize - tailWindow)..<source.byteSize)
        }
        for window in windows {
            var offset = window.lowerBound
            while offset < window.upperBound {
                try Task.checkCancellation()
                // Commit complete responses incrementally, never a partial body
                // of a larger HTTP range. Short cached reads are normal here.
                let length = Int(min(1024 * 1024, window.upperBound - offset))
                let data = try await source.read(at: offset, length: length)
                guard !data.isEmpty, data.count <= length else {
                    throw MediaTransportError.protocolViolation(reason: "invalid preparation read length")
                }
                offset += Int64(data.count)
            }
        }
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid WebDAV byte range")
        }
        // Reads at or past EOF are a normal end-of-stream signal (AVIO probes
        // past the end), not an error — return empty rather than asking the
        // server for an unsatisfiable range (which would be a 416).
        guard offset < byteSize else {
            return Data()
        }
        let lastByte = byteSize - 1
        let requestedEnd = offset.addingReportingOverflow(Int64(length) - 1)
        let end = requestedEnd.overflow ? lastByte : min(requestedEnd.partialValue, lastByte)

        do {
            try Task.checkCancellation()
            if end < representation.initialData.count {
                return representation.initialData.subdata(in: Int(offset)..<(Int(end) + 1))
            }
            if let cached = preparedCache?.read(at: offset, through: end) { return cached }
            let data = try await client.readRange(
                url: resourceURL, start: offset, end: end, representation: representation,
                sessionKey: sessionKey, credential: credential, trustPolicy: trustPolicy
            )
            // A completed, validated response remains useful if Play interrupts
            // its borrower immediately afterwards. Sealing still rejects writes.
            preparedCache?.insert(data, at: offset)
            try Task.checkCancellation()
            return data
        } catch {
            throw mapWebDAVError(error)
        }
    }

    func finishPreparation() {
        preparedCache?.finishPreparation()
    }

    func shutdown() async {
        preparedCache?.clear()
        // The ephemeral URLSession is owned by the transport registry and drained
        // when that session shuts down. Deterministic teardown is therefore the
        // session's responsibility; a cancelled in-flight read is torn down at
        // the URLSessionTask level by structured cancellation.
    }
}
