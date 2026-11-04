import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single managed ephemeral session: the `URLSession` plus the delegate
/// object that stays alive for the session's lifetime.
final class TransportSession: @unchecked Sendable {
    let key: TransportSessionKey
    let session: URLSession
    private let delegate: TransportSessionDelegate
    private let credential: WebDAVCredential
    private let trustPolicy: TrustPolicy
    private let lifecycleLock = NSLock()
    private var acceptsNewTasks = true
    private var retryAfter: ContinuousClock.Instant?

    init(
        key: TransportSessionKey,
        session: URLSession,
        delegate: TransportSessionDelegate,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy
    ) {
        self.key = key
        self.session = session
        self.delegate = delegate
        self.credential = credential
        self.trustPolicy = trustPolicy
    }

    deinit {
        session.invalidateAndCancel()
    }

    func matches(credential: WebDAVCredential, trustPolicy: TrustPolicy) -> Bool {
        self.credential.hasSameMaterial(as: credential) && self.trustPolicy == trustPolicy
    }

    func data(
        for request: URLRequest,
        maxResponseBytes: Int,
        followRedirects: Bool = true,
        stream: TransportResponseStream? = nil,
        validateResponse: (@Sendable (HTTPURLResponse) throws -> Void)? = nil
    ) async throws -> TransportDataResponse {
        let taskBox = URLSessionTaskBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lifecycleLock.lock()
                guard acceptsNewTasks else {
                    lifecycleLock.unlock()
                    continuation.resume(throwing: TransportError.cancelled)
                    return
                }
                if let retryAfter, retryAfter > .now {
                    lifecycleLock.unlock()
                    continuation.resume(throwing: TransportError.protocolError(
                        status: 429, detail: "server-requested cooldown is still active"
                    ))
                    return
                }
                let task = session.dataTask(with: request)
                delegate.register(
                    task: task, maxResponseBytes: maxResponseBytes,
                    followRedirects: followRedirects, stream: stream, validateResponse: validateResponse
                ) { [self] result in
                    if case .success(let response) = result, response.response.statusCode == 429 {
                        recordCooldown(response.response)
                    }
                    continuation.resume(with: result)
                }
                taskBox.store(task)
                task.resume()
                lifecycleLock.unlock()
            }
        } onCancel: {
            stream?.cancel()
            taskBox.cancel()
        }
    }

    private func recordCooldown(_ response: HTTPURLResponse) {
        let header = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds: TimeInterval
        if let header, !header.isEmpty, header.utf8.allSatisfy({ (48...57).contains($0) }),
           let value = Double(header), value.isFinite {
            seconds = value
        } else if let header, let date = HTTPDate.parse(header) {
            seconds = max(0, date.timeIntervalSinceNow)
        } else {
            seconds = 5
        }
        // An unrepresentably distant retry date remains blocked for this session.
        let deadline = ContinuousClock.now.advanced(by: .seconds(min(seconds, 31_536_000_000)))
        lifecycleLock.withLock {
            retryAfter = max(retryAfter ?? deadline, deadline)
        }
    }

    /// Cancels all outstanding tasks immediately and invalidates the
    /// session. Use when the key's credential/trust is being replaced and
    /// in-flight requests must not be allowed to complete.
    func invalidateAndCancel() {
        lifecycleLock.lock()
        guard acceptsNewTasks else {
            lifecycleLock.unlock()
            return
        }
        acceptsNewTasks = false
        session.invalidateAndCancel()
        lifecycleLock.unlock()
    }

    /// Lets outstanding tasks finish, then invalidates. Use for graceful
    /// shutdown (e.g. app backgrounding) where an in-flight read shouldn't
    /// be torn down mid-response.
    func finishTasksAndInvalidate() {
        lifecycleLock.lock()
        guard acceptsNewTasks else {
            lifecycleLock.unlock()
            return
        }
        acceptsNewTasks = false
        session.finishTasksAndInvalidate()
        lifecycleLock.unlock()
    }
}

