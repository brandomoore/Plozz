import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI
@testable import FeatureLiveTV

struct GuideNavigationFixture: View {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    @State private var model = makeModel()
    @State private var imports = LiveTVPrototypeImportModel()
    @State private var selectedID: String? = "channel-0"
    @State private var selectedRow: LiveTVGuideRowID? = .init(channelID: "channel-0")
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var hasFocus = false
    @State private var railActive = false
    @State private var restoring = true
    @State private var guideOffset: TimeInterval = 0
    @State private var timeAnchor = Self.now
    @State private var timelineOffset: CGFloat = 0
    @State private var nowRequest = 0

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Now") { nowRequest += 1 }
                    .accessibilityIdentifier("guide-now")
                Spacer()
                Text(focusedProgram?.title ?? selectedID ?? "No focus")
                    .accessibilityIdentifier("guide-focus-probe")
            }
            .focusSection()
            PrototypeBrowser(
                model: model, imports: imports,
                selectedID: $selectedID, selectedRowID: $selectedRow,
                railActive: $railActive, focusedProgram: $focusedProgram, hasFocus: $hasFocus,
                topRequest: 0, nowRequest: nowRequest,
                guideOffset: $guideOffset, timeAnchor: $timeAnchor, timelineOffset: $timelineOffset,
                restoreFocusRequest: 1, isPresented: true, isRestoringFocus: restoring,
                restoresPlaybackFocus: true, watchOrigin: .init(channelID: "channel-0"),
                focusRestored: { _ in restoring = false },
                tune: { _ in }, details: { _ in }, openControls: {}, openSources: {},
                openGuideTime: {}, openToolbar: {}, isLoading: false, loadFailed: false, reload: {}
            )
        }
        .frame(width: 1_680, height: 840)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
    }

    private static func makeModel() -> LiveTVPrototypeModel {
        let channels = (0..<8).map { index in
            LiveTVPrototypeChannel(
                id: "channel-\(index)", number: index, name: "Channel \(index)", category: "Plozz",
                symbol: "tv", accent: index % 6, source: .plozz, tagline: ""
            )
        }
        let model = LiveTVPrototypeModel(now: now, channels: channels)
        let programs = (0..<7).flatMap { row in
            let currentEnd: TimeInterval = row == 0 || row == 4 ? 7_200 : 600
            let boundaries: [TimeInterval] = [currentEnd, currentEnd + 1_800, currentEnd + 3_600, 21_600]
            return [
                LiveTVPrototypeProgram(
                    id: "current-\(row)", channelID: channels[row].id, title: "Current \(row)", subtitle: "",
                    start: now.addingTimeInterval(-300), end: now.addingTimeInterval(currentEnd)
                )
            ] + (0..<3).map { index in
                LiveTVPrototypeProgram(
                    id: "future-\(row)-\(index)", channelID: channels[row].id,
                    title: "Future \(row).\(index + 1)", subtitle: "",
                    start: now.addingTimeInterval(boundaries[index]),
                    end: now.addingTimeInterval(boundaries[index + 1])
                )
            }
        }
        do { try model.replacePrograms(programs) }
        catch { preconditionFailure("Invalid guide fixture: \(error)") }
        return model
    }
}
