import CoreModels
import Foundation
import MediaTransportCore
import MediaTransportHTTP
import os

/// Non-secret + secret connection material for one WebDAV account, resolved
/// per (accountID, credentialRevision). The endpoint origin and root come from
/// the session key's endpoint (the single source of that truth); this carries
/// only what the endpoint can't: the credential and the TLS trust policy.
public struct WebDAVMediaTransportConfiguration: Sendable {
    public let credential: WebDAVCredential
    public let trustPolicy: TrustPolicy

    public init(credential: WebDAVCredential, trustPolicy: TrustPolicy) {
        self.credential = credential
        self.trustPolicy = trustPolicy
    }
}

/// Resolves per-account WebDAV credentials/trust. **Must throw a
/// ``MediaTransportError``** (e.g. `.authentication` for a missing/incompatible
/// vault envelope), never a raw vault error — `ShareTransportBrowser` treats a
/// non-`MediaTransportError` as transient and would retry-loop on a permanent
/// credential problem.
public typealias WebDAVMediaTransportConfigurationProvider =
    @Sendable (String, CredentialRevision) throws -> WebDAVMediaTransportConfiguration

/// The two HTTP schemes a WebDAV account can use. The adapter's
/// `transportIdentifier` is the scheme itself, so the shared
/// `MediaTransportResolverRegistry` routes on the account's real
/// `http`/`https` scheme and the session key that reaches the HTTP primitives
/// already carries a valid origin — no key translation, and no `webDAV`
/// mixed-case identifier trap.
public enum WebDAVScheme: String, Sendable, CaseIterable {
    case http
    case https
}

/// WebDAV/HTTP `MediaTransportAdapter`. Mirrors `SMBMediaTransportAdapter`: a
/// stateless struct whose `connect` produces a session that owns its own
/// ephemeral-session registry, so shutting one session down never disturbs
/// another account/role/source.
public struct WebDAVMediaTransportAdapter: MediaTransportAdapter, Sendable {
    public let transportIdentifier: String

    private let configurationProvider: WebDAVMediaTransportConfigurationProvider
    private let registryFactory: @Sendable () -> TransportSessionRegistry

    public init(
        scheme: WebDAVScheme,
        configurationProvider: @escaping WebDAVMediaTransportConfigurationProvider
    ) {
        self.init(
            scheme: scheme,
            configurationProvider: configurationProvider,
            registryFactory: { TransportSessionRegistry() }
        )
    }

    /// DI seam: tests inject a `registryFactory` that installs a stub
    /// `URLProtocol` (via `TransportSessionRegistry`'s testing initializer) so
    /// the full request/response/trust/redirect path runs offline.
    init(
        scheme: WebDAVScheme,
        configurationProvider: @escaping WebDAVMediaTransportConfigurationProvider,
        registryFactory: @escaping @Sendable () -> TransportSessionRegistry
    ) {
        self.transportIdentifier = scheme.rawValue
        self.configurationProvider = configurationProvider
        self.registryFactory = registryFactory
    }

    public func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
        guard key.endpoint.transportIdentifier == transportIdentifier else {
            throw MediaTransportError.unsupportedCapability("transport")
        }
        guard let origin = key.origin else {
            throw MediaTransportError.invalidInput(reason: "invalid WebDAV endpoint origin")
        }
        guard let root = WebDAVRoot(origin: origin, rawPath: key.endpoint.rootPath) else {
            throw MediaTransportError.invalidInput(reason: "invalid WebDAV root")
        }

        // The provider owns the MediaTransportError contract (see the typealias
        // doc); its errors propagate unchanged so a permanent credential
        // failure stays terminal rather than being reclassified as transient.
        let configuration = try configurationProvider(key.accountID, key.credentialRevision)

        let registry = registryFactory()
        let client = WebDAVClient(registry: registry)
        let fileSystem = WebDAVMediaTransportFileSystem(
            client: client,
            root: root,
            sessionKey: key,
            credential: configuration.credential,
            trustPolicy: configuration.trustPolicy,
            accountID: key.accountID,
            credentialRevision: key.credentialRevision
        )
        return WebDAVMediaTransportSession(key: key, fileSystem: fileSystem, registry: registry)
    }
}

