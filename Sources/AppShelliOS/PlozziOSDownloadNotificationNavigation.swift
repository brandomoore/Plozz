#if os(iOS)
import CoreNetworking
import Foundation
import MediaDownloads
import Observation
import SwiftUI
import UserNotifications

struct PlozziOSDownloadNotificationTarget: Equatable, Sendable {
    let profileID: String
    let identityKey: String
    let recordCreatedAt: Date
    let batchID: String?

    init(profileID: String, notice: DownloadNotification) {
        self.profileID = profileID
        identityKey = notice.identityKey
        recordCreatedAt = notice.recordCreatedAt
        batchID = notice.kind == .batchCompleted ? notice.batchID : nil
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let payload = userInfo["plozz.download"] as? [String: Any],
              payload["version"] as? Int == 1,
              let profileID = payload["profile"] as? String, !profileID.isEmpty,
              let identityKey = payload["item"] as? String, !identityKey.isEmpty,
              let createdAt = payload["createdAt"] as? Double, createdAt.isFinite,
              payload["batch"] == nil || payload["batch"] is String else { return nil }
        let batchID = payload["batch"] as? String
        guard batchID == nil || batchID?.isEmpty == false else { return nil }
        self.profileID = profileID
        self.identityKey = identityKey
        recordCreatedAt = Date(timeIntervalSinceReferenceDate: createdAt)
        self.batchID = batchID
    }

    var userInfo: [AnyHashable: Any] {
        var payload: [String: Any] = [
            "version": 1,
            "profile": profileID,
            "item": identityKey,
            // Reference-date seconds preserve the registry's exact Date value.
            "createdAt": recordCreatedAt.timeIntervalSinceReferenceDate,
        ]
        if let batchID { payload["batch"] = batchID }
        return ["plozz.download": payload]
    }
}

enum PlozziOSDownloadNotificationDestination: Hashable {
    case library
    case item(identityKey: String, createdAt: Date)
    case show(id: String, seasonID: String?)
    case unavailable

    static func resolve(
        _ target: PlozziOSDownloadNotificationTarget,
        records: [DownloadedMediaRecord]
    ) -> Self {
        if let batchID = target.batchID {
            let batch = records.filter { $0.batchID == batchID && $0.status == .completed }
            guard !batch.isEmpty else { return .unavailable }
            let shows = PlozziOSDownloadLibrary.make(from: records).shows.filter { show in
                show.records.contains { $0.batchID == batchID && $0.status == .completed }
            }
            guard shows.count == 1, let show = shows.first else { return .library }
            let seasons = show.seasons.filter { season in
                season.records.contains { $0.batchID == batchID && $0.status == .completed }
            }
            return .show(id: show.id, seasonID: seasons.count == 1 ? seasons.first?.id : nil)
        }
        guard records.contains(where: {
            $0.identityKey == target.identityKey && $0.createdAt == target.recordCreatedAt
                && $0.status == .completed
        }) else { return .unavailable }
        return .item(identityKey: target.identityKey, createdAt: target.recordCreatedAt)
    }
}

@MainActor
@Observable
final class PlozziOSDownloadNotificationNavigation {
    struct Request {
        let id = UUID()
        let target: PlozziOSDownloadNotificationTarget
    }

    struct Presentation {
        let id: UUID
        let profileID: String
        let destination: PlozziOSDownloadNotificationDestination
    }

    struct Context: Equatable {
        let requestID: UUID?
        let targetExists: Bool
        let activeProfileID: String
        let canEnterApp: Bool
        let profileIsAuthorized: Bool
        let profileGateIsPresented: Bool
        let downloadsAreReady: Bool
        let presentationIsAvailable: Bool
    }

    static let shared = PlozziOSDownloadNotificationNavigation()
    private(set) var pending: Request?
    private(set) var presentation: Presentation?
    var profileUnavailable = false
    @ObservationIgnored private var activationRequestedFor: UUID?
    @ObservationIgnored private var selectedTabFor: UUID?
    @ObservationIgnored private var openedDestinationFor: UUID?

