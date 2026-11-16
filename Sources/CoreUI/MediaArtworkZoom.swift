#if os(iOS)
import CoreModels
import SwiftUI

public struct MediaArtworkZoomSource: Hashable {
    let id: String
    let namespace: Namespace.ID
}

public struct MediaArtworkZoomRoute<Value: Hashable>: Hashable {
    public let value: Value
    public let source: MediaArtworkZoomSource

    public init(value: Value, source: MediaArtworkZoomSource) {
        self.value = value
        self.source = source
    }
}

public struct MediaArtworkZoomValueLink<Value: Hashable, Label: View>: View {
    private let id: String
    private let value: Value
    private let label: () -> Label
    @Namespace private var namespace

    public init(id: String, value: Value, @ViewBuilder label: @escaping () -> Label) {
        self.id = id
        self.value = value
        self.label = label
    }

    public var body: some View {
        let source = MediaArtworkZoomSource(id: id, namespace: namespace)
        NavigationLink(value: MediaArtworkZoomRoute(value: value, source: source)) {
            label().environment(\.mediaArtworkZoomSource, source)
        }
    }
}

/// Each rendered card owns its namespace, even when another row shows the same item.
public struct MediaArtworkZoomLink<Destination: View, Label: View>: View {
    private let id: String
    /// Whether the destination shares the source card's aspect closely enough for
    /// the zoom morph. A portrait poster growing into a full-bleed landscape hero
    /// stretches the picture and is the visible "hero freaks out on entry"; those
    /// links use the normal push instead.
    private let usesZoom: Bool
    private let destination: () -> Destination
    private let label: () -> Label
    @Namespace private var namespace

    public init(
        id: String,
        usesZoom: Bool = false,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.id = id
        self.usesZoom = usesZoom
        self.destination = destination
        self.label = label
    }

    @State private var isPresented = false

    public var body: some View {
        let source = MediaArtworkZoomSource(id: id, namespace: namespace)
        // A NavigationLink keeps its highlighted/presented state on the source card
        // after a pop in some stacks, leaving that one card inert until another link
        // is activated. An explicit presentation binding resets on dismissal.
        Button {
            isPresented = true
        } label: {
            label().environment(\.mediaArtworkZoomSource, source)
        }
        .navigationDestination(isPresented: $isPresented) {
            if usesZoom {
                destination().mediaArtworkZoomDestination(source)
            } else {
                destination()
            }
        }
    }
}

public struct MediaArtworkZoomButton<Label: View>: View {
    private let id: String
    private let action: (MediaArtworkZoomSource) -> Void
    private let label: () -> Label
    @Namespace private var namespace

    public init(
        id: String,
        action: @escaping (MediaArtworkZoomSource) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.id = id
        self.action = action
        self.label = label
    }

    public var body: some View {
        let source = MediaArtworkZoomSource(id: id, namespace: namespace)
        Button { action(source) } label: {
            label().environment(\.mediaArtworkZoomSource, source)
        }
    }
}

private struct MediaArtworkZoomSourceKey: EnvironmentKey {
    static let defaultValue: MediaArtworkZoomSource? = nil
}

private struct MediaItemArtworkNavigatorKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MediaItem, MediaArtworkZoomSource) -> Void)? = nil
}

public extension EnvironmentValues {
    var mediaItemArtworkNavigator: (@MainActor (MediaItem, MediaArtworkZoomSource) -> Void)? {
        get { self[MediaItemArtworkNavigatorKey.self] }
        set { self[MediaItemArtworkNavigatorKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var mediaArtworkZoomSource: MediaArtworkZoomSource? {
        get { self[MediaArtworkZoomSourceKey.self] }
        set { self[MediaArtworkZoomSourceKey.self] = newValue }
    }
}

public extension View {
    /// Gives menu-only artwork an origin, or preserves its enclosing link's origin.
    func mediaArtworkZoomOrigin(id: String) -> some View {
        modifier(MediaArtworkZoomOrigin(id: id))
    }

    func mediaArtworkZoomDestination(_ source: MediaArtworkZoomSource) -> some View {
        navigationTransition(.zoom(sourceID: source.id, in: source.namespace))
            .environment(\.mediaArtworkZoomSource, nil)
    }

    func mediaArtworkZoomSource(cornerRadius: CGFloat) -> some View {
        modifier(MediaArtworkZoomAnchor(cornerRadius: cornerRadius))
    }

    func mediaItemArtworkNavigator(
        _ action: @escaping @MainActor (MediaItem, MediaArtworkZoomSource) -> Void
    ) -> some View {
        environment(\.mediaItemArtworkNavigator, action)
    }
}

private struct MediaArtworkZoomOrigin: ViewModifier {
    let id: String
    @Environment(\.mediaArtworkZoomSource) private var inheritedSource
    @Namespace private var namespace

    func body(content: Content) -> some View {
        content.environment(
            \.mediaArtworkZoomSource,
            inheritedSource ?? MediaArtworkZoomSource(id: id, namespace: namespace)
        )
    }
}

private struct MediaArtworkZoomAnchor: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.mediaArtworkZoomSource) private var source
    @Namespace private var unmatchedNamespace

    func body(content: Content) -> some View {
        // An unlinked artwork stays inert without changing its structural identity.
        // Register the final artwork bounds, never a guessed size or the caption.
        content.matchedTransitionSource(
            id: source?.id ?? "", in: source?.namespace ?? unmatchedNamespace
        ) { configuration in
            configuration.clipShape(.rect(cornerRadius: cornerRadius))
        }
    }
}
#endif
