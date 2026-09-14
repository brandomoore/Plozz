import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit

struct NativeSidebarHandoffFixture: View {
    @State private var model = NativeSidebarHandoffModel()

    var body: some View {
        TabView(selection: $model.selection) {
            Tab("Home", systemImage: "house", value: NavigationRailDestination.home) {
                NativeSidebarHandoffPage(destination: .home, model: model)
                    .tvNavigationExitProtectionContent()
            }
            Tab("Settings", systemImage: "gearshape", value: NavigationRailDestination.settings) {
                NativeSidebarHandoffPage(destination: .settings, model: model)
                    .tvNavigationExitProtectionContent()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tvNavigationExitProtection(isEnabled: true)
        .onPlayPauseCommand {
            model.expected = model.selection == .home ? .settings : .home
            model.prematureFocusCount = 0
        }
    }
}

@MainActor
@Observable
private final class NativeSidebarHandoffModel {
    var selection = NavigationRailDestination.home
    var expected: NavigationRailDestination?
    var prematureFocusCount = 0

    func focused(_ destination: NavigationRailDestination) {
        if let expected, destination != expected { prematureFocusCount += 1 }
    }
}

private struct NativeSidebarHandoffPage: View {
    let destination: NavigationRailDestination
    let model: NativeSidebarHandoffModel

    var body: some View {
        VStack(spacing: 40) {
            NativeSidebarHandoffButton(destination: destination, onFocus: model.focused)
                .frame(width: 500, height: 100)
            Text("\(model.prematureFocusCount)")
                .accessibilityIdentifier("native-premature-focus-\(destination.storageValue)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(destination == .home ? Color.black : Color.blue.opacity(0.2))
    }
}

private struct NativeSidebarHandoffButton: UIViewRepresentable {
    let destination: NavigationRailDestination
    let onFocus: (NavigationRailDestination) -> Void

    func makeUIView(context: Context) -> Button {
        let button = Button(type: .system)
        button.setTitle("Page \(destination.storageValue)", for: .normal)
        button.accessibilityIdentifier = "native-page-\(destination.storageValue)"
        return button
    }

    func updateUIView(_ button: Button, context: Context) {
        button.isEnabled = context.environment.isEnabled
        button.onFocus = { onFocus(destination) }
    }

    final class Button: UIButton {
        var onFocus: (() -> Void)?

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            if context.nextFocusedView === self { onFocus?() }
        }
    }
}