    func receive(_ target: PlozziOSDownloadNotificationTarget) {
        pending = Request(target: target)
        profileUnavailable = false
    }

    func cancelPending() {
        pending = nil
    }

    func advance(
        context: Context,
        selectProfile: (String) -> Void,
        resolve: (PlozziOSDownloadNotificationTarget) -> PlozziOSDownloadNotificationDestination
    ) {
        guard let request = pending, context.requestID == request.id,
              context.canEnterApp else { return }
        guard context.presentationIsAvailable else { return }
        guard context.targetExists else {
            PlozzLog.app.info("Download notification target profile no longer exists")
            pending = nil
            profileUnavailable = true
            return
        }
        guard context.activeProfileID == request.target.profileID, context.profileIsAuthorized else {
            guard !context.profileGateIsPresented,
                  activationRequestedFor != request.id else { return }
            activationRequestedFor = request.id
            selectProfile(request.target.profileID)
            return
        }
        guard context.downloadsAreReady else { return }
        let destination = resolve(request.target)
        if destination == .unavailable {
            PlozzLog.app.info("Download notification target no longer matches a completed download")
        }
        presentation = Presentation(id: request.id, profileID: request.target.profileID, destination: destination)
        pending = nil
    }

    func claimTabSelection(profileID: String) -> Bool {
        guard let presentation, presentation.profileID == profileID,
              selectedTabFor != presentation.id else { return false }
        selectedTabFor = presentation.id
        return true
    }

    func claimDestination(profileID: String) -> PlozziOSDownloadNotificationDestination? {
        guard let presentation, presentation.profileID == profileID,
              selectedTabFor == presentation.id,
              openedDestinationFor != presentation.id else { return nil }
        openedDestinationFor = presentation.id
        return presentation.destination
    }
}

struct PlozziOSDownloadNotificationRouting: ViewModifier {
    @Bindable var navigation: PlozziOSDownloadNotificationNavigation
    let context: PlozziOSDownloadNotificationNavigation.Context
    let preparePresentation: () -> Void
    let selectProfile: (String) -> Void
    let resolve: (PlozziOSDownloadNotificationTarget) -> PlozziOSDownloadNotificationDestination

    func body(content: Content) -> some View {
        content
            .onChange(of: navigation.pending?.id, initial: true) { _, _ in
                preparePresentation()
            }
            .onChange(of: context, initial: true) { _, _ in
                navigation.advance(context: context, selectProfile: selectProfile, resolve: resolve)
            }
            .alert("Downloads Unavailable", isPresented: $navigation.profileUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This profile is no longer available.")
            }
    }
}

public enum PlozziOSDownloadNotificationBridge {
    @MainActor
    public static func activate() {
        UNUserNotificationCenter.current().delegate = PlozziOSDownloadNotificationDelegate.shared
    }

    static func target(
        actionIdentifier: String, requestIdentifier: String, userInfo: [AnyHashable: Any]
    ) -> PlozziOSDownloadNotificationTarget? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              requestIdentifier.hasPrefix("plozz.download.") else { return nil }
        guard userInfo["plozz.download"] != nil else {
            PlozzLog.app.info("Download notification has no navigation metadata")
            return nil
        }
        guard let target = PlozziOSDownloadNotificationTarget(userInfo: userInfo) else {
            PlozzLog.app.error("Download notification navigation payload is missing or invalid")
            return nil
        }
        return target
    }
}

@MainActor
private final class PlozziOSDownloadNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PlozziOSDownloadNotificationDelegate()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let target = PlozziOSDownloadNotificationBridge.target(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier,
            userInfo: response.notification.request.content.userInfo
        ) else { return }
        await PlozziOSDownloadNotificationNavigation.shared.receive(target)
    }
}
#endif
