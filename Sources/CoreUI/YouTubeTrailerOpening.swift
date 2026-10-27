#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreNetworking
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
public final class YouTubeTrailerOpening {
    public var failed = false
    private let openURL: @MainActor (URL) async -> Bool

    public init(
        openURL: @escaping @MainActor (URL) async -> Bool = {
            await UIApplication.shared.open($0)
        }
    ) {
        self.openURL = openURL
    }

    public func open(_ item: MediaItem) async {
        guard !Task.isCancelled else { return }
        failed = false
        guard let appURL = item.youTubeTrailerAppURL,
              let watchURL = item.youTubeTrailerWatchURL else {
            reportFailure()
            return
        }
        if await openURL(appURL) { return }
        guard !Task.isCancelled else { return }
        #if !os(tvOS)
        if await openURL(watchURL) { return }
        guard !Task.isCancelled else { return }
        #endif
        reportFailure()
    }

    private func reportFailure() {
        PlozzLog.playback.error("Unable to open the external YouTube trailer.")
        failed = true
    }
}

private struct YouTubeTrailerOpeningFailure: ViewModifier {
    @Bindable var opener: YouTubeTrailerOpening

    func body(content: Content) -> some View {
        content.alert(
            Text(LocalizedStringResource("Couldn't open YouTube", comment: "Title when an external trailer link cannot be opened.")),
            isPresented: $opener.failed
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringResource("YouTube couldn't be opened on this device.", comment: "External trailer handoff failed. No built-in playback or QR fallback is offered."))
        }
    }
}

public extension View {
    func youTubeTrailerOpeningFailures(_ opener: YouTubeTrailerOpening) -> some View {
        modifier(YouTubeTrailerOpeningFailure(opener: opener))
    }
}
#endif
