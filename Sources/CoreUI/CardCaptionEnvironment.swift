#if canImport(SwiftUI)
import SwiftUI
import CoreModels

private struct PlozzCardCaptionsHiddenKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct PlozzCardCaptionSettingsKey: EnvironmentKey {
    static let defaultValue = CardCaptionSettings.default
}

private struct PlozzCardCaptionViewKey: EnvironmentKey {
    static let defaultValue = CardCaptionView.browse
}

public extension EnvironmentValues {
    var plozzCardCaptionSettings: CardCaptionSettings {
        get { self[PlozzCardCaptionSettingsKey.self] }
        set { self[PlozzCardCaptionSettingsKey.self] = newValue }
    }

    var plozzCardCaptionView: CardCaptionView {
        get { self[PlozzCardCaptionViewKey.self] }
        set {
            self[PlozzCardCaptionViewKey.self] = newValue
            self[PlozzCardCaptionsHiddenKey.self] = nil
        }
    }

    /// Explicit values are reserved for non-media navigation tiles and fixtures.
    /// Media surfaces resolve their shared default and per-view exception here.
    var plozzCardCaptionsHidden: Bool {
        get {
            self[PlozzCardCaptionsHiddenKey.self]
                ?? !plozzCardCaptionSettings.showsLabels(in: plozzCardCaptionView)
        }
        set { self[PlozzCardCaptionsHiddenKey.self] = newValue }
    }

    /// How much closer a row's title sits to its cards than usual. Set by a
    /// surface that reads one row at a time, where the title belongs tightly to
    /// its row.
    var plozzRowTitleTightening: CGFloat {
        get { self[PlozzRowTitleTighteningKey.self] }
        set { self[PlozzRowTitleTighteningKey.self] = newValue }
    }

    /// Read by the title alone, so a focus change never invalidates the media rail.
    var plozzRowTitleOffset: @MainActor @Sendable () -> CGFloat {
        get { self[PlozzRowTitleOffsetKey.self] }
        set { self[PlozzRowTitleOffsetKey.self] = newValue }
    }
}

public struct PlozzRowTitlePosition: ViewModifier {
    @Environment(\.plozzRowTitleOffset) private var offset

    public init() {}

    public func body(content: Content) -> some View {
        content.offset(y: offset())
    }
}

private struct PlozzRowTitleOffsetKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> CGFloat = { 0 }
}

private struct PlozzRowTitleTighteningKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
#endif
