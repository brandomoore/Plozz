import CoreModels
import FeatureLiveTVCore
import SwiftUI

private struct LiveTVGuideAutoUpdateModifier: ViewModifier {
    let accountIDs: [String]
    let authorizationID: String
    let isAuthorized: Bool
    let namespace: String?
    let resolver: LiveTVServerProviderResolver
    @Environment(\.scenePhase) private var scenePhase
    @State private var interval: LiveTVGuideUpdateInterval

    init(
        accountIDs: [String], authorizationID: String, isAuthorized: Bool,
        namespace: String?, resolver: @escaping LiveTVServerProviderResolver
    ) {
        self.accountIDs = accountIDs
        self.authorizationID = authorizationID
        self.isAuthorized = isAuthorized
        self.namespace = namespace
        self.resolver = resolver
        _interval = State(initialValue: Self.interval(namespace))
    }

    private static func interval(_ namespace: String?) -> LiveTVGuideUpdateInterval {
        LiveTVViewSettingsStore(namespace: namespace).load().guideUpdateInterval
    }

    private struct Run: Equatable {
        let accountIDs: [String]
        let authorizationID: String
        let seconds: TimeInterval?
        let isActive: Bool
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: LiveTVViewSettingsStore.didChange)) { _ in
                interval = Self.interval(namespace)
            }
            .onChange(of: namespace) { _, namespace in interval = Self.interval(namespace) }
            .task(
                id: Run(
                    accountIDs: accountIDs, authorizationID: authorizationID, seconds: interval.seconds,
                    isActive: isAuthorized && scenePhase == .active
                ),
                priority: .utility
            ) {
                guard isAuthorized, scenePhase == .active, let seconds = interval.seconds else { return }
                await LiveTVGuideAutoUpdate.run(accountIDs: accountIDs, interval: seconds, resolver: resolver)
            }
    }
}

public extension View {
    /// Keeps the active profile's saved programme guides current while the app is in the
    /// foreground, following that profile's "Update guide automatically" setting.
    func liveTVGuideAutoUpdate(
        accountIDs: [String], authorizationID: String, isAuthorized: Bool,
        namespace: String?, resolver: @escaping LiveTVServerProviderResolver
    ) -> some View {
        modifier(LiveTVGuideAutoUpdateModifier(
            accountIDs: accountIDs, authorizationID: authorizationID, isAuthorized: isAuthorized,
            namespace: namespace, resolver: resolver
        ))
    }
}
