import CoreModels
import CoreUI
import SwiftUI
@testable import AppShelliOS

@MainActor
struct ProfilePickerInteractionFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var selectedName: String?
    private let profiles: [Profile]
    private let arguments = ProcessInfo.processInfo.arguments

    init() {
        let sync = SyncSetupFeatureFlag()
        sync.isEnabled = false
        let model = PlozziOSAppModel()
        let names = ["Alex", "Sam", "Jamie"]
        profiles = names.enumerated().map { index, name in
            if let existing = model.profiles.profiles.first(where: { $0.name == name }) {
                return existing
            }
            return model.profiles.add(
                name: name, avatarSymbol: ["person.fill", "star.fill", "moon.fill"][index],
                colorIndex: index
            )
        }
        _appModel = State(initialValue: model)
    }

    var body: some View {
        Group {
            if let selectedName {
                VStack {
                    Text(selectedName).accessibilityIdentifier("fixture-profile-result")
                    Button("Open picker") { self.selectedName = nil }
                }
            } else {
                PlozziOSProfilePickerView(
                    profiles: profiles, activeProfileID: profiles[0].id,
                    onSelect: { selectedName = $0.name },
                    manager: arguments.contains("--restricted-picker") ? nil : appModel,
                    onCancel: arguments.contains("--launch-picker") ? nil : { selectedName = "Cancelled" }
                )
            }
        }
        .environment(appModel)
        .environment(\.themePalette, .dark)
        .environment(\.gradientBackgroundsEnabled, true)
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(.dark)
    }
}
