import Foundation

/// Whether this process may make outgoing connections to the local network.
///
/// Local Network is a user-controlled privacy grant, not an entitlement: the
/// system shows its alert the first time an app performs a local-network
/// operation, and remembers the answer per signed identity
/// ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
/// Re-signing the same bundle id with a different team (for example an
/// unsigned self-build IPA re-signed by a sideloading tool) produces a new
/// identity, so the grant the previous install earned does not follow it.
public enum LocalNetworkPermissionState: String, Sendable, Equatable, CaseIterable {
    /// The grant is in place; local addresses are reachable.
    case granted
    /// The user declined, or declined earlier and never re-enabled the switch.
    /// Every outgoing local connection fails until it is turned back on in
    /// Settings ▸ Privacy & Security ▸ Local Network.
    case denied
    /// Not decided yet, or the probe could not establish an answer.
    case unknown
    /// The platform has no Local Network privacy gate (tvOS), or this process
    /// must not probe (unit-test hosts).
    case notRequired
}

/// Requests the Local Network grant from **the app's own process**.
///
/// Playback of a LAN library used to rely on whichever request happened to hit
/// the network first. When that request is made by AVFoundation while the
/// player presents, the alert can be missed and the stream then times out with
/// `NSURLError -1001` — which reads as a broken player rather than a permission
/// decision. Asking once, early, from a calm foreground screen makes the
/// decision explicit and keeps playback off the alert's critical path.
///
/// The probe is a bounded Bonjour browse of a service type both apps already
/// declare in `NSBonjourServices` (`_jellyfin._tcp`). Browsing is the operation
/// that raises the alert; it is cancelled as soon as the answer is known.
/// Callers must treat a timeout as "unknown", never as success or failure.
public enum LocalNetworkAuthorization {
    /// Starts (or joins) the one probe this process performs and returns its
    /// state. Awaits at most five seconds; a still-undecided alert resolves as
    /// `.unknown` while the browse stays alive so a later answer is recorded.
    public static func requestIfNeeded() async -> LocalNetworkPermissionState {
        await LocalNetworkProbe.shared.request()
    }

    /// The last recorded state, without starting a probe. Used by diagnostics.
    public static var recordedState: LocalNetworkPermissionState {
        LocalNetworkProbe.shared.recorded
    }
}

public extension LocalNetworkPermissionState {
    /// Developer-facing rendering for the Device & Build diagnostic panel.
    /// Deliberately English and not part of the localized UI copy.
    var diagnosticLabel: String {  // l10n:content — developer-facing diagnostic
        switch self {
        case .granted: "Granted"
        case .denied: "Denied — Settings ▸ Privacy & Security ▸ Local Network"
        case .unknown: "Not requested"
        case .notRequired: "Not required"
        }
    }
}

#if os(iOS) && canImport(Network)
import Network

/// One process-wide probe. `NWBrowser` has no shared state to protect beyond
/// what the lock below covers, so the callbacks run on a private queue.
private final class LocalNetworkProbe: @unchecked Sendable {
    static let shared = LocalNetworkProbe()

    /// Declared in `NSBonjourServices` for both apps, and legitimately browsed
    /// by server discovery. Browsing a type the app does not declare would not
    /// raise the alert on newer systems.
    private static let serviceType = "_jellyfin._tcp"
    /// `kDNSServiceErr_PolicyDenied`: the answer the DNS layer gives when the
    /// Local Network switch is off.
    private static let policyDeniedDNSCode: Int32 = -65570
    private static let decisionTimeout: Duration = .seconds(5)

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.plozz.local-network-authorization")
    private var state: LocalNetworkPermissionState = .unknown
    private var started = false
    private var waiters: [CheckedContinuation<LocalNetworkPermissionState, Never>] = []
    private var browser: NWBrowser?

    var recorded: LocalNetworkPermissionState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func request() async -> LocalNetworkPermissionState {
        guard !Self.isTestHost else { return .notRequired }

        let decision = begin()
        if let settled = decision.settled { return settled }
        // The alert is already up (or the browse already ran). Later callers
        // must not park for another five seconds on every foreground or
        // playback start; the recorded state is read from diagnostics instead.
        guard decision.startNow else { return .unknown }
        startBrowser()

        return await withCheckedContinuation { continuation in
            if let settled = enqueue(continuation) {
                continuation.resume(returning: settled)
            }
        }
    }

    private struct Decision {
        let settled: LocalNetworkPermissionState?
        let startNow: Bool
    }

    /// Synchronous so the async entry point never holds `NSLock` across a
    /// suspension point (`NSLock.lock()` is unavailable in async contexts).
    private func begin() -> Decision {
        lock.lock()
        defer { lock.unlock() }
        if state != .unknown { return Decision(settled: state, startNow: false) }
        if started { return Decision(settled: nil, startNow: false) }
        started = true
        return Decision(settled: nil, startNow: true)
    }

    /// Returns a decided state when the answer arrived between `begin()` and
    /// the continuation; otherwise parks the caller until the probe resolves or
    /// the decision timeout lapses.
    private func enqueue(
        _ continuation: CheckedContinuation<LocalNetworkPermissionState, Never>
    ) -> LocalNetworkPermissionState? {
        lock.lock()
        if state != .unknown {
            let current = state
            lock.unlock()
            return current
        }
        let armTimeout = waiters.isEmpty
        waiters.append(continuation)
        lock.unlock()
        if armTimeout { armDecisionTimeout() }
        return nil
    }

    /// Bounds only the caller's wait. The browse keeps running so the alert is
    /// not torn down while the user is deciding and a late answer is still kept.
    private func armDecisionTimeout() {
        Task { [weak self] in
            try? await Task.sleep(for: Self.decisionTimeout)
            self?.expireWaiters()
        }
    }

    private func expireWaiters() {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        let current = state
        lock.unlock()
        for waiter in pending { waiter.resume(returning: current) }
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: NWParameters.tcp
        )
        browser.stateUpdateHandler = { [weak self] browserState in
            guard let self else { return }
            switch browserState {
            case .ready:
                self.resolve(.granted)
            case .failed(let error):
                self.resolve(Self.state(for: error))
            case .waiting(let error):
                // A policy denial can surface as a waiting browse; anything
                // else is transient and must not be recorded as a denial.
                if Self.state(for: error) == .denied { self.resolve(.denied) }
            default:
                break
            }
        }
        lock.lock()
        self.browser = browser
        lock.unlock()
        browser.start(queue: queue)
    }

    private func resolve(_ resolved: LocalNetworkPermissionState) {
        guard resolved != .unknown else { return }
        lock.lock()
        if state == .unknown { state = resolved }
        let value = state
        let pending = waiters
        waiters.removeAll()
        let browser = self.browser
        self.browser = nil
        lock.unlock()
        browser?.cancel()
        for waiter in pending { waiter.resume(returning: value) }
    }

    private static func state(for error: NWError) -> LocalNetworkPermissionState {
        guard case let .dns(code) = error, code == policyDeniedDNSCode else { return .unknown }
        return .denied
    }

    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
#else
/// tvOS has no Local Network privacy gate, and no other platform builds the
/// app targets. Keeping the API inert here keeps call sites unconditional.
private final class LocalNetworkProbe: @unchecked Sendable {
    static let shared = LocalNetworkProbe()

    var recorded: LocalNetworkPermissionState { .notRequired }

    func request() async -> LocalNetworkPermissionState { .notRequired }
}
#endif
