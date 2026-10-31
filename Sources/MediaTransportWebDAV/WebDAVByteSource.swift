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
final class WebDAVByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64
    let preferredReadSize = 32 * 1024 * 1024

    private let client: WebDAVClient
    private let resourceURL: URL
    private let representation: RangeProbeResult
    private let sessionKey: TransportSessionKey
    private let credential: WebDAVCredential
    private let trustPolicy: TrustPolicy

    init(
        client: WebDAVClient,
        representation: RangeProbeResult,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy
    ) {
        self.client = client
        self.resourceURL = representation.resourceURL
        self.representation = representation
        self.sessionKey = sessionKey
        self.credential = credential
        self.trustPolicy = trustPolicy
        self.byteSize = representation.totalLength
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
            return try await client.readRange(
                url: resourceURL, start: offset, end: end, representation: representation,
                sessionKey: sessionKey, credential: credential, trustPolicy: trustPolicy
            )
        } catch {
            throw mapWebDAVError(error)
        }
    }

    func shutdown() async {
        // No per-source resource to release: the ephemeral URLSession backing
        // these reads is owned by the transport session's registry and drained
        // when that session shuts down. Deterministic teardown is therefore the
        // session's responsibility; a cancelled in-flight read is torn down at
        // the URLSessionTask level by structured cancellation.
    }
}
