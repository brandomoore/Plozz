import CoreModels
import SwiftUI

extension EnvironmentValues {
    @Entry public var openHomeCustomization: (@MainActor () -> Void)? = nil
}

public struct HomeSectionStatusRow: View {
    @Environment(\.openHomeCustomization) private var openHomeCustomization
    private let issue: HomeSectionIssue
    private let onSeeAll: (() -> Void)?
    private let onDismissEmpty: (() -> Void)?
    private let onRetry: () -> Void

    public init(
        issue: HomeSectionIssue, onSeeAll: (() -> Void)? = nil,
        onDismissEmpty: (() -> Void)? = nil, onRetry: @escaping () -> Void
    ) {
        self.issue = issue
        self.onSeeAll = onSeeAll
        self.onDismissEmpty = onDismissEmpty
        self.onRetry = onRetry
    }

    public var body: some View {
        MediaRowSection(
            title: issue.choice.localizedTitle.map(Text.init) ?? Text(verbatim: issue.choice.title),
            insetsContent: true, onSeeAll: onSeeAll
        ) {
            HomeSectionStatusView(
                issue: issue, showsTitle: false,
                onCustomizeHome: openHomeCustomization, onDismissEmpty: onDismissEmpty, onRetry: onRetry
            )
        }
    }
}
