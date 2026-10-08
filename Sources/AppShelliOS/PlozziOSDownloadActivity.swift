#if os(iOS)
import BackgroundTasks
import CoreNetworking
import Foundation
import MediaDownloads

@MainActor
protocol PlozziOSDownloadActivityTask: AnyObject, Sendable {
    func onExpiration(_ handler: @escaping @Sendable () -> Void)
    func update(_ progress: DownloadActivityProgress)
    func complete(success: Bool)
}

@MainActor
protocol PlozziOSDownloadActivityScheduling: Sendable {
    func submit(
        identifier: String,
        progress: DownloadActivityProgress,
        onStart: @escaping @MainActor @Sendable (any PlozziOSDownloadActivityTask) -> Void
    ) async throws
    func cancel(identifier: String)
}

@MainActor
final class PlozziOSDownloadActivity {
    private let scheduler: any PlozziOSDownloadActivityScheduling
    private let beginExecution: @MainActor (DownloadBackgroundExecutionLease) async -> Bool
    private let pauseExpiredWork: @MainActor ([String: Date]) async -> Void
    private let beforeCompletion: @MainActor () async -> Void
    private var identifier: String?
    private var task: (any PlozziOSDownloadActivityTask)?
    private var lease: DownloadBackgroundExecutionLease?
    private var tracked: [String: Date] = [:]
    private var attempted: [String: Date] = [:]
    private var latestRecords: [DownloadedMediaRecord] = []
    private var latestRate: Int64 = 0
    private var isActivating = false
    private var isExpiring = false
    private var retired = false
    private var expirationTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?

    var hasExecutionLease: Bool { lease?.isValid == true }

    nonisolated static func systemScheduler() -> (any PlozziOSDownloadActivityScheduling)? {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { return PlozziOSSystemDownloadActivityScheduler() }
        #endif
        return nil
    }

    func allowRetry() { attempted.removeAll() }

    init(
        scheduler: any PlozziOSDownloadActivityScheduling,
        beginExecution: @escaping @MainActor (DownloadBackgroundExecutionLease) async -> Bool,
        pauseExpiredWork: @escaping @MainActor ([String: Date]) async -> Void,
        beforeCompletion: @escaping @MainActor () async -> Void = {}
    ) {
        self.scheduler = scheduler
        self.beginExecution = beginExecution
        self.pauseExpiredWork = pauseExpiredWork
        self.beforeCompletion = beforeCompletion
    }

    deinit {
        lease?.invalidate()
        let task = task
        let scheduler = scheduler
        let identifier = identifier
        Task { @MainActor in
            if let identifier { scheduler.cancel(identifier: identifier) }
            task?.complete(success: false)
        }
    }

    func waitForExpiration() async {
        await expirationTask?.value
    }

    func start(records: [DownloadedMediaRecord]) async {
        guard !retired, !isExpiring else { return }
        if identifier == nil {
            let generations = Dictionary(records.map { ($0.identityKey, $0.createdAt) },
                                         uniquingKeysWith: { _, latest in latest })
            attempted = attempted.filter { generations[$0.key] == $0.value }
            guard records.contains(where: {
                $0.status.isActive && attempted[$0.identityKey] != $0.createdAt
            }) else { return }
        }
        for record in records where record.status.isActive {
            tracked[record.identityKey] = record.createdAt
            attempted[record.identityKey] = record.createdAt
        }
        latestRecords = records
        guard !tracked.isEmpty else { return }
        if identifier != nil {
            update(records: records, bytesPerSecond: latestRate)
            return
        }
        let id = "\(Bundle.main.bundleIdentifier ?? "com.thatcube.Plozz").downloads.\(UUID().uuidString)"
        identifier = id
        do {
            try await scheduler.submit(identifier: id, progress: progress) { [weak self] task in
                guard let self else {
                    task.complete(success: false)
                    return
                }
                Task { await self.didStart(task, identifier: id) }
            }
            if identifier != id { scheduler.cancel(identifier: id) }
        } catch {
            guard identifier == id else { return }
            finish(success: false)
            let failure = error as NSError
            PlozzLog.app.info(
                "Download Live Activity not admitted: \(failure.domain) (\(failure.code)); retaining normal download policy"
            )
        }
    }

    func update(records: [DownloadedMediaRecord], bytesPerSecond: Int64) {
        latestRecords = records
        latestRate = bytesPerSecond
        guard identifier != nil, !isActivating, !isExpiring else { return }
        let snapshot = progress
        let awaitingBackgroundAdmission = task == nil && trackedRecords.contains {
            $0.status == .paused && $0.pauseReason == .directShareBackground
        }
        if !snapshot.hasActiveWork, !awaitingBackgroundAdmission {
            finishAfterPendingNotifications()
        } else {
            task?.update(snapshot)
        }
    }

    func retire() {
        retired = true
        finish(success: false)
    }

    private var trackedRecords: [DownloadedMediaRecord] {
        latestRecords.filter { tracked[$0.identityKey] == $0.createdAt }
    }

    private var progress: DownloadActivityProgress {
        DownloadActivityProgress(records: trackedRecords, bytesPerSecond: latestRate)
    }

