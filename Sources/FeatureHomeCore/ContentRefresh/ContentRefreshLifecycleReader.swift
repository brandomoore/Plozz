#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Zero-size app-lifecycle adapter. UIKit's activation notification is used
/// instead of relying on a coalesced SwiftUI `scenePhase` change across
/// suspend/resume, which can leave Home believing it never left the foreground.
public struct ContentRefreshLifecycleReader: View {
    private let coordinator: ContentRefreshCoordinator

    public init(coordinator: ContentRefreshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear {
                if UIApplication.shared.applicationState != .active {
                    coordinator.applicationWillResignActive()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.willResignActiveNotification
                )
            ) { _ in
                coordinator.applicationWillResignActive()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didBecomeActiveNotification
                )
            ) { _ in
                coordinator.applicationDidBecomeActive()
            }
    }
}
#endif
