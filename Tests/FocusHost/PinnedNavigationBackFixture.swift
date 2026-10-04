import CoreModels
import CoreUI
import Observation
import SwiftUI
@testable import AppShell

struct PinnedNavigationBackFixture: View {
    @State private var model = PinnedNavigationBackModel()

    var body: some View {
        NavigationRailShell(
            profile: model.profile,
            entries: [],
            destinations: MainTabView.includingExplicitHome(
                model.configuredDestinations, isRequested: model.requiresHome
            ),
            selection: $model.selection,
            onOpenProfileSwitcher: {},
            chrome: model.chrome,
            content: PinnedNavigationBackPage(destination: model.selection, chrome: model.chrome)
                .id(model.selection),
            contentDestination: model.selection,
            onRequireHome: { model.requiresHome = true }
        )
        .tvBackButtonGuard()
    }
}

@MainActor @Observable
private final class PinnedNavigationBackModel {
    let profile = Profile(name: "Viewer")
    let chrome = NavigationChromeModel()
    let configuredDestinations: [NavigationRailDestination]
    var selection: NavigationRailDestination
    var requiresHome = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let prefix = "--back-root="
        let root = arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? "home"
        guard let destination = NavigationRailDestination(storageValue: root) else {
            preconditionFailure("Invalid Back fixture destination: \(root)")
        }
        selection = destination
        let destinations: [NavigationRailDestination] = [.home, .watchlist, .search, .liveTV, .music, .settings]
        configuredDestinations = arguments.contains("--back-hidden-home")
            ? destinations.filter { $0 != .home } : destinations
    }
}

private struct PinnedNavigationBackPage: View {
    let destination: NavigationRailDestination
    let chrome: NavigationChromeModel
    @State private var path: [Int] = []
    @State private var showsDialog = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 50) {
                Button("Page \(destination.storageValue)") { path.append(1) }
                    .accessibilityIdentifier("back-page-\(destination.storageValue)")
                    .contextMenu {
                        Button("Context action") {}
                    }
                Button("Open dialog") { showsDialog = true }
                    .accessibilityIdentifier("back-open-dialog")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationDestination(for: Int.self) { depth in
                Button("Detail \(depth)") { path.append(depth + 1) }
                    .accessibilityIdentifier("back-detail-\(depth)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .reportsNavigationDepth(path.count, to: chrome)
        .sheet(isPresented: $showsDialog) {
            Button("Dialog") {}
                .accessibilityIdentifier("back-dialog")
                .onExitCommand { showsDialog = false }
        }
    }
}
