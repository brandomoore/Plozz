import CoreModels
import SwiftUI
@testable import AppShell

@MainActor
struct DeepLinkResumeFixture: View {
    @State private var playRequest: PlayRequest?
    @State private var resumePrompt: MediaItem?
    @State private var started = false

    var body: some View {
        Button {
            playFirst()
        } label: {
            Text(verbatim: "Play first")
        }
        .accessibilityIdentifier("deep-link-play-first")
        .playbackPresentation(
            playRequest: $playRequest,
            resumePrompt: $resumePrompt,
            onResume: { item, position in
                resumePrompt = nil
                playRequest = PlayRequest(item: item, startPosition: position)
            }
        ) { request in
            VStack {
                Text(verbatim: "\(request.item.id):\(Int(request.startPosition))")
                    .accessibilityIdentifier("deep-link-playing")
                Button {
                    var item = MediaItem(id: "resumed", title: "Resumed movie", kind: .movie)
                    item.resumePosition = 3
                    playRequest = nil
                    resumePrompt = item
                } label: {
                    Text(verbatim: "Send resumed title")
                }
                .accessibilityIdentifier("deep-link-send-resumed")
            }
        }
        .task {
            guard !started else { return }
            started = true
            playFirst()
        }
    }

    private func playFirst() {
        resumePrompt = nil
        playRequest = PlayRequest(
            item: MediaItem(id: "first", title: "First movie", kind: .movie),
            startPosition: 0
        )
    }
}
