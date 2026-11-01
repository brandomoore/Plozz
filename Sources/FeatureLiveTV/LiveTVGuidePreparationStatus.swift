import CoreUI
import FeatureLiveTVCore
import SwiftUI

public struct LiveTVGuidePreparationStatus: View {
    private let status: LiveTVGuidePreparationModel.Status

    public init(status: LiveTVGuidePreparationModel.Status) {
        self.status = status
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch status.phase {
            case .loading:
                if status.isRefresh {
                    ProgressView("Refreshing guide")
                } else {
                    ProgressView("Adding guide")
                }
            case .loaded:
                Label("Guide ready", systemImage: "checkmark.circle")
                Group {
                    if status.channelsWithListings == 1 {
                        Text("1 channel with current listings")
                    } else {
                        Text("\(status.channelsWithListings) channels with current listings")
                    }
                }
                .font(.caption)
            case .empty:
                Label("No current guide listings", systemImage: "calendar.badge.exclamationmark")
            case .notConfigured:
                Label("No guide configured", systemImage: "calendar")
            case .paused:
                Label("Guide update paused", systemImage: "pause.circle")
            case .failed(let failure):
                Label("Guide update failed", systemImage: "exclamationmark.triangle")
                Text(failure.userDescription).font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live-tv-guide-preparation-\(status.id)")
    }
}
