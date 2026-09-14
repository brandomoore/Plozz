import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
@testable import AppShell

struct NavigationDestinationHandoffFixture: View {
    @State private var model = NavigationDestinationHandoffFixtureModel()

    var body: some View {
        NavigationRailShell(
            profile: model.profile,
            entries: [],
            destinations: [.home, .music, .settings],
            selection: Binding(
                get: { model.requested },
                set: { model.select($0) }
            ),
            onOpenProfileSwitcher: {},
            chrome: model.chrome,
            content: NavigationHandoffFixturePage(model: model),
            contentDestination: model.presented
        )
        .task(id: model.requested) {
            await model.finishLoading()
        }
        .onPlayPauseCommand { model.releaseHeldPage() }
    }
}

@MainActor
@Observable
private final class NavigationDestinationHandoffFixtureModel {
    let profile = Profile(name: "Viewer")
    let chrome = NavigationChromeModel()
    var requested = NavigationRailDestination.home
    var presented = NavigationRailDestination.home
    var prematureFocusCount = 0
    private let holdsPages = ProcessInfo.processInfo.arguments.contains("--manual-navigation-handoff")

    func select(_ destination: NavigationRailDestination) {
        prematureFocusCount = 0
        requested = destination
    }

    func focused(_ destination: NavigationRailDestination) {
        if destination != requested { prematureFocusCount += 1 }
    }

    func finishLoading() async {
        let destination = requested
        guard destination != presented, !holdsPages else { return }
        do { try await Task.sleep(for: .milliseconds(750)) }
        catch is CancellationError { return }
        catch {
            assertionFailure("Fixture loading failed: \(error)")
            return
        }
        guard !Task.isCancelled, requested == destination else { return }
        presented = destination
    }

    func releaseHeldPage() {
        if holdsPages { presented = requested }
    }
}

private struct NavigationHandoffFixturePage: View {
    let model: NavigationDestinationHandoffFixtureModel

    var body: some View {
        VStack(spacing: 40) {
            NavigationHandoffFixtureButton(destination: model.presented, onFocus: model.focused)
                .frame(width: 500, height: 90)
                .id(model.presented)
            Text("Ready \(model.presented.storageValue)")
            Text("\(model.prematureFocusCount)")
                .accessibilityIdentifier("handoff-premature-focus")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

private struct NavigationHandoffFixtureButton: UIViewRepresentable {
    let destination: NavigationRailDestination
    let onFocus: (NavigationRailDestination) -> Void

    func makeUIView(context: Context) -> Button {
        let button = Button(type: .system)
        button.setTitle("Page \(destination.storageValue)", for: .normal)
        button.accessibilityIdentifier = "handoff-page-\(destination.storageValue)"
        return button
    }

    func updateUIView(_ button: Button, context: Context) {
        button.isEnabled = context.environment.isEnabled
        button.onFocus = { onFocus(destination) }
    }

    final class Button: UIButton {
        var onFocus: (() -> Void)?

        override func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            super.didUpdateFocus(in: context, with: coordinator)
            if context.nextFocusedView === self { onFocus?() }
        }
    }
}
