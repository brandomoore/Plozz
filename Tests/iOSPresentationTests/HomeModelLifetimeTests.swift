#if os(iOS)
import CoreUI
import FeatureHomeCore
import SwiftUI
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeModelLifetimeTests: XCTestCase {
    func testRootUpdatesReuseTheSameHomeModel() {
        let app = PlozziOSAppModel()
        let box = LazyViewState<HomeViewModel>()
        var models: [HomeViewModel] = []
        let start = ContinuousClock.now
        for index in 0..<24 {
            let shell = PlozziOSTabShell(
                appModel: app, homeViewModelBox: box, onAddServer: {},
                showingSettings: .constant(index.isMultiple(of: 2)),
                showingProfileSwitcher: .constant(false),
                deferredPairingURL: .constant(nil),
                systemColorScheme: index.isMultiple(of: 2) ? .dark : .light
            )
            models.append(shell.sharedHomeViewModel)
        }
        let constructions = Set(models.map(ObjectIdentifier.init)).count
        print("Home root updates: 24; models: \(constructions); elapsed: \(start.duration(to: .now))")
        XCTAssertEqual(constructions, 1, "Root presentation updates must not rehydrate disposable Home models.")
    }

    func testProfileSwitchReplacesTheModelBeforeRenderingTheNewScope() {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Home lifetime fixture")
        defer {
            app.profiles.select(original)
            app.profiles.remove(profile.id)
        }
        let box = LazyViewState<HomeViewModel>()
        func model() -> HomeViewModel {
            PlozziOSTabShell(
                appModel: app, homeViewModelBox: box, onAddServer: {},
                showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
                deferredPairingURL: .constant(nil), systemColorScheme: .dark
            ).sharedHomeViewModel
        }
        let first = model()
        XCTAssertTrue(first === model())
        app.profiles.select(profile.id)
        let second = model()
        XCTAssertFalse(first === second)
        XCTAssertTrue(second === model())
        app.profiles.select(original)
        let restored = model()
        XCTAssertFalse(second === restored)
        XCTAssertFalse(first === restored, "Do not revive an obsolete credential/cache snapshot.")
    }
}
#endif