private final class URLSessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func store(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

/// Hands out one ephemeral `URLSession` per ``TransportSessionKey`` and
/// nothing more — no session, auth state, cookie, or cache is ever reused
/// across two keys that differ in *any* dimension (account, credential
/// revision, origin, trust revision, or role).
///
/// An `actor` so concurrent callers (a scanner and a playback reader firing
/// at once) can't race on the backing dictionary.
public actor TransportSessionRegistry {
    private enum SessionIdentity: Hashable {
        case account(TransportSessionKey)
        case media(source: TransportSessionKey, origin: TransportOrigin)

        var sourceKey: TransportSessionKey {
            switch self {
            case .account(let key), .media(let key, _): return key
            }
        }
    }

    private var sessions: [SessionIdentity: TransportSession] = [:]
    private let testProtocolClasses: [AnyClass]

    /// Max simultaneous connections one managed session opens to its host.
    ///
    /// The parallel share scanner (`ShareScanner`) runs a pool of independent
    /// listers (default 4) that all share ONE scanner-role session per account.
    /// SMB needs a separate socket per lister because its client is serial per
    /// connection — but HTTP has no such limit: a single `URLSession` is built
    /// to fan concurrent requests across a per-host connection pool. Capping
    /// this at 1 would silently serialize the whole scan onto one connection
    /// (making a WebDAV first-scan ~Nx slower than the equivalent SMB walk), so
    /// we allow enough connections to cover the scan pool plus a little headroom
    /// for an overlapping interactive read. Each playback reader has at most one
    /// active range request; independent preview readers retain their own cursors.
    static let maxConnectionsPerHost = 6

    public init() {
        self.testProtocolClasses = []
    }

    /// Test-only seam: installs additional `URLProtocol` classes (e.g. a
    /// loopback/stub protocol) on every ephemeral session this registry
    /// creates, so integration tests can exercise the real challenge/
    /// redirect delegate without a real network. Never used by production
    /// call sites.
    ///
    init(testProtocolClasses: [AnyClass]) {
        self.testProtocolClasses = testProtocolClasses
    }

    /// Returns the existing session for `key` if one is live, or creates a
    /// brand-new ephemeral one. Two calls with an *equal* key intentionally
    /// share the same session (that's not "reuse across a dimension" — the
    /// key hasn't changed); two calls whose keys differ in any field always
    /// get distinct sessions, because they're distinct dictionary entries.
    func session(
        for key: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy
    ) throws -> TransportSession {
        if case .pinnedLeaf(_, let revision) = trustPolicy,
           revision != key.trustRevision {
            throw TransportError.sessionConfigurationMismatch
        }
        if let existing = sessions[.account(key)] {
            guard existing.matches(credential: credential, trustPolicy: trustPolicy) else {
                throw TransportError.sessionConfigurationMismatch
            }
            return existing
        }
        let created = try makeSession(key: key, credential: credential, trustPolicy: trustPolicy)
        sessions[.account(key)] = created
        return created
    }

    /// Delivery grants never share cookies, credentials or a certificate override
    /// with the DAV session, including a redirect that returns to its origin.
    func mediaSession(for sourceKey: TransportSessionKey, origin: TransportOrigin) throws -> TransportSession {
        let identity = SessionIdentity.media(source: sourceKey, origin: origin)
        if let existing = sessions[identity] { return existing }
        let key = try TransportSessionKey(
            accountID: sourceKey.accountID,
            credentialRevision: sourceKey.credentialRevision.rawValue,
            origin: origin,
            trustRevision: sourceKey.trustRevision,
            role: sourceKey.role
        )
        let created = try makeSession(
            key: key, credential: .anonymous, trustPolicy: .system, isAnonymousMediaSession: true
        )
        sessions[identity] = created
        return created
    }

    /// Immediately cancels and removes the session for `key`, if any.
    public func invalidate(_ key: TransportSessionKey) {
        invalidateAll { $0 == key }
    }

    /// Cancels and removes every session whose key matches `predicate` —
    /// e.g. every session for a given `accountID` when an account is
    /// removed, regardless of which origins/roles/revisions it spun up.
    public func invalidateAll(where predicate: (TransportSessionKey) -> Bool) {
        for key in Array(sessions.keys) where predicate(key.sourceKey) {
            sessions.removeValue(forKey: key)?.invalidateAndCancel()
        }
    }

    /// Gracefully invalidates and drops every managed session (e.g. on app
    /// termination/backgrounding). Uses `finishTasksAndInvalidate` so
    /// in-flight reads complete rather than being cut off mid-response.
    public func drainAll() {
        for session in sessions.values {
            session.finishTasksAndInvalidate()
        }
        sessions.removeAll()
    }

    /// Current count of live sessions — test/diagnostic use only, so tests
    /// can assert session-key separation without reaching into private
    /// state.
    public var liveSessionCount: Int { sessions.count }

    private func makeSession(
        key: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy,
        isAnonymousMediaSession: Bool = false
    ) throws -> TransportSession {
        guard let origin = key.origin else {
            throw TransportError.invalidOrigin(reason: "session key is not an HTTP endpoint")
        }
        let configuration = URLSessionConfiguration.ephemeral
        // Belt-and-suspenders on top of `.ephemeral`: explicit, so the
        // no-reuse guarantee doesn't silently depend on a platform default
        // that could change.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        // Allow the shared scanner session to parallelize across the scan pool;
        // see `maxConnectionsPerHost`. (Was 1, which serialized WebDAV scans.)
        configuration.httpMaximumConnectionsPerHost = Self.maxConnectionsPerHost
        if !testProtocolClasses.isEmpty {
            configuration.protocolClasses = testProtocolClasses
        }
        let delegate = TransportSessionDelegate(
            credential: credential,
            trustPolicy: trustPolicy,
            origin: origin,
            isAnonymousMediaSession: isAnonymousMediaSession
        )
        let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return TransportSession(
            key: key,
            session: urlSession,
            delegate: delegate,
            credential: credential,
            trustPolicy: trustPolicy
        )
    }
}
