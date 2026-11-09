import AVFoundation
@testable import AppShelliOS
import CoreModels
import FeatureMusic
import SwiftUI

struct MusicPlayerFixture: View {
    @State private var player = MusicPlayerSession()
    @State private var failure: String?
    @State private var hasBottomBar = false

    private var appearance: MusicPlayerAppearance {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--music-light") { return .light }
        if arguments.contains("--music-oled") { return .pureBlack }
        return .matchTheme
    }

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section("Evening Light") {
                        Button("Play") { player.controller.resume(); player.isPresented = true }
                        Button("Next track") { player.controller.next() }
                        Button("Previous track") { player.controller.previous() }
                    }
                    if let failure { Text(failure) }
                }
                .navigationTitle("Music")
            }
            .tabItem { Label("Music", systemImage: "music.note") }
            Text("Library").tabItem { Label("Library", systemImage: "square.stack") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background {
            PlozziOSSettingsTabAction(
                tabIndex: nil, action: {},
                onBottomBarVisibilityChange: { hasBottomBar = $0 },
                reservesMusicDockSpace: player.controller.hasActivePlayback
            )
            .frame(width: 0, height: 0)
        }
        .overlay {
            MusicPlayerOverlay(session: player, hasBottomBar: hasBottomBar, appearance: appearance)
        }
        .task {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("music-fixture.caf")
            defer {
                player.stop()
                try? FileManager.default.removeItem(at: file)
            }
            do {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_646_000),
                      let samples = buffer.floatChannelData else {
                    throw AppError.unknown("Could not create fixture audio.")
                }
                buffer.frameLength = buffer.frameCapacity
                samples[0].initialize(repeating: 0, count: Int(buffer.frameLength))
                do {
                    let audio = try AVAudioFile(forWriting: file, settings: format.settings)
                    try audio.write(from: buffer)
                }
                player.controller.play(
                    tracks: [
                        MusicTrack(id: "one", title: "The First Song", albumTitle: "Evening Light", albumID: "album", artistName: "Test Artist", artistID: "artist", duration: 60, sourceAccountID: "fixture"),
                        MusicTrack(id: "two", title: "Another Song", albumTitle: "Evening Light", albumID: "album", artistName: "Test Artist", artistID: "artist", duration: 60, sourceAccountID: "fixture")
                    ],
                    startIndex: 0,
                    resolveStreamURL: { _ in .init(url: file) }
                )
                if ProcessInfo.processInfo.arguments.contains("--music-expanded") {
                    player.isPresented = true
                }
                try await Task.sleep(for: .seconds(300))
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
