#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public extension EnvironmentValues {
    @Entry var communityPlaybackTimestampSource: (any CommunityPlaybackTimestampProviding)?
}
#endif
