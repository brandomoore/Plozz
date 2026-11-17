#if canImport(UIKit)
import CoreModels
import UIKit

public extension VideoZoomDefaults.Platform {
    @MainActor static var current: Self {
        #if os(tvOS)
        .television
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? .phone : .tablet
        #endif
    }
}
#endif
