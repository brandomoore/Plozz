#if canImport(SwiftUI)
import SwiftUI

extension EnvironmentValues {
    @Entry public var openWatchlist: (@MainActor () -> Void)? = nil
}
#endif
