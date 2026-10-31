#if os(iOS)
import Observation
import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var plozziOSIsOverflowDestination = false
    @Entry var plozziOSOverflowNavigation: PlozziOSOverflowNavigation?
}

struct PlozziOSOverflowBackToolbarItem: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(id: "more-navigation-back", placement: .topBarLeading) {
            Button("Back", systemImage: "chevron.backward", action: action)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("more-navigation-back")
        }
    }
}

@MainActor
@Observable
final class PlozziOSOverflowNavigation {
    private(set) var destinationIndex: Int?
    @ObservationIgnored private(set) weak var navigationController: UINavigationController?

    func update(destinationIndex: Int?, navigationController: UINavigationController) {
        self.navigationController = navigationController
        self.destinationIndex = destinationIndex
    }

    func returnToMore() {
        guard destinationIndex != nil else { return }
        navigationController?.popToRootViewController(animated: true)
    }
}
#endif
