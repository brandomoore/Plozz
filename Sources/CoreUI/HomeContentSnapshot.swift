#if canImport(SwiftUI)
import CoreModels
import SwiftUI

private struct HomeContentSnapshotKey: EnvironmentKey {
    static let defaultValue: (any HomeContentSnapshotProviding)? = nil
}

public extension EnvironmentValues {
    var homeContentSnapshot: (any HomeContentSnapshotProviding)? {
        get { self[HomeContentSnapshotKey.self] }
        set { self[HomeContentSnapshotKey.self] = newValue }
    }
}
#endif
