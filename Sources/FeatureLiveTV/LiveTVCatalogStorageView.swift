import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// Create storage before constructing views whose retained importers depend on it.
public struct LiveTVCatalogStorageView<Content: View>: View {
    private let load: @MainActor () throws -> LiveTVIndexedCache
    private let content: (LiveTVIndexedCache) -> Content
    private let loading: AnyView?
    @State private var cache: LiveTVIndexedCache?
    @State private var failed = false
    @State private var retry = 0

    public init(
        load: @escaping @MainActor () throws -> LiveTVIndexedCache,
        loading: AnyView? = nil,
        @ViewBuilder content: @escaping (LiveTVIndexedCache) -> Content
    ) {
        self.load = load
        self.loading = loading
        self.content = content
    }

    public var body: some View {
        Group {
            if let cache {
                content(cache)
            } else if failed {
                ContentUnavailableView {
                    Label("Live TV storage unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Channel and guide storage couldn't be opened.")
                } actions: {
                    Button("Retry", systemImage: "arrow.clockwise") { retry &+= 1 }
                        .plozzActionButton(role: .secondary)
                }
            } else if let loading {
                loading
            } else {
                ProgressView("Opening Live TV...")
            }
        }
        .task(id: retry) {
            guard !Task.isCancelled, cache == nil else { return }
            failed = false
            do {
                cache = try load()
            } catch {
                HandoffDiagnostics.emit("LIVE_TV event=catalogStorageUnavailable")
                failed = true
            }
        }
    }
}
