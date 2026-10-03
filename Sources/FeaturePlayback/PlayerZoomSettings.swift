#if os(iOS)
import SwiftUI
import UIKit

@MainActor
public enum PlayerZoomMenu {
    public static func make(
        model: PlayerVideoZoomModel, locale: Locale,
        onCustomZoom: @escaping () -> Void
    ) -> UIMenu {
        let selection = model.settings.mode
        let choices = PlayerVideoZoom.Mode.allCases.map { mode in
            var title = mode.menuTitle
            title.locale = locale
            return UIAction(
                title: String(localized: title), // l10n:content - UIKit menu boundary.
                state: selection == mode ? .on : .off
            ) { _ in
                model.settings.mode = mode
                if mode == .custom { onCustomZoom() }
            }
        }
        return UIMenu(
            title: String(localized: "Zoom Mode", locale: locale), // l10n:content - UIKit menu boundary.
            image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"),
            options: .singleSelection, children: choices
        )
    }
}

struct PlayerZoomSettingsRows: View {
    @Bindable var model: PlayerVideoZoomModel

    var body: some View {
        Picker("Zoom Mode", selection: $model.settings.mode) {
            ForEach(PlayerVideoZoom.Mode.allCases, id: \.self) { mode in
                Text(mode.menuTitle).tag(mode)
            }
        }
        if model.settings.mode == .custom {
            Stepper(value: Binding(
                get: { model.settings.customPercent },
                set: { model.setCustomPercent($0) }
            ), in: PlayerVideoZoom.customPercentRange) {
                LabeledContent("Zoom Amount") {
                    Text(Double(model.settings.customPercent) / 100, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
        }
    }
}

public struct PlayerZoomSettingsSheet: View {
    let model: PlayerVideoZoomModel
    @Environment(\.dismiss) private var dismiss

    public init(model: PlayerVideoZoomModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            Form {
                PlayerZoomSettingsRows(model: model)
                Button("Reset to Normal") { model.settings = PlayerVideoZoom() }
            }
            .navigationTitle("Zoom Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
