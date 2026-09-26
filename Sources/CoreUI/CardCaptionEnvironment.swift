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
}
#endif
