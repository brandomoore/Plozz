import SwiftUI

public extension HomeRow {
    var displayName: Text {
        customTitle.map { Text(verbatim: $0) } ?? Text(title)
    }
}
