import CoreModels
import SwiftUI

public struct HomeSectionStatusRow: View {
    private let issue: HomeSectionIssue
    private let onSeeAll: (() -> Void)?
    private let onRetry: () -> Void

    public init(issue: HomeSectionIssue, onSeeAll: (() -> Void)? = nil, onRetry: @escaping () -> Void) {
        self.issue = issue
        self.onSeeAll = onSeeAll
        self.onRetry = onRetry
    }

    public var body: some View {
        MediaRowSection(
            title: issue.choice.localizedTitle.map(Text.init) ?? Text(verbatim: issue.choice.title),
            insetsContent: true, onSeeAll: onSeeAll
        ) {
            HomeSectionStatusView(issue: issue, showsTitle: false, onRetry: onRetry)
        }
    }
}
