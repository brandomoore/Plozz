#if canImport(SwiftUI)
import SwiftUI

@MainActor
@Observable
public final class SubtitleControlsLayout {
    public enum Region: Hashable, Sendable {
        case transport, title, trackControls, timeline, card, menu
        case tab(String)
    }
    private struct Entry: Hashable {
        let region: Region
        let owner: UUID?
    }
    private var regions: [Entry: CGRect] = [:]
    public var frames: [CGRect] { Array(regions.values) }
    /// Convenience for a single transport surface and aggregate inspection.
    /// Collision layout uses `frames`, not this bounding rectangle.
    public var frame: CGRect? {
        get {
            let bounds = frames.reduce(CGRect.null) { $0.union($1) }
            return bounds.isNull ? nil : bounds
        }
        set { setFrame(newValue, for: .transport) }
    }
    public init() {}

    public func frame(for region: Region) -> CGRect? {
        let bounds = regions.filter { $0.key.region == region }.values.reduce(CGRect.null) { $0.union($1) }
        return bounds.isNull ? nil : bounds
    }

    public func setFrame(_ frame: CGRect?, for region: Region, owner: UUID? = nil) {
        let entry = Entry(region: region, owner: owner)
        guard let frame, !frame.isNull, !frame.isEmpty,
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else {
            if regions[entry] != nil { regions.removeValue(forKey: entry) }
            return
        }
        if regions[entry] != frame { regions[entry] = frame }
    }
}

public extension View {
    func reportSubtitleControlsFrame(
        in layout: SubtitleControlsLayout, region: SubtitleControlsLayout.Region, isVisible: Bool = true
    ) -> some View {
        modifier(SubtitleControlsRegionReader(layout: layout, region: region, isVisible: isVisible))
    }

    /// Measure the visible control content before any full-player frame or spacer.
    func reportSubtitleControlsFrame(
        isVisible: Bool = true,
        onChange: @escaping @MainActor (CGRect?) -> Void
    ) -> some View {
        modifier(SubtitleControlsFrameReader(isVisible: isVisible, onChange: onChange))
    }
}

private struct SubtitleControlsRegionReader: ViewModifier {
    let layout: SubtitleControlsLayout
    let region: SubtitleControlsLayout.Region
    let isVisible: Bool
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.reportSubtitleControlsFrame(isVisible: isVisible) {
            layout.setFrame($0, for: region, owner: owner)
        }
    }
}

private struct SubtitleControlsFrameReader: ViewModifier {
    let isVisible: Bool
    let onChange: @MainActor (CGRect?) -> Void
    @State private var frame: CGRect = .null
    @State private var mounted = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                frame = $0
                if mounted { onChange(isVisible ? $0 : nil) }
            }
            .onAppear {
                mounted = true
                onChange(isVisible && !frame.isNull ? frame : nil)
            }
            .onChange(of: isVisible) { _, visible in
                onChange(mounted && visible && !frame.isNull ? frame : nil)
            }
            .onDisappear {
                mounted = false
                onChange(nil)
            }
    }
}
#endif
