#if canImport(SwiftUI)
import SwiftUI

private struct PlozzCardCaptionsHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Whether media cards drop the title lines under their artwork. Set by a
    /// surface that already names the focused title elsewhere, such as the Home
    /// hero that follows focus. A resume chip then carries the episode instead.
    var plozzCardCaptionsHidden: Bool {
        get { self[PlozzCardCaptionsHiddenKey.self] }
        set { self[PlozzCardCaptionsHiddenKey.self] = newValue }
    }

    /// How much closer a row's title sits to its cards than usual. Set by a
    /// surface that reads one row at a time, where the title belongs tightly to
    /// its row.
    var plozzRowTitleTightening: CGFloat {
        get { self[PlozzRowTitleTighteningKey.self] }
        set { self[PlozzRowTitleTighteningKey.self] = newValue }
    }
}

private struct PlozzRowTitleTighteningKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
#endif