    private func didStart(_ task: any PlozziOSDownloadActivityTask, identifier: String) async {
        guard !retired, self.identifier == identifier, self.task == nil else {
            task.complete(success: false)
            return
        }
        self.task = task
        let lease = DownloadBackgroundExecutionLease()
        self.lease = lease
        isActivating = true
        task.onExpiration { [weak self, lease] in
            lease.invalidate()
            Task { @MainActor in
                guard let self, self.identifier == identifier else { return }
                self.beginExpiration(identifier: identifier)
            }
        }
        let admitted = await beginExecution(lease)
        guard self.identifier == identifier else { return }
        isActivating = false
        guard lease.isValid else {
            beginExpiration(identifier: identifier)
            return
        }
        guard admitted else {
            finish(success: false)
            return
        }
        update(records: latestRecords, bytesPerSecond: latestRate)
    }

    private func beginExpiration(identifier: String) {
        guard self.identifier == identifier, !isExpiring else { return }
        isExpiring = true
        lease?.invalidate()
        expirationTask = Task { await self.expire(identifier: identifier) }
    }

    private func expire(identifier: String) async {
        await pauseExpiredWork(tracked)
        if self.identifier == identifier { finish(success: false) }
        isExpiring = false
        expirationTask = nil
    }

    private func finishAfterPendingNotifications() {
        guard completionTask == nil, let identifier else { return }
        completionTask = Task { [weak self] in
            guard let self else { return }
            await beforeCompletion()
            guard self.identifier == identifier, !Task.isCancelled else { return }
            completionTask = nil
            guard !isExpiring else { return }
            let snapshot = progress
            guard !snapshot.hasActiveWork else { return }
            task?.update(snapshot)
            finish(success: snapshot.succeeded)
        }
    }

    private func finish(success: Bool) {
        completionTask?.cancel()
        completionTask = nil
        lease?.invalidate()
        lease = nil
        if let identifier { scheduler.cancel(identifier: identifier) }
        task?.complete(success: success)
        task = nil
        identifier = nil
        tracked.removeAll()
        isActivating = false
    }
}

#if !targetEnvironment(macCatalyst)
@available(iOS 26.0, *)
@MainActor
struct PlozziOSSystemDownloadActivityScheduler: PlozziOSDownloadActivityScheduling {
    private enum RegistrationError: Error { case identifierNotPermitted }

    nonisolated init() {}

