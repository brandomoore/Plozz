import CoreModels
import CoreUI
import SwiftUI

extension View {
    func playbackPresentation<Player: View>(
        playRequest: Binding<PlayRequest?>,
        resumePrompt: Binding<MediaItem?>,
        onResume: @escaping (MediaItem, TimeInterval) -> Void,
        @ViewBuilder player: @escaping (PlayRequest) -> Player
    ) -> some View {
        modifier(PlaybackPresentationHost(
            playRequest: playRequest, resumePrompt: resumePrompt,
            onResume: onResume, player: player
        ))
    }
}

private struct PlaybackPresentationHost<Player: View>: ViewModifier {
    @Binding var playRequest: PlayRequest?
    @Binding var resumePrompt: MediaItem?
    let onResume: (MediaItem, TimeInterval) -> Void
    let player: (PlayRequest) -> Player
    @State private var presentedRequest: PlayRequest?
    // Retained until UIKit's dismissal completes, including interactive dismissal.
    @State private var presentedTraceID: UUID?

    private struct Intent: Equatable {
        let traceID: UUID?
        let resumeItem: MediaItem?
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $presentedRequest, onDismiss: didDismiss) { request in
                player(request).id(request.traceID)
            }
            .resumePrompt(item: Binding(
                get: { presentedTraceID == nil ? resumePrompt : nil },
                set: { resumePrompt = $0 }
            ), onChoose: onResume)
            .onChange(of: Intent(traceID: playRequest?.traceID, resumeItem: resumePrompt), initial: true) {
                reconcile()
            }
    }

    private func reconcile() {
        if let presentedTraceID {
            if playRequest?.traceID != presentedTraceID || resumePrompt != nil {
                presentedRequest = nil
            }
            return
        }
        guard resumePrompt == nil, let playRequest else { return }
        presentedTraceID = playRequest.traceID
        presentedRequest = playRequest
    }

    private func didDismiss() {
        // A dismissed cover owns only its request, never a newer queued link.
        if playRequest?.traceID == presentedTraceID { playRequest = nil }
        presentedTraceID = nil
        reconcile()
    }
}
