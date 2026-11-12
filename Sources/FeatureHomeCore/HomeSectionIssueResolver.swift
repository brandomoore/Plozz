import CoreModels

enum HomeSectionIssueResolver {
    static func resolve(
        content: HomeViewModel.Content, failures: [HomeRowKind: AppError],
        visibility: HomeLibraryVisibility, accounts: [ResolvedAccount]
    ) -> [HomeSectionIssue] {
        guard !accounts.isEmpty else { return [] }
        let recommendations = Dictionary(
            content.librarySections.map { ($0.library.key, $0.sections) },
            uniquingKeysWith: { first, _ in first }
        )
        var choices = HomeSectionCatalog(
            libraries: content.libraries,
            serverRows: visibility.rowCustomization?.availableServerRows ?? [],
            recommendations: recommendations
        ).availableChoices(in: visibility)
        var known = Set(choices.map(\.id))
        let saved = (visibility.rowCustomization?.order ?? [])
            + (visibility.rowCustomization?.shown ?? []).sorted { $0.presentationID < $1.presentationID }
        for id in saved where known.insert(id).inserted {
            guard let key = id.libraryKey, visibility.isEnabled(key),
                  accounts.contains(where: { key.hasPrefix($0.account.id + ":") }) else { continue }
            let kind = id.libraryKind ?? .hubs
            choices.append(HomeRowChoice(
                id: id, title: kind.rawValue, localizedTitle: kind.displayName,
                library: content.libraries.first { $0.key == key }, isProviderDefault: false
            ))
        }
        return choices.compactMap { choice -> HomeSectionIssue? in
            guard visibility.isHomeRowVisible(choice), !visibility.isMergedHomeRow(choice) else { return nil }
            let explicitlyShown = visibility.rowCustomization?.shown.contains(choice.id) == true
            let reason: HomeSectionIssue.Reason?
            var accountID = choice.library?.accountID ?? choice.serverRow?.accountID
            switch choice.id {
            case let .global(kind):
                let rowKind = HomeRowKind(rawValue: kind.rawValue)
                reason = rowKind.flatMap { failures[$0] }.flatMap(failure)
            case .libraries:
                reason = failures[.libraries].flatMap(failure)
            case .liveTV:
                return nil
            case let .server(id, _):
                accountID = id
                guard accounts.contains(where: { $0.account.id == id }) else { return nil }
                if let row = content.serverRows.first(where: { $0.definition.id == choice.id }) {
                    reason = row.failure.flatMap(failure)
                        ?? (row.failure == nil && !row.isLoading && row.items.isEmpty ? .empty : nil)
                } else {
                    reason = .notReturned
                }
            case let .section(id):
                guard let definition = choice.collectionSection,
                      !definition.availableSources(accounts: accounts, visibility: visibility).isEmpty else { return nil }
                accountID = definition.sources.count == 1 ? definition.sources.first?.accountID : nil
                if let row = content.collectionRows.first(where: { $0.definition.id == id }) {
                    reason = row.failure.flatMap(failure)
                        ?? (row.failure == nil && !row.isLoading && row.items.isEmpty ? .empty : nil)
                } else {
                    reason = .sourceUnavailable
                }
            case let .library(key, section):
                accountID = choice.library?.accountID
                    ?? accounts.first(where: { key.hasPrefix($0.account.id + ":") })?.account.id
                guard accountID != nil else { return nil }
                if let group = content.librarySections.first(where: { $0.library.key == key }) {
                    let kind = choice.id.libraryKind ?? .hubs
                    if let error = group.failures[kind] {
                        reason = failure(error)
                    } else if group.loadingRows.contains(kind) {
                        reason = nil
                    } else if let row = group.sections.first(where: { $0.id == section }) {
                        reason = row.items.isEmpty && explicitlyShown ? .empty : nil
                    } else {
                        reason = explicitlyShown ? (kind == .hubs ? .notReturned : .empty) : nil
                    }
                } else if content.libraries.contains(where: { $0.key == key }) {
                    reason = explicitlyShown ? (choice.id.libraryKind == .hubs ? .notReturned : .empty) : nil
                } else {
                    reason = explicitlyShown ? .sourceUnavailable : nil
                }
            }
            guard let reason else { return nil }
            let account = accounts.first { $0.account.id == accountID }
            return HomeSectionIssue(
                choice: choice, reason: reason, serverName: account?.account.server.name,
                providerKind: account?.provider.kind
            )
        }
    }

    private static func failure(_ error: AppError) -> HomeSectionIssue.Reason? {
        error == .cancelled ? nil : .failed(error)
    }
}
