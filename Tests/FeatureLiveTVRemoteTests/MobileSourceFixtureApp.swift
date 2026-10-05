import Foundation
import SwiftUI

@main
struct MobileSourceFixtureApp: App {
    init() {
        URLProtocol.registerClass(SourceSmokeNetworkBlocker.self)
    }

    var body: some Scene {
        WindowGroup { SourceOnboardingFixture() }
    }
}
