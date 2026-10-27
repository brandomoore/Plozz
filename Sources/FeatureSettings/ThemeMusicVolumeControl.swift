#if canImport(SwiftUI) && canImport(AVFoundation)
import CoreModels
import CoreUI
import SwiftUI

public struct ThemeMusicVolumeControl: View {
    @Bindable private var model: ThemeMusicSettingsModel
    @Environment(\.themeMusicPreviewController) private var controller
    @Environment(\.themeMusicPreviewResolver) private var resolvePreview
    @Environment(\.themeMusicAuthenticatedHTTPResolver) private var authenticatedHTTPResolver
    @State private var previewRequest: UUID?

    public init(model: ThemeMusicSettingsModel) {
        self.model = model
    }

    private var level: Binding<Double> {
        Binding(
            get: { model.settings.volume.level },
            set: { model.settings.volume = ThemeMusicVolume($0) }
        )
    }

    private var ownsPreview: Bool {
        previewRequest != nil && controller?.previewOwner == previewRequest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(tvOS)
            SettingsStepper(
                options: Array(0...100),
                selection: Binding(
                    get: { Int((level.wrappedValue * 100).rounded()) },
                    set: { level.wrappedValue = Double($0) / 100 }
                ),
                compact: true,
                label: "Theme music volume",
                textTitle: { Text(Double($0) / 100, format: .percent.precision(.fractionLength(0))) }
            )
            .environment(\.settingsAdjustmentRepeatSpeed, .fast)
            .accessibilityIdentifier("theme-music-volume")
            #else
            HStack(spacing: 16) {
                Text("Theme music volume")
                Slider(value: level, in: 0...1, step: 0.01) {
                    Text("Theme music volume")
                } onEditingChanged: { editing in
                    if editing { startPreviewIfNeeded() }
                }
                .accessibilityIdentifier("theme-music-volume")
                Text(level.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            #endif
            Button {
                if ownsPreview, let previewRequest {
                    controller?.stopPreview(owner: previewRequest)
                    self.previewRequest = nil
                } else {
                    previewRequest = UUID()
                }
            } label: {
                if ownsPreview {
                    Label("Stop preview", systemImage: "stop.fill")
                } else {
                    Label("Play preview", systemImage: "play.fill")
                }
            }
            .disabled(controller == nil || controller?.isBlocked == true)
            .accessibilityIdentifier("theme-music-preview")
            if let failure = controller?.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.settings.volume) { _, volume in
            controller?.updateVolume(volume)
            startPreviewIfNeeded()
        }
        .task(id: previewRequest) {
            guard let previewRequest, let controller else { return }
            await controller.preview(
                owner: previewRequest,
                volume: model.settings.volume,
                resolve: resolvePreview,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
            if controller.previewOwner == previewRequest {
                controller.updateVolume(model.settings.volume)
            }
        }
        .onDisappear {
            if let previewRequest { controller?.stopPreview(owner: previewRequest) }
        }
    }

    private func startPreviewIfNeeded() {
        guard !ownsPreview, controller?.isBlocked == false,
              controller?.isAppActive == true else { return }
        previewRequest = UUID()
    }
}
#endif
