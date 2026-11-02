import CoreModels
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
                if let progress = status.progress {
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction) {
                            Text(progress.title)
                        } currentValueLabel: {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                        }
                    } else {
                        ProgressView { Text(progress.title) }
                    }
                    if let detail = progress.detail { Text(detail).font(.caption).monospacedDigit() }
                } else {
                    if status.isRefresh { ProgressView("Refreshing guide") }
                    else { ProgressView("Adding guide") }
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

private extension ServerLiveTVGuideProgress {
    var title: LocalizedStringResource {
        switch stage {
        case .downloading: "Downloading guide"
        case .readingGuide: "Reading guide"
        case .preparingListings: "Preparing listings"
        case .saving: "Saving guide"
        case .matching: "Checking channels"
        }
    }

    var detail: LocalizedStringResource? {
        switch stage {
        case .downloading:
            let received = Int64(completed).formatted(.byteCount(style: .file))
            if let total {
                let expected = Int64(total).formatted(.byteCount(style: .file))
                return "\(received) of \(expected)"
            }
            return "\(received) downloaded"
        case .readingGuide:
            return completed == 0 ? nil : "\(completed) listings scanned"
        case .preparingListings:
            if let total { return "\(completed) of \(total) listings" }
            return "\(completed) listings processed"
        case .matching:
            if let total { return "\(completed) of \(total) channels" }
            return nil
        case .saving: return nil
        }
    }
}