    func submit(
        identifier: String,
        progress: DownloadActivityProgress,
        onStart: @escaping @MainActor @Sendable (any PlozziOSDownloadActivityTask) -> Void
    ) async throws {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    PlozzLog.app.error("Download activity received an unexpected background task type")
                    task.setTaskCompleted(success: false)
                    return
                }
                onStart(PlozziOSSystemDownloadActivityTask(task: task))
            }
        }
        guard registered else { throw RegistrationError.identifierNotPermitted }
        let title = Self.title(for: progress)
        let subtitle = Self.subtitle(for: progress)
        // Construct/submit away from the main executor, including the iOS 27
        // asynchronous submission API. Rejection must not stop HTTP transfers.
        try await Task.detached {
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier, title: title, subtitle: subtitle
            )
            request.strategy = .fail
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
                return
            }
            #endif
            try BGTaskScheduler.shared.submit(request)
        }.value
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    static func title( // l10n:content - pinned media metadata and resolved system activity copy.
        for progress: DownloadActivityProgress,
        locale: Locale = .current
    ) -> String {
        if let title = progress.displayTitle {
            if let item = progress.currentItem, let episode = episodeLabel(item, locale: locale) {
                return joinedDetails(title, episode, locale: locale)
            }
            return title
        }
        if progress.activeItemCount > 1 {
            let count = progress.activeItemCount.formatted(.number.locale(locale))
            return resolve(
                .init("Active downloads: \(count)", comment: "Live Activity title for several unrelated downloads running at once. Placeholder is the localized number currently preparing, transferring, or finishing."),
                locale: locale
            )
        }
        return resolve("Downloads", locale: locale)
    }

    static func subtitle( // l10n:content - resolved text for the system task, refreshed on each update.
        for progress: DownloadActivityProgress,
        locale: Locale = .current
    ) -> String {
        let completed = progress.completedCount.formatted(.number.locale(locale))
        let total = progress.totalCount.formatted(.number.locale(locale))
        let completion = resolve(
            .init("Completed: \(completed) of \(total)", comment: "Compact download Live Activity completion count. First placeholder is the localized number fully finished; second is the total. Keep an explicit completion label, including when zero have finished. This is not the current download's position."),
            locale: locale
        )
        if progress.succeeded, progress.totalCount > 1 { return completion }
        let detail: String
        if progress.activeItemCount > 1 {
            if progress.displayTitle == nil { return completion }
            let count = progress.activeItemCount.formatted(.number.locale(locale))
            detail = resolve(
                .init("Active: \(count)", comment: "Compact Live Activity label counting downloads currently preparing, transferring, or finishing in parallel. The placeholder is a locale-formatted count."),
                locale: locale
            )
        } else if let item = progress.currentItem {
            if let number = progress.currentItemNumber, progress.totalCount > 1 {
                let current = number.formatted(.number.locale(locale))
                let stage: String
                switch item.phase {
                case .preparing:
                    stage = resolve(
                        .init("Preparing \(current) of \(total)", comment: "Compact Live Activity subtitle for sequential downloads. First placeholder is the one-based current download number, second is the queue total. This item is being prepared, not yet transferred. Both numbers are already localized."),
                        locale: locale
                    )
                case .downloading:
                    stage = resolve(
                        .init("Downloading \(current) of \(total)", comment: "Compact Live Activity subtitle for sequential downloads. First placeholder is the one-based current download number, second is the queue total. This is the item in progress, not a completed count. Both numbers are already localized."),
                        locale: locale
                    )
                case .finishing:
                    stage = resolve(
                        .init("Finishing \(current) of \(total)", comment: "Compact Live Activity subtitle for sequential downloads. First placeholder is the one-based current download number, second is the queue total. Bytes have arrived, but validation/finalization is not complete. Both numbers are already localized."),
                        locale: locale
                    )
                }
                if let percentage = percentage(for: item, locale: locale) {
                    return joinedDetails(stage, percentage, locale: locale)
                }
                return stage
            }
            detail = Self.detail(for: item, locale: locale)
        } else {
            detail = resolve(status(for: progress.status), locale: locale)
        }
        if progress.totalCount > 1 {
            return joinedDetails(detail, completion, locale: locale)
        }
        return detail
    }

    private static func joinedDetails( // l10n:content - independent localized fragments, not a translatable phrase.
        _ first: String, _ second: String, locale: Locale
    ) -> String {
        if locale.language.characterDirection == .rightToLeft {
            return "\u{2068}\(first)\u{2069} · \u{2068}\(second)\u{2069}"
        }
        return "\(first) · \(second)"
    }

    private static func detail( // l10n:content - resolved system activity text and measured numeric data.
        for item: DownloadActivityProgress.ItemProgress,
        locale: Locale
    ) -> String {
        switch item.phase {
        case .preparing:
            if let percentage = percentage(for: item, locale: locale) {
                return resolve(
                    .init("Preparing \(percentage)", comment: "Live Activity preparation stage followed by its measured, already localized percentage. This is server preparation, not downloaded bytes or overall batch progress."),
                    locale: locale
                )
            }
            return resolve("Preparing Download", locale: locale)
        case .downloading:
            if let percentage = percentage(for: item, locale: locale) {
                return joinedDetails(resolve("Downloading", locale: locale), percentage, locale: locale)
            }
            return resolve("Downloading", locale: locale)
        case .finishing:
            return resolve(
                .init("Finishing", comment: "Download Live Activity status after the media bytes arrive while the engine validates and finalizes the offline copy. It is not complete yet."),
                locale: locale
            )
        }
    }

    private static func percentage(
        for item: DownloadActivityProgress.ItemProgress, locale: Locale
    ) -> String? {
        guard item.phase != .finishing, let fraction = item.fractionCompleted else { return nil }
        let value = item.phase == .downloading ? min(0.99, fraction) : fraction
        return value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    private static func episodeLabel(
        _ item: DownloadActivityProgress.ItemProgress,
        locale: Locale
    ) -> String? { // l10n:content - pinned media title or the app's S/E episode notation.
        if let episode = item.episodeNumber, episode >= 0 {
            let episodeLabel = "E\(episode.formatted(.number.locale(locale)))"
            if let season = item.seasonNumber, season >= 0 {
                return "S\(season.formatted(.number.locale(locale))) \(episodeLabel)"
            }
            return episodeLabel
        }
        return nil
    }

    private static func status(for status: DownloadStatus) -> LocalizedStringResource {
        let resource: LocalizedStringResource
        switch status {
        case .completed: resource = "Download Complete"
        case .failed: resource = "Download Failed"
        case .paused: resource = "Download Paused"
        case .preparing: resource = "Preparing Download"
        case .queued: resource = "Queued"
        case .downloading: resource = "Downloading"
        }
        return resource
    }

    private static func resolve(
        _ resource: LocalizedStringResource, locale: Locale
    ) -> String { // l10n:content - localized system API boundary.
        var resource = resource
        resource.locale = locale
        return String(localized: resource) // l10n:content - system API boundary, resolved using this update's locale.
    }
}

@available(iOS 26.0, *)
@MainActor
private final class PlozziOSSystemDownloadActivityTask: PlozziOSDownloadActivityTask {
    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) { self.task = task }

    func onExpiration(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func update(_ progress: DownloadActivityProgress) {
        task.progress.totalUnitCount = max(1, progress.totalUnitCount)
        task.progress.completedUnitCount = progress.completedUnitCount
        task.progress.estimatedTimeRemaining = progress.estimatedTimeRemaining
        task.updateTitle(
            PlozziOSSystemDownloadActivityScheduler.title(for: progress),
            subtitle: PlozziOSSystemDownloadActivityScheduler.subtitle(for: progress)
        )
    }

    func complete(success: Bool) {
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }
}
#endif
#endif
