#if canImport(SwiftUI)
import SwiftUI

@MainActor
@Observable
public final class SubtitleControlsLayout {
    public var frame: CGRect?
    public init() {}
}

public extension View {
    /// Measure the visible control content before any full-player frame or spacer.
    func reportSubtitleControlsFrame(
        isVisible: Bool = true,
        onChange: @escaping @MainActor (CGRect?) -> Void
    ) -> some View {
        modifier(SubtitleControlsFrameReader(isVisible: isVisible, onChange: onChange))
    }
}

private struct SubtitleControlsFrameReader: ViewModifier {
    let isVisible: Bool
    let onChange: @MainActor (CGRect?) -> Void
    @State private var frame: CGRect = .null

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                frame = $0
                onChange(isVisible ? $0 : nil)
            }
            .onChange(of: isVisible) { _, visible in
                onChange(visible && !frame.isNull ? frame : nil)
            }
            .onDisappear { onChange(nil) }
    }
}
#endif
