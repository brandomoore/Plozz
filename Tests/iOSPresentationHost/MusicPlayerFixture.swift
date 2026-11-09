import AVFoundation
import CoreModels
import FeatureMusic
import SwiftUI

struct MusicPlayerFixture: View {
    @State private var player = MusicPlayerSession()
    @State private var failure: String?

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
                .safeAreaPadding(.bottom, 64)
            }
            .tabItem { Label("Music", systemImage: "music.note") }
            Text("Library").tabItem { Label("Library", systemImage: "square.stack") }
        }
        .overlay {
            MusicPlayerOverlay(session: player, hasBottomBar: true)
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
                        MusicTrack(id: "one", title: "The First Song", albumTitle: "Evening Light", artistName: "Test Artist", duration: 60),
                        MusicTrack(id: "two", title: "Another Song", albumTitle: "Evening Light", artistName: "Test Artist", duration: 60)
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