final class WebDAVMediaTransportSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    private let registry: TransportSessionRegistry

    init(
        key: MediaTransportSessionKey,
        fileSystem: any MediaTransportFileSystem,
        registry: TransportSessionRegistry
    ) {
        self.key = key
        self.fileSystem = fileSystem
        self.registry = registry
    }

    func shutdown() async {
        // Gracefully invalidate every ephemeral URLSession this session spun
        // up. Only this session's registry is affected — sibling sessions own
        // their own registries.
        await registry.drainAll()
    }

    /// Always healthy: there is no persistent socket to go stale. WebDAV is
    /// stateless HTTP and every request is issued through URLSession, which owns
    /// its own connection pool and transparently opens a new socket when a
    /// pooled one has been closed (by the server, a NAT, or an app suspend).
    /// Authentication is per-request, so nothing survives a reconnect that would
    /// need re-establishing.
    func isHealthy() async -> Bool { true }
}

final class WebDAVMediaTransportFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    static let maximumSmallFileSize = 16 * 1_024 * 1_024

    private let client: WebDAVClient
    private let root: WebDAVRoot
    private let sessionKey: MediaTransportSessionKey
    private let credential: WebDAVCredential
    private let trustPolicy: TrustPolicy
    private let accountID: String
    private let credentialRevision: CredentialRevision

    init(
        client: WebDAVClient,
        root: WebDAVRoot,
        sessionKey: MediaTransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy,
        accountID: String,
        credentialRevision: CredentialRevision
    ) {
        self.client = client
        self.root = root
        self.sessionKey = sessionKey
        self.credential = credential
        self.trustPolicy = trustPolicy
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    func validate() async throws {
        do {
            try await client.validateCollection(
                root: root,
                sessionKey: sessionKey,
                credential: credential,
                trustPolicy: trustPolicy
            )
        } catch {
            throw mapWebDAVError(error)
        }
    }

    func probe() async throws -> MediaTransportProbe {
        // Transport-level capabilities. Per-file seekability is not asserted
        // here (probe has no file argument) — openSource requires a strong ETag
        // or Last-Modified from the actual GET representation.
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess,
                maximumBoundedWholeFileReadBytes: Self.maximumSmallFileSize,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] {
        let absolute = try absolutePath(forRelative: relativePath)
        do {
            let entries = try await client.listChildren(
                root: root,
                path: absolute,
                depth: .one,
                sessionKey: sessionKey,
                credential: credential,
                trustPolicy: trustPolicy
            )
            // Skip an individual entry that can't be represented (e.g. a
            // malformed path) rather than aborting the whole directory scan.
            // Missing validators do not prevent directory browsing.
            return entries.compactMap { try? remoteFileEntry(from: $0) }
        } catch {
            throw mapWebDAVError(error)
        }
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        let absolute = try absolutePath(forRelative: relativePath)
        do {
            let entry = try await client.properties(
                root: root,
                path: absolute,
                sessionKey: sessionKey,
                credential: credential,
                trustPolicy: trustPolicy
            )
            return try remoteFileEntry(from: entry)
        } catch {
            throw mapWebDAVError(error)
        }
    }

    func statForOpening(relativePath: String) async throws -> RemoteFileEntry {
        try await openingMetadata(relativePath: relativePath).entry
    }

    private func openingMetadata(
        relativePath: String
    ) async throws -> (entry: RemoteFileEntry, probe: RangeProbeResult?) {
        let file = try await stat(relativePath: relativePath)
        do {
            guard file.kind == .file, file.strongETag == nil, file.modifiedAt == nil else {
                return (file, nil)
            }
            // Some DAV listings omit validators that GET supplies. Learn a real
            // identity, rather than persisting a fabricated timestamp or ETag.
            let absolute = try absolutePath(forRelative: relativePath)
            guard let url = root.origin.url(path: absolute) else {
                throw MediaTransportError.invalidInput(reason: "could not build WebDAV URL")
            }
            let probe = try await probeFile(url)
            // A delivery resource's ETag cannot identify the stable DAV path.
            // Without DAV metadata, only that exact resource is comparable
            // across opens; signed delivery URLs must not become locator state.
            guard probe.resourceURL.absoluteString == url.absoluteString else {
                throw MediaTransportError.unsupportedRange(
                    reason: "redirected WebDAV files require a stable DAV metadata validator"
                )
            }
            guard file.size == nil || file.size == probe.totalLength else {
                throw MediaTransportError.sourceChanged(reason: "WebDAV size changed during stat")
            }
            let entry = try RemoteFileEntry(
                relativePath: file.relativePath, kind: .file, size: probe.totalLength,
                modifiedAt: probe.lastModified, strongETag: probe.etag?.rawValue, mimeType: file.mimeType
            )
            return (entry, probe)
        } catch {
            throw mapWebDAVError(error)
        }
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= Self.maximumSmallFileSize else {
            throw MediaTransportError.invalidInput(reason: "invalid small-file bound")
        }
        let absolute = try absolutePath(forRelative: relativePath)
        guard let url = root.origin.url(path: absolute) else {
            throw MediaTransportError.invalidInput(reason: "could not build WebDAV URL")
        }
        do {
            return try await client.getBounded(
                root: root,
                url: url,
                maxBytes: maximumBytes,
                sessionKey: sessionKey,
                credential: credential,
                trustPolicy: trustPolicy
            )
        } catch {
            throw mapWebDAVError(error)
        }
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        guard locator.accountID == accountID,
              locator.credentialRevision == credentialRevision else {
            throw MediaTransportError.invalidInput(reason: "locator session mismatch")
        }
        guard locator.representation.consistency == .changeDetecting,
              locator.representation.identity.kind == .strongETag
                || locator.representation.identity.kind == .modificationTime else {
            throw MediaTransportError.unsupportedRange(
                reason: "WebDAV playback requires an ETag or modification-time representation"
            )
        }
        let absolute = try absolutePath(forRelative: locator.relativePath)
        guard let url = root.origin.url(path: absolute) else {
            throw MediaTransportError.invalidInput(reason: "could not build WebDAV URL")
        }
        do {
            do {
                return try await openValidatedSource(
                    for: locator, url: url, reportDeliveryConnectionFailure: sessionKey.role == .playback
                )
            } catch TransportError.deliveryConnectionFailed {
                try Task.checkCancellation()
                Logger(subsystem: "com.thatcube.Plozz", category: "webdav")
                    .notice("Anonymous delivery connection failed; revalidating and resolving once before playback")
                return try await openValidatedSource(for: locator, url: url)
            }
        } catch {
            throw mapWebDAVError(error)
        }
    }

    private func openValidatedSource(
        for locator: NetworkFileLocator,
        url: URL,
        reportDeliveryConnectionFailure: Bool = false
    ) async throws -> MediaTransportSourceLease {
        try Task.checkCancellation()
        // Revalidate the stable DAV identity before opening a delivery grant.
        // This also protects resumed downloads whose locator was persisted.
        let metadata = try await openingMetadata(relativePath: locator.relativePath)
        let current = metadata.entry
        let identity = locator.representation.identity
        let identityMatches = identity.kind == .strongETag
            ? current.strongETag == identity.value
            : current.modifiedAt == identity.modifiedAt
        guard current.kind == .file, identityMatches, current.size == locator.representation.size else {
            throw MediaTransportError.sourceChanged(reason: "WebDAV metadata changed since locator creation")
        }
        let probe: RangeProbeResult
        if let discovered = metadata.probe {
            probe = discovered
        } else {
            probe = try await probeFile(
                url, prefetch: sessionKey.role == .playback
                    && locator.representation.size >= RangeProbe.initialReadByteCount,
                reportDeliveryConnectionFailure: reportDeliveryConnectionFailure
            )
        }
        guard probe.totalLength == locator.representation.size else {
            throw MediaTransportError.sourceChanged(reason: "WebDAV representation changed since scan")
        }
        // A delivery host can use a different validator namespace. Only
        // compare DAV/GET validators when they describe the same origin.
        if TransportOrigin(url: probe.resourceURL) == root.origin {
            if identity.kind == .strongETag, let etag = probe.etag, etag.rawValue != identity.value {
                throw MediaTransportError.sourceChanged(reason: "WebDAV GET ETag changed")
            }
            if identity.kind == .modificationTime, let date = probe.lastModified, date != identity.modifiedAt {
                throw MediaTransportError.sourceChanged(reason: "WebDAV GET modification time changed")
            }
        }
        let source = WebDAVByteSource(
            client: client,
            representation: probe,
            sessionKey: sessionKey,
            credential: credential,
            trustPolicy: trustPolicy
        )
        return MediaTransportSourceLease(source: source)
    }

    private func probeFile(
        _ url: URL, prefetch: Bool = false, reportDeliveryConnectionFailure: Bool = false
    ) async throws -> RangeProbeResult {
        try await client.probeRange(
            root: root, url: url, sessionKey: sessionKey, credential: credential,
            trustPolicy: trustPolicy, prefetch: prefetch,
            reportDeliveryConnectionFailure: reportDeliveryConnectionFailure
        )
    }

    // MARK: - Path helpers

    /// Builds the absolute, root-anchored WebDAV path for a transport-relative
    /// path, and asserts it is normalized and contained by the configured root
    /// (defense-in-depth on top of `NetworkFileLocator`/scanner normalization).
    private func absolutePath(forRelative relativePath: String) throws -> String {  // l10n:content — throw-reason text is a developer diagnostic. Onboarding-probe callers (SFTPOnboardingProbe/FTPOnboardingProbe.classify) now log the raw reason via PlozzLog and show generic translated copy instead of displaying it — see PlozziOSAddSFTPShareView/PlozziOSAddFTPShareView/UnifiedAddShareModel.
        let rootBase = trimmedRoot()
        let relative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absolute: String
        if relative.isEmpty {
            absolute = rootBase.isEmpty ? "/" : rootBase
        } else if rootBase == "/" || rootBase.isEmpty {
            absolute = "/" + relative
        } else {
            absolute = rootBase + "/" + relative
        }
        guard WebDAVPathPolicy.isNormalizedDecodedPath(absolute),
              WebDAVPathPolicy.isWithinRoot(absolute, root: root.path) else {
            throw MediaTransportError.invalidInput(reason: "WebDAV path escapes root")
        }
        return absolute
    }

    /// Strips the configured root prefix off an absolute (server-resolved)
    /// path to produce the transport-relative path `RemoteFileEntry` expects.
    private func relativeUnderRoot(_ absolutePath: String) throws -> String {  // l10n:content — throw-reason text is a developer diagnostic. Onboarding-probe callers (SFTPOnboardingProbe/FTPOnboardingProbe.classify) now log the raw reason via PlozzLog and show generic translated copy instead of displaying it — see PlozziOSAddSFTPShareView/PlozziOSAddFTPShareView/UnifiedAddShareModel.
        var path = absolutePath
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let rootBase = trimmedRoot()
        if rootBase == "/" || rootBase.isEmpty {
            return String(path.drop(while: { $0 == "/" }))
        }
        if path == rootBase { return "" }
        guard path.hasPrefix(rootBase + "/") else {
            throw MediaTransportError.protocolViolation(reason: "entry escaped WebDAV root")
        }
        return String(path.dropFirst(rootBase.count + 1))
    }

    private func trimmedRoot() -> String {
        (root.path.count > 1 && root.path.hasSuffix("/")) ? String(root.path.dropLast()) : root.path
    }

    private func remoteFileEntry(from entry: WebDAVEntry) throws -> RemoteFileEntry {
        let relative = try relativeUnderRoot(entry.resolvedPath)
        let strongETag = (entry.etag?.isValidStrongValidator == true) ? entry.etag?.rawValue : nil
        return try RemoteFileEntry(
            relativePath: relative,
            kind: entry.isCollection ? .directory : .file,
            size: entry.isCollection ? nil : entry.contentLength,
            modifiedAt: entry.lastModified,
            strongETag: strongETag,
            mimeType: entry.contentType
        )
    }
}
