import CoreUI
import FeatureLiveTVCore
import SwiftUI

private struct LiveTVGuidePreparationToast: View {
    let model: LiveTVGuidePreparationModel
    let presenter: TransientStatusPresenter
    let palette: ThemePalette

    var body: some View {
        if presenter.message == nil, let status = model.notificationStatus {
            HStack(spacing: 16) {
                LiveTVGuidePreparationStatus(status: status, tracksInlinePresentation: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                Button {
                    model.dismissNotification(accountID: status.id, requestID: status.requestID)
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("live-tv-guide-toast-dismiss")
            }
            .font(.subheadline)
            .foregroundStyle(palette.primaryText)
            .tint(palette.primaryText)
            .transientStatusSurface(palette: palette)
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("live-tv-guide-toast")
        }
    }
}

public extension View {
    func guidePreparationOverlay(
        model: LiveTVGuidePreparationModel, presenter: TransientStatusPresenter,
        palette: ThemePalette, bottomPadding: CGFloat = 48
    ) -> some View {
        overlay(alignment: .bottom) {
            LiveTVGuidePreparationToast(model: model, presenter: presenter, palette: palette)
                .environment(model)
                .padding(.bottom, bottomPadding)
        }
    }
}
