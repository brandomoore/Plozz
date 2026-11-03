#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreNetworking
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
public final class ExternalMediaOpening {
    public var failed = false
    private var generation = UUID()
    private let openURL: @MainActor (URL) async -> Bool

    public init(openURL: @escaping @MainActor (URL) async -> Bool = { url in
        #if os(tvOS)
        await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
        #else
        await UIApplication.shared.open(url)
        #endif
    }) {
        self.openURL = openURL
    }

    public func cancel() {
        generation = UUID()
    }

    public func open(
        _ item: MediaItem, provider: any MediaProvider,
        isAuthorized: @escaping @MainActor () -> Bool = { true }
    ) async {
        let current = UUID()
        generation = current
        failed = false
        guard !Task.isCancelled, isAuthorized() else { return }
        do {
            let link = try await provider.externalMediaLink(
                for: item.id,
                mediaSourceID: item.selectedVersionID ?? item.externalSourceVersion?.playbackMediaSourceID
            )
            guard generation == current, !Task.isCancelled, isAuthorized() else { return }
            if await openURL(link.url) { return }
        } catch {
            guard generation == current, !Task.isCancelled, !(error is CancellationError), isAuthorized() else { return }
        }
        guard generation == current, !Task.isCancelled, isAuthorized() else { return }
        PlozzLog.playback.error("Unable to open the imported external media link.")
        failed = true
    }
}

private struct ExternalMediaOpeningFailure: ViewModifier {
    @Bindable var opener: ExternalMediaOpening

    func body(content: Content) -> some View {
        content
            .alert("Couldn't Open Link", isPresented: $opener.failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check the link file and that the destination app is available on this device.")
            }
            .onDisappear { opener.cancel() }
    }
}

public extension View {
    func externalMediaOpeningFailures(_ opener: ExternalMediaOpening) -> some View {
        modifier(ExternalMediaOpeningFailure(opener: opener))
    }
}
#endif
