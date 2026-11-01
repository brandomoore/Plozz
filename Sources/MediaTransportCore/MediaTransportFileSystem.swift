import CoreModels
import Foundation

public enum MediaTransportRangeBehavior: String, Hashable, Sendable {
    case unsupported
    case bounded
    case randomAccess
}

public enum MediaTransportConsistencyBehavior: String, Hashable, Sendable {
    case none
    case changeDetecting
    case representationBound
}

public struct MediaTransportCapabilities: Hashable, Sendable {
    public let supportsList: Bool
    public let supportsStat: Bool
    public let supportsBoundedWholeFileRead: Bool
    public let byteRangeBehavior: MediaTransportRangeBehavior
    public let maximumBoundedWholeFileReadBytes: Int?
    public let consistency: MediaTransportConsistencyBehavior

    public init(
        supportsList: Bool,
        supportsStat: Bool,
        supportsBoundedWholeFileRead: Bool,
        byteRangeBehavior: MediaTransportRangeBehavior,
        maximumBoundedWholeFileReadBytes: Int? = nil,
        consistency: MediaTransportConsistencyBehavior
    ) throws {
        if let maximumBoundedWholeFileReadBytes, maximumBoundedWholeFileReadBytes <= 0 {
            throw MediaTransportError.invalidInput(reason: "bounded read limit must be positive")
        }
        guard supportsBoundedWholeFileRead == (maximumBoundedWholeFileReadBytes != nil) else {
            throw MediaTransportError.invalidInput(reason: "bounded read capability mismatch")
        }
        if byteRangeBehavior != .unsupported, !supportsBoundedWholeFileRead {
            throw MediaTransportError.invalidInput(
                reason: "byte range access requires bounded whole-file reads"
            )
        }
        self.supportsList = supportsList
        self.supportsStat = supportsStat
        self.supportsBoundedWholeFileRead = supportsBoundedWholeFileRead
        self.byteRangeBehavior = byteRangeBehavior
        self.maximumBoundedWholeFileReadBytes = maximumBoundedWholeFileReadBytes
        self.consistency = consistency
    }
}

public struct MediaTransportProbe: Hashable, Sendable {
    public let capabilities: MediaTransportCapabilities
    public let diagnostics: Set<MediaTransportDiagnostic>

    public init(
        capabilities: MediaTransportCapabilities,
        diagnostics: Set<MediaTransportDiagnostic> = []
    ) {
        self.capabilities = capabilities
        self.diagnostics = diagnostics
    }
}

public protocol MediaTransportBrowsing: Sendable {
    func list(relativePath: String) async throws -> [RemoteFileEntry]
    func stat(relativePath: String) async throws -> RemoteFileEntry
}

public protocol MediaTransportFileSystem: MediaTransportBrowsing {
    func validate() async throws
    func probe() async throws -> MediaTransportProbe
    /// May perform bounded I/O to establish a locator identity. Ordinary stat
    /// remains metadata-only, including for nonseekable sidecars and artwork.
    func statForOpening(relativePath: String) async throws -> RemoteFileEntry
    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data
    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease
}

/// Explicit opt-in to bounded, exact-representation preparation. Implementations
/// must honor cancellation, bound their I/O and memory, and return an unclaimed
/// lease (no cursor). A failed preparation must drain any partially opened source.
public protocol MediaTransportPreparingFileSystem: MediaTransportFileSystem {
    func prepareSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease

    /// Performs fresh authorization and representation/size validation. This is
    /// not a cached stat: a mismatch must throw rather than reuse prepared bytes.
    func revalidatePreparedSource(for locator: NetworkFileLocator) async throws
}

public extension MediaTransportFileSystem {
    func statForOpening(relativePath: String) async throws -> RemoteFileEntry {
        try await stat(relativePath: relativePath)
    }
}
