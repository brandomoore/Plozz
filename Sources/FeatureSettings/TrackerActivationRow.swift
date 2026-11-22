#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct TrackerActivationRow: View {
    private let tracker: any TrackerActivationControlling
    private let trackerID: String
    private let fallbackTargets: [String]
    @State private var changeFailed = false

    public init(tracker: any TrackerActivationControlling, trackerID: String, fallbackTargets: [String] = []) {
        self.tracker = tracker
        self.trackerID = trackerID
        self.fallbackTargets = fallbackTargets
    }

    public var body: some View {
        Toggle("Enable tracker", isOn: Binding(
            get: { tracker.trackerEnabled },
            set: { enabled in
                do { try tracker.setTrackerEnabled(enabled) }
                catch { changeFailed = true }
            }
        ))
        .accessibilityIdentifier("\(trackerID).enabled")
        .settingsSearchAnchor("tracker-enabled-\(trackerID)", fallbackFor: fallbackTargets)
        .alert("Couldn’t change the tracker setting. Try again.", isPresented: $changeFailed) {}
    }
}
#endif
