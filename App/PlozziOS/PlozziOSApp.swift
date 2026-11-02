import AppShelliOS
import AppRuntime
import CoreModels
import CoreUI
import SwiftUI
import UIKit

private final class PlozziOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PlozziOSWindowOrientation.supportedOrientations(for: window)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PlozziOSDownloadNotificationBridge.activate()
        PlozziOSBackgroundSessionBridge.activate()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        PlozziOSBackgroundSessionBridge.handleEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct PlozziOSApp: App {
    @UIApplicationDelegateAdaptor(PlozziOSAppDelegate.self) private var appDelegate

    init() {
        _ = AppInstallation.current
        ProcessSignalPolicy.ignoreBrokenPipe()
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            PlozziOSRootView()
                .diagnosticRecordingStatus()
        }
    }
}
