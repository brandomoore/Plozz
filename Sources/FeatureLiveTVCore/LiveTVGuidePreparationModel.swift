import CoreModels
import CoreNetworking
import Foundation
import Observation

/// Owns explicitly requested guide work beyond the setup/source sheet's lifetime.
@MainActor
@Observable
public final class LiveTVGuidePreparationModel {
    public struct Status: Identifiable, Equatable {
        public enum Phase: Equatable {
            case loading, loaded, empty, notConfigured, paused
            case failed(LiveTVServerImportError)
        }

        public let id: String
        public let requestID = UUID()
        public var phase: Phase
        public var progress: ServerLiveTVGuideProgress?
        public let isRefresh: Bool
        public var channelCount: Int?
        public var channelsWithListings = 0
        public var refreshedAt: Date?
    }

    public private(set) var statuses: [String: Status] = [:]
    public private(set) var completionRevision = 0
    private var notificationOrder: [String] = []
    private var dismissedNotifications = Set<String>()
    @ObservationIgnored private var notificationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let resolver: LiveTVServerProviderResolver
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var authorizations: [String: String] = [:]
    @ObservationIgnored private var requests: [String: UUID] = [:]
    @ObservationIgnored private var observationRevision = 0

    public init(
        resolver: @escaping LiveTVServerProviderResolver,
        clock: @escaping @MainActor () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.clock = clock
    }

    deinit {
        for task in tasks.values { task.cancel() }
        for task in notificationTasks.values { task.cancel() }
    }

    public var notificationStatus: Status? {
        let candidates = notificationOrder.compactMap { id -> Status? in
            guard !dismissedNotifications.contains(id) else { return nil }
            return statuses[id]
        }
        return candidates.first { $0.phase == .loading } ?? candidates.first
    }

    public func dismissNotification(accountID: String, requestID: UUID) {
        guard statuses[accountID]?.requestID == requestID else { return }
        dismissedNotifications.insert(accountID)
    }

    public func canPrepare(accountID: String) -> Bool {
        resolver(accountID)?.kind == .iptv
    }

    public func start(accountID: String, refresh: Bool = false) {
        guard tasks[accountID] == nil else { return }
        guard let context = resolver(accountID), context.kind == .iptv else {
            PlozzLog.app.error("Guide preparation rejected outside an authorized IPTV account")
            return
        }
        let request = UUID()
        requests[accountID] = request
        authorizations[accountID] = context.authorizationID
        var status = Status(id: accountID, phase: .loading, isRefresh: refresh)
        status.channelCount = statuses[accountID]?.channelCount
        status.channelsWithListings = statuses[accountID]?.channelsWithListings ?? 0
        status.refreshedAt = statuses[accountID]?.refreshedAt
        statuses[accountID] = status
        notificationTasks.removeValue(forKey: accountID)?.cancel()
        dismissedNotifications.remove(accountID)
        notificationOrder.removeAll { $0 == accountID }
        notificationOrder.append(accountID)
        tasks[accountID] = Task { [weak self] in
            await self?.prepareReportingProgress(context, request: request, refresh: refresh)
        }
        observeAuthorization()
    }

    public func cancel(accountID: String) {
        tasks.removeValue(forKey: accountID)?.cancel()
        requests.removeValue(forKey: accountID)
        if statuses[accountID]?.phase == .loading {
            statuses[accountID]?.phase = .paused
        }
        dismissedNotifications.insert(accountID)
    }

    func waitForCompletion(accountID: String) async {
        await tasks[accountID]?.value
    }

    private func isCurrent(_ context: LiveTVAuthorizedServerProvider, request: UUID) -> Bool {
        requests[context.accountID] == request
            && resolver(context.accountID)?.authorizationID == context.authorizationID
    }

    private func prepareReportingProgress(
        _ context: LiveTVAuthorizedServerProvider, request: UUID, refresh: Bool
    ) async {
        let (stream, continuation) = AsyncStream<ServerLiveTVGuideProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let observer = Task { [weak self] in
            for await progress in stream {
                guard let self, self.isCurrent(context, request: request),
                      self.statuses[context.accountID]?.phase == .loading else { continue }
                self.statuses[context.accountID]?.progress = progress
            }
        }
        await ServerLiveTVGuideProgress.$report.withValue({ continuation.yield($0) }) {
            await prepare(context, request: request, refresh: refresh)
        }
        continuation.finish()
        await observer.value
        guard isCurrent(context, request: request), let status = statuses[context.accountID] else { return }
        notificationTasks[context.accountID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch is CancellationError { return }
            catch {
                PlozzLog.app.error("Guide notification dismissal wait failed")
                return
            }
            self?.dismissNotification(accountID: status.id, requestID: status.requestID)
            self?.notificationTasks[status.id] = nil
        }
    }

