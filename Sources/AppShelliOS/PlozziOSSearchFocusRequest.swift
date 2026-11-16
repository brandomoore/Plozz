#if os(iOS)
import SwiftUI

/// How the shell asks the Search screen to take focus.
///
/// iOS/iPadOS only: pressing the Search tab must land the viewer in the search
/// field with the keyboard up, whether they arrive from another tab or press Search
/// again while already there. A counter rather than a Bool so **every** press is a
/// distinct request — a Bool would collapse a re-tap into "already true".
///
/// These requests are scoped to the mobile tab shell.
struct PlozziOSSearchFocusRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

/// Increments when the viewer pressed Search while the Search tab was already
/// selected, meaning "start a new search": the previous query is cleared rather
/// than left in place. Arriving from another tab keeps the query (the viewer may
/// be returning to their results) and only focuses the field.
struct PlozziOSSearchReplaceQueryRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

/// Increments when the shell needs the active navigation stack to return to its
/// root when Search is pressed with a detail page pushed over its results.
/// Only the Search stack receives this request; other tabs retain their routes.
struct PlozziOSNavigationRootRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var plozziOSNavigationRootRequest: Int {
        get { self[PlozziOSNavigationRootRequestKey.self] }
        set { self[PlozziOSNavigationRootRequestKey.self] = newValue }
    }

    var plozziOSSearchFocusRequest: Int {
        get { self[PlozziOSSearchFocusRequestKey.self] }
        set { self[PlozziOSSearchFocusRequestKey.self] = newValue }
    }

    var plozziOSSearchReplaceQueryRequest: Int {
        get { self[PlozziOSSearchReplaceQueryRequestKey.self] }
        set { self[PlozziOSSearchReplaceQueryRequestKey.self] = newValue }
    }
}
#endif
