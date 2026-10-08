#if os(iOS)
import CoreNetworking
import Foundation
import MediaDownloads
import UserNotifications

@MainActor
protocol PlozziOSDownloadNotificationClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func existingIdentifiers() async -> Set<String>
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
struct PlozziOSSystemDownloadNotificationClient: PlozziOSDownloadNotificationClient {
    nonisolated init() {}

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func existingIdentifiers() async -> Set<String> {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        return Set(pending.map(\.identifier) + delivered.map(\.request.identifier))
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
final class PlozziOSDownloadNotifications {
    private let profileID: String
    private let registry: DownloadedMediaRegistry
    private let client: any PlozziOSDownloadNotificationClient
    private let preferences: @MainActor () -> PlozziOSDownloadPreferences
    private var delivering = false
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestingPermission = false
    private var retired = false

    init(
        profileID: String,
        registry: DownloadedMediaRegistry,
        client: any PlozziOSDownloadNotificationClient = PlozziOSSystemDownloadNotificationClient(),
        preferences: @escaping @MainActor () -> PlozziOSDownloadPreferences
    ) {
        self.profileID = profileID
        self.registry = registry
        self.client = client
        self.preferences = preferences
    }

    func retire() { retired = true }

    func requestPermissionIfNeeded() async {
        guard !retired, !requestingPermission, preferences().notificationsEnabled else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        guard await client.authorizationStatus() == .notDetermined, !retired else { return }
        do {
            _ = try await client.requestAuthorization()
            await deliverPending()
        } catch {
            log(error, operation: "authorization")
        }
    }

    func deliverPending() async {
        guard !retired else { return }
        if delivering {
            await withCheckedContinuation { deliveryWaiters.append($0) }
            return
        }
        delivering = true
        defer {
            delivering = false
            let waiters = deliveryWaiters
            deliveryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        guard !(await registry.pendingNotifications()).isEmpty else { return }
        var existing = await client.existingIdentifiers()
        while !retired {
            let pending = await registry.pendingNotifications()
            guard !pending.isEmpty else { return }
            for notice in pending {
                guard !retired else { return }
                do {
                    let enabled = preferences().allows(notice.kind)
                    guard enabled, await registry.notificationIsCurrent(notice) else {
                        try await registry.acknowledgeNotification(notice.id)
                        continue
                    }
                    let authorization = await client.authorizationStatus()
                    guard !retired else { return }
                    guard preferences().allows(notice.kind),
                          await registry.notificationIsCurrent(notice) else {
                        try await registry.acknowledgeNotification(notice.id)
                        continue
                    }
                    guard !retired else { return }
                    // Keep the outbox while the first permission prompt is open.
                    guard authorization != .notDetermined else { return }
                    if authorization != .authorized && authorization != .provisional
                        && authorization != .ephemeral {
                        try await registry.acknowledgeNotification(notice.id)
                        continue
                    }
                    let identifier = "plozz.download.\(notice.id.uuidString)"
                    if !existing.contains(identifier) {
                        try await client.add(Self.request(for: notice, profileID: profileID, identifier: identifier))
                        existing.insert(identifier)
                    }
                    try await registry.acknowledgeNotification(notice.id)
                } catch {
                    log(error, operation: "delivery")
                    return
                }
            }
        }
    }

    private static func request(
        for notice: DownloadNotification, profileID: String, identifier: String
    ) -> UNNotificationRequest {
        let title: LocalizedStringResource
        let body: LocalizedStringResource
        switch notice.kind {
        case .failed:
            title = "Download Failed"
            body = "\(notice.title ?? "") could not be downloaded."
        case .completed, .batchCompleted:
            title = "Download Complete"
            if let title = notice.title {
                body = "\(title) is available offline."
            } else {
                body = "Downloads are available offline."
            }
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: title) // l10n:content — notification API requires resolved text.
        content.body = String(localized: body) // l10n:content — notification API requires resolved text.
        content.sound = .default
        if notice.kind != .failed {
            content.userInfo = PlozziOSDownloadNotificationTarget(profileID: profileID, notice: notice).userInfo
        }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    private func log(_ error: any Error, operation: String) {
        let failure = error as NSError
        PlozzLog.app.error("Download notification \(operation) failed: \(failure.domain) (\(failure.code))")
    }
}

struct PlozziOSDownloadPreferences: Codable {
    var asksBeforeDownloading: Bool
    var notifiesOnStandaloneCompletion: Bool
    var notifiesOnBatchCompletion: Bool
    var notifiesOnFailure: Bool

    static let `default` = PlozziOSDownloadPreferences(
        asksBeforeDownloading: true,
        notifiesOnStandaloneCompletion: true,
        notifiesOnBatchCompletion: true,
        notifiesOnFailure: false
    )

    var notificationsEnabled: Bool {
        notifiesOnStandaloneCompletion || notifiesOnBatchCompletion || notifiesOnFailure
    }

    func allows(_ kind: DownloadNotification.Kind) -> Bool {
        switch kind {
        case .completed: notifiesOnStandaloneCompletion
        case .batchCompleted: notifiesOnBatchCompletion
        case .failed: notifiesOnFailure
        }
    }

    static func load(key: String, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key) else { return .default }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            PlozzLog.app.error("Download notification preferences could not be decoded; notifications remain disabled")
            return Self(
                asksBeforeDownloading: true, notifiesOnStandaloneCompletion: false,
                notifiesOnBatchCompletion: false, notifiesOnFailure: false
            )
        }
    }
}
#endif
