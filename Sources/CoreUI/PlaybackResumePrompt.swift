import CoreModels
import SwiftUI

public extension View {
    func resumePrompt(
        item: Binding<MediaItem?>,
        onChoose: @escaping (MediaItem, TimeInterval) -> Void
    ) -> some View {
        resumePrompt(request: item, mediaItem: { $0 }, onChoose: onChoose)
    }

    /// Retains the complete request, including its source and playlist, while choosing a start position.
    func resumePrompt<Request>(
        request: Binding<Request?>,
        mediaItem: @escaping (Request) -> MediaItem,
        onChoose: @escaping (Request, TimeInterval) -> Void
    ) -> some View {
        confirmationDialog(
            request.wrappedValue.map { Self.resumePromptTitle(mediaItem($0)) } ?? "",
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { if !$0 { request.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: request.wrappedValue
        ) { presented in
            let item = mediaItem(presented)
            if let remaining = item.resumeRemainingText {
                Button {
                    onChoose(presented, item.resumePosition ?? 0)
                } label: {
                    Text(
                        "Resume · \(remaining) left",
                        comment: """
                            Resume-playback dialog button: continue from the saved \
                            position. The placeholder is a formatted duration (e.g. \
                            "59m") for the time REMAINING, not the elapsed position. \
                            Pairs with "Start Over · %@", which quotes the full runtime.
                            """
                    )
                }
            } else {
                Button("Resume") { onChoose(presented, item.resumePosition ?? 0) }
            }
            if let runtime = item.runtime?.runtimeBadgeText {
                Button {
                    onChoose(presented, 0)
                } label: {
                    Text(
                        "Start Over · \(runtime)",
                        comment: """
                            Resume-playback dialog button: restart from the beginning. \
                            The placeholder is a formatted duration (e.g. "1h 48m") for \
                            the item's FULL runtime. Pairs with "Resume · %@ left".
                            """
                    )
                }
            } else {
                Button("Start Over") { onChoose(presented, 0) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { presented in
            if let context = Self.resumePromptContext(for: mediaItem(presented)) {
                Text(verbatim: context)
            }
        }
    }

    private static func resumePromptTitle(_ item: MediaItem) -> String {
        if item.kind == .episode, let series = item.parentTitle, !series.isEmpty {
            return series
        }
        return item.title
    }

    private static func resumePromptContext(for item: MediaItem) -> String? {
        guard item.kind == .episode else { return nil }
        let parts = [item.subtitle, item.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
