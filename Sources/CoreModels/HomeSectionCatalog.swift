import Foundation

/// Available Home sections adapt existing row feeds; this catalog never owns
/// playback or persisted preferences. The separately configured Hero is pinned.
public struct HomeSectionCatalog: Equatable, Sendable {
    public let choices: [HomeRowChoice]

    public init(
        libraries: [AggregatedLibrary],
        serverRows: [HomeServerRowDefinition] = [],
        recommendations: [String: [LibrarySection]] = [:]
    ) {
        let shared = HomeRowChoice.shared
        let native = serverRows.filter {
            if case .server = $0.id { return true }
            return false
        }.map(HomeRowChoice.init(serverRow:))
        let libraryRows = libraries.filter {
            !$0.library.isMusic && !$0.isRetiredCollectionShortcut
        }.flatMap { library in
            HomeRowChoice.baseRows(for: library) + (recommendations[library.key] ?? []).map {
                HomeRowChoice(section: $0, library: library)
            }
        }
        var seen = Set<HomeRowID>()
        choices = (
            shared.filter { $0.id != .libraries && $0.id != .liveTV }
                + native + libraryRows + shared.filter { $0.id == .libraries || $0.id == .liveTV }
        ).filter { seen.insert($0.id).inserted }
    }

    public func availableChoices(in visibility: HomeLibraryVisibility) -> [HomeRowChoice] {
        let collectionChoices = visibility.collectionSections.map { section in
            HomeRowChoice(
                collectionSection: section,
                library: section.sources.count == 1
                    ? choices.compactMap(\.library).first { $0.key == section.sources.first?.libraryKey } : nil
            )
        }
        return (choices + collectionChoices).filter { choice in
            if let section = choice.collectionSection,
               section.sources.allSatisfy({ $0.libraryKey.map(visibility.isEnabled) == false }) { return false }
            if let key = choice.library?.key, !visibility.isEnabled(key) { return false }
            if let source = choice.serverRow, let libraryID = source.section.libraryID,
               !visibility.isEnabled("\(source.accountID):\(libraryID)") { return false }
            return true
        }
    }

    public func editableChoices(in visibility: HomeLibraryVisibility) -> [HomeRowChoice] {
        availableChoices(in: visibility).filter { !visibility.isMergedHomeRow($0) }
    }

    public func sections(in visibility: HomeLibraryVisibility) -> OrderedVisibilityList.Sections<HomeRowID> {
        visibility.rowSections(choices: editableChoices(in: visibility))
    }

    public func settingVisible(
        _ visible: Bool, id: HomeRowID, in visibility: HomeLibraryVisibility
    ) throws -> HomeLibraryVisibility {
        guard editableChoices(in: visibility).contains(where: { $0.id == id }) else {
            throw AppError.notFound
        }
        var sections = sections(in: visibility)
        guard sections.enabled.contains(id) != visible else { return visibility }
        sections.enabled.removeAll { $0 == id }
        sections.disabled.removeAll { $0 == id }
        if visible { sections.enabled.append(id) }
        else { sections.disabled.append(id) }
        var result = visibility
        result.applyRows(sections, choices: availableChoices(in: visibility))
        return result
    }

    public func reordering(
        _ order: [HomeRowID], in visibility: HomeLibraryVisibility
    ) throws -> HomeLibraryVisibility {
        let current = sections(in: visibility)
        guard order.count == current.enabled.count,
              Set(order) == Set(current.enabled) else { throw AppError.invalidResponse }
        guard order != current.enabled else { return visibility }
        var result = visibility
        result.applyRows(
            .init(enabled: order, disabled: current.disabled),
            choices: availableChoices(in: visibility)
        )
        return result
    }
}