    private func prepare(
        _ context: LiveTVAuthorizedServerProvider, request: UUID, refresh: Bool
    ) async {
        let id = context.accountID
        defer {
            if requests[id] == request { tasks[id] = nil }
        }
        do {
            try Task.checkCancellation()
            let availability = try await context.provider.liveTVAvailability()
            guard isCurrent(context, request: request) else { return }
            try Task.checkCancellation()
            statuses[id]?.channelCount = availability.channelCount
            switch availability.status {
            case .available, .noChannels, .unsupportedPlaybackMode: break
            case .notConfigured: throw LiveTVServerImportError.guideRequired
            case .permissionDenied: throw LiveTVServerImportError.permissionDenied
            case .subscriptionRequired: throw LiveTVServerImportError.subscriptionRequired
            case .unsupportedAPI: throw LiveTVServerImportError.unsupportedAPI
            case .serviceUnavailable: throw LiveTVServerImportError.guideUnavailable
            }
            let supportsGuide = try await context.provider.completeLiveTVGuideDiscovery() ?? availability.supportsGuide
            try Task.checkCancellation()
            guard isCurrent(context, request: request) else { return }
            guard supportsGuide else {
                statuses[id]?.phase = .notConfigured
                return
            }
            if refresh { await context.provider.invalidateLiveTVGuideCache() }
            try Task.checkCancellation()
            guard isCurrent(context, request: request) else { return }
            let channels = try await context.provider.liveTVChannels()
            guard isCurrent(context, request: request) else { return }
            try Task.checkCancellation()
            statuses[id]?.channelCount = channels.count
            let from = clock()
            let to = from.addingTimeInterval(6 * 3_600)
            var matched = Set<String>()
            try await ServerLiveTVGuideRefreshScope.$current.withValue(ServerLiveTVGuideRefreshScope()) {
                for offset in stride(from: 0, to: channels.count, by: 2_000) {
                    try Task.checkCancellation()
                    guard isCurrent(context, request: request) else { throw CancellationError() }
                    let ids = channels[offset..<min(offset + 2_000, channels.count)].map(\.id)
                    let programs = try await context.provider.liveTVGuide(channelIDs: ids, from: from, to: to)
                    try Task.checkCancellation()
                    guard isCurrent(context, request: request) else { throw CancellationError() }
                    let requested = Set(ids)
                    matched.formUnion(programs.filter {
                        requested.contains($0.channelID) && $0.startDate < to && $0.endDate > from
                    }.map(\.channelID))
                    statuses[id]?.progress = .init(
                        stage: .matching, completed: min(offset + ids.count, channels.count), total: channels.count
                    )
                }
            }
            guard isCurrent(context, request: request) else { return }
            statuses[id]?.channelsWithListings = matched.count
            statuses[id]?.refreshedAt = clock()
            statuses[id]?.phase = matched.isEmpty ? .empty : .loaded
            completionRevision &+= 1
        } catch {
            guard isCurrent(context, request: request) else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                statuses[id]?.phase = .paused
            } else {
                let underlying = (error as? ServerLiveTVPartialGuideError)?.failure ?? error
                statuses[id]?.phase = .failed(LiveTVServerImportError.sanitizedGuide(underlying))
                PlozzLog.app.error("IPTV guide preparation failed; existing listings retained")
            }
        }
    }

    private func observeAuthorization() {
        observationRevision &+= 1
        let revision = observationRevision
        withObservationTracking {
            for id in authorizations.keys { _ = resolver(id)?.authorizationID }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationRevision == revision else { return }
                for (id, authorization) in self.authorizations {
                    if self.resolver(id)?.authorizationID != authorization {
                        self.cancel(accountID: id)
                        self.statuses[id] = nil
                        self.notificationTasks.removeValue(forKey: id)?.cancel()
                        self.notificationOrder.removeAll { $0 == id }
                        self.dismissedNotifications.remove(id)
                        self.authorizations[id] = nil
                    }
                }
                self.observeAuthorization()
            }
        }
    }
}
