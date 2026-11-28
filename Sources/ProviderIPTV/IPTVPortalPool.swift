import CoreModels
import CoreNetworking
import Foundation

/// Tracks health and latency across an Xtream account's primary and backup portal URLs.
///
/// - **Performance**: `warmConnection` probes non-stream endpoints in parallel across all
///   configured portals to rank by RTT and keep the fastest portal's TCP/TLS socket warm
///   in the pooled playback `URLSession` (0 media stream slots consumed).
/// - **Reliability (1-stream safe)**: API calls and live media stream opens fail over strictly
///   sequentially, never racing concurrent media streams, and never failing over on auth,
///   rate-limit, or connection-limit refusals.
actor IPTVPortalPool {
    struct ProbeResult: Sendable {
        let portal: URL
        let rtt: TimeInterval?
        let allowedOutputFormats: [String]?
        let failed: Bool
        let reason: String?

        init(
            portal: URL, rtt: TimeInterval?, allowedOutputFormats: [String]?,
            failed: Bool, reason: String? = nil
        ) {
            self.portal = portal
            self.rtt = rtt
            self.allowedOutputFormats = allowedOutputFormats
            self.failed = failed
            self.reason = reason
        }
    }

    private struct PortalHealth {
        var measuredRTT: TimeInterval?
        var degradedUntil: TimeInterval?
        var lastFailedAt: TimeInterval?
    }

    static let defaultCooldownSeconds: TimeInterval = 60
    static let preferredHysteresisSeconds: TimeInterval = 0.025

    let portals: [URL]
    private let cooldownSeconds: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private var health: [URL: PortalHealth] = [:]
    private var preferredPortal: URL?

    init(
        portals: [URL],
        cooldownSeconds: TimeInterval = IPTVPortalPool.defaultCooldownSeconds,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        precondition(!portals.isEmpty)
        self.portals = portals
        self.cooldownSeconds = cooldownSeconds
        self.uptime = uptime
    }

    var hasAlternates: Bool { portals.count > 1 }

    func index(of portal: URL) -> Int? {
        portals.firstIndex(of: portal)
    }

    func activePortal() -> URL {
        orderedPortals().first ?? portals[0]
    }

    /// Returns all configured portals in try order: healthy portals ranked by latency
    /// (with a small hysteresis favoring the current preferred portal), followed by
    /// unmeasured healthy portals in configured order, and finally degraded portals
    /// oldest-failure-first as a last resort if every portal is degraded.
    func orderedPortals() -> [URL] {
        guard portals.count > 1 else { return portals }
        let now = uptime()
        var measuredHealthy: [(portal: URL, rtt: TimeInterval, order: Int)] = []
        var unmeasuredHealthy: [(portal: URL, order: Int)] = []
        var degraded: [(portal: URL, failedAt: TimeInterval, order: Int)] = []

        for (order, portal) in portals.enumerated() {
            let entry = health[portal]
            if let until = entry?.degradedUntil, until > now {
                degraded.append((portal, entry?.lastFailedAt ?? 0, order))
            } else if let rtt = entry?.measuredRTT {
                measuredHealthy.append((portal, rtt, order))
            } else {
                unmeasuredHealthy.append((portal, order))
            }
        }

        measuredHealthy.sort { lhs, rhs in
            if lhs.rtt != rhs.rtt { return lhs.rtt < rhs.rtt }
            return lhs.order < rhs.order
        }

        var ordered: [URL] = measuredHealthy.map(\.portal) + unmeasuredHealthy.map(\.portal)

        // Keep the current preferred portal at the head unless another healthy portal is
        // meaningfully faster (beyond hysteresis) or preferred has no RTT while another does.
        if let preferred = preferredPortal, let prefIndex = ordered.firstIndex(of: preferred), prefIndex > 0 {
            if let prefRTT = health[preferred]?.measuredRTT,
               let bestRTT = measuredHealthy.first?.rtt {
                if prefRTT - bestRTT <= Self.preferredHysteresisSeconds {
                    ordered.remove(at: prefIndex)
                    ordered.insert(preferred, at: 0)
                }
            } else if measuredHealthy.isEmpty {
                ordered.remove(at: prefIndex)
                ordered.insert(preferred, at: 0)
            }
        }

        degraded.sort { lhs, rhs in
            if lhs.failedAt != rhs.failedAt { return lhs.failedAt < rhs.failedAt }
            return lhs.order < rhs.order
        }
        ordered += degraded.map(\.portal)
        return ordered
    }

    func recordSuccess(_ portal: URL, rtt: TimeInterval? = nil, promote: Bool = true) {
        guard portals.contains(portal) else { return }
        var entry = health[portal] ?? PortalHealth()
        entry.degradedUntil = nil
        entry.lastFailedAt = nil
        if let rtt, rtt.isFinite, rtt >= 0 {
            entry.measuredRTT = rtt
        }
        health[portal] = entry
        if promote { preferredPortal = portal }
    }

    func recordFailure(_ portal: URL) {
        guard portals.contains(portal) else { return }
        let now = uptime()
        var entry = health[portal] ?? PortalHealth()
        entry.degradedUntil = now + cooldownSeconds
        entry.lastFailedAt = now
        entry.measuredRTT = nil
        health[portal] = entry
        if preferredPortal == portal { preferredPortal = nil }
    }

    func applyProbeResults(_ results: [ProbeResult]) -> URL? {
        for result in results {
            if result.failed {
                recordFailure(result.portal)
            } else {
                recordSuccess(result.portal, rtt: result.rtt, promote: false)
            }
        }
        let best = orderedPortals().first
        if let best, health[best]?.degradedUntil == nil {
            preferredPortal = best
        }
        return best
    }

    /// Rewrites `url` from `sourcePortal` to `targetPortal` preserving the relative path
    /// and percent-encoded query. Returns `nil` when `url` does not belong to `sourcePortal`.
    static func rewriting(_ url: URL, from sourcePortal: URL, to targetPortal: URL) -> URL? {
        guard IPTVCredential.sameOrigin(sourcePortal, url),
              let urlParts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sourceParts = URLComponents(url: sourcePortal, resolvingAgainstBaseURL: false),
              var targetParts = URLComponents(url: targetPortal, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var sourceBase = sourceParts.percentEncodedPath
        while sourceBase.hasSuffix("/") { sourceBase.removeLast() }
        let urlPath = urlParts.percentEncodedPath
        let suffix: String
        if sourceBase.isEmpty {
            suffix = urlPath
        } else if urlPath == sourceBase {
            suffix = ""
        } else if urlPath.hasPrefix(sourceBase + "/") {
            suffix = String(urlPath.dropFirst(sourceBase.count))
        } else {
            return nil
        }
        var targetBase = targetParts.percentEncodedPath
        while targetBase.hasSuffix("/") { targetBase.removeLast() }
        targetParts.percentEncodedPath = targetBase + suffix
        targetParts.percentEncodedQuery = urlParts.percentEncodedQuery
        targetParts.fragment = nil
        return targetParts.url
    }

    /// Only transport/DNS/TLS/timeout and transient server errors trigger failover.
    /// Auth refusals (401/403), expired accounts, 404, 451, rate limits (429/509),
    /// and 503 connection-limit conflicts (`AppError.conflict`) never fail over.
    static func shouldFailOver(after error: any Error, httpStatus: Int? = nil) -> Bool {
        if error is CancellationError { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return false }

        switch error {
        case IPTVError.authentication, IPTVError.expired, IPTVError.unsupported,
             AppError.unauthorized, AppError.notFound, AppError.conflict,
             AppError.rateLimited, AppError.accessRestricted:
            return false
        case AppError.serverUnreachable:
            return true
        case IPTVError.httpStatus(let status):
            return status == 408 || (500...599).contains(status)
        default:
            break
        }

        if let httpStatus {
            if [401, 403, 404, 405, 429, 451, 501, 509].contains(httpStatus) { return false }
            if httpStatus == 408 || (500...599).contains(httpStatus) { return true }
        }

        if nsError.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorCannotLoadFromNetwork,
                NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorCannotParseResponse
            ].contains(nsError.code)
        }
        return false
    }
}
