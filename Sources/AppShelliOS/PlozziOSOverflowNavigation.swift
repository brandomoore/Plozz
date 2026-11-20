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
        ToolbarItem(id: "more-navigation-back", placement: .cancellationAction) {
            Button("Back", systemImage: "chevron.backward", action: action)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("more-navigation-back")
        }
    }
}

@MainActor
@Observable
final class PlozziOSOverflowNavigation {
    // Placement belongs to the tab layout, not to the current push or pop.
    private(set) var destinationIndices = IndexSet()
    @ObservationIgnored private(set) var destinationIndex: Int?
    @ObservationIgnored private(set) weak var navigationController: UINavigationController?

    func update(destinationIndices: IndexSet, destinationIndex: Int?, navigationController: UINavigationController) {
        self.navigationController = navigationController
        self.destinationIndex = destinationIndex
        if self.destinationIndices != destinationIndices {
            self.destinationIndices = destinationIndices
        }
    }

    func returnToMore() {
        guard destinationIndex != nil else { return }
        navigationController?.popToRootViewController(animated: true)
    }
}
#endif
