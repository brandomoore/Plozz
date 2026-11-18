import CoreModels
import SwiftUI

private struct PlaybackResumePromptAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

public extension View {
    func resumePromptAnchor(id: String = "play") -> some View {
        anchorPreference(key: PlaybackResumePromptAnchorKey.self, value: .bounds) { [id: $0] }
    }

    func resumePrompt(
        item: Binding<MediaItem?>,
        anchorID: String? = "play",
        onChoose: @escaping (MediaItem, TimeInterval) -> Void
    ) -> some View {
        resumePrompt(request: item, mediaItem: { $0 }, anchorID: anchorID, onChoose: onChoose)
    }

    /// Retains the complete request, including its source and playlist, while choosing a start position.
    func resumePrompt<Request>(
        request: Binding<Request?>,
        mediaItem: @escaping (Request) -> MediaItem,
        anchorID: String? = "play",
        onChoose: @escaping (Request, TimeInterval) -> Void
    ) -> some View {
        #if os(iOS)
        overlayPreferenceValue(PlaybackResumePromptAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let anchor = anchorID.flatMap { anchors[$0] }
                let bounds = anchor.map { proxy[$0] } ?? CGRect(origin: .zero, size: proxy.size)
                Color.clear
                    .frame(width: bounds.width, height: bounds.height)
                    .allowsHitTesting(false)
                    .resumePromptDialog(request: request, mediaItem: mediaItem, onChoose: onChoose)
                    .position(x: bounds.midX, y: bounds.midY)
            }
        }
        #else
        resumePromptDialog(request: request, mediaItem: mediaItem, onChoose: onChoose)
        #endif
    }

    private func resumePromptDialog<Request>(
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
