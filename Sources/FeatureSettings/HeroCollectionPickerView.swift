#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct HeroCollectionPickerView: View {
    @Binding private var selections: [HeroCollectionSelection]
    private let libraries: [AggregatedLibrary]
    private let accounts: [ResolvedAccount]
    private let onSelect: ((HeroCollectionSelection) -> Void)?
    @State private var sourceID: HeroCollectionPickerSource.ID?
    @SettingsPageDismiss private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SettingsDetailNavigation.self) private var detailNavigation: SettingsDetailNavigation?

    public init(
        selections: Binding<[HeroCollectionSelection]>,
        libraries: [AggregatedLibrary],
        accounts: [ResolvedAccount],
        onSelect: ((HeroCollectionSelection) -> Void)? = nil
    ) {
        _selections = selections
        self.libraries = libraries
        self.accounts = accounts
        self.onSelect = onSelect
    }

    public var body: some View {
        let sources = HeroCollectionPickerSource.available(libraries: libraries, accounts: accounts)
        let preferred = sourceID ?? selections.first.map {
            HeroCollectionPickerSource.ID(accountID: $0.accountID, libraryID: $0.libraryID)
        }
        let source = sources.first(where: { $0.id == preferred }) ?? sources.first
        ViewCustomizationList(
            title: onSelect == nil ? "Choose collections" : "Choose collection",
            initialRowID: source?.id.focusID ?? "hero-collection-done"
        ) {
            if onSelect == nil && !selections.isEmpty {
                HeroCollectionSection(title: "Selected collections") {
                    ForEach(selections) { selection in
                        let selectedSource = sources.first {
                            $0.id.accountID == selection.accountID && $0.id.libraryID == selection.libraryID
                                && accounts.contains(where: selection.matches)
                        }
                        HeroCollectionChoice(
                            selections: $selections, choice: selection,
                            source: selectedSource, isSummary: true
                        )
                    }
                    Button("Clear selection") { selections = [] }
                        .plozzActionButton(role: .secondary)
                        .modifier(ViewCustomizationRowFocus(id: "hero-collection-clear"))
                }
            }
            if let source {
                HeroCollectionSources(
                    sources: sources,
                    selection: Binding(get: { source.id }, set: { sourceID = $0 })
                )
                if let account = accounts.first(where: { $0.account.id == source.id.accountID }) {
                    HeroCollectionListView(
                        selections: $selections, source: source, provider: account.provider,
                        serverUserID: account.plexHomeUserID ?? account.provider.session.userID,
                        onSelect: onSelect
                    )
                    .id([
                        source.id.focusID, account.credentialRevision.rawValue.uuidString,
                        account.provider.session.userID, account.plexHomeUserID ?? ""
                    ])
                }
            } else {
                Text("No available collection sources.")
                Button("Done") {
                    if let detailNavigation {
                        detailNavigation.pop(animated: !reduceMotion)
                    } else {
                        dismiss()
                    }
                }
                .plozzActionButton(role: .secondary)
                .modifier(ViewCustomizationRowFocus(id: "hero-collection-done"))
            }
        }
        .onAppear { if sourceID == nil { sourceID = source?.id } }
    }
}

private struct HeroCollectionSources: View {
    let sources: [HeroCollectionPickerSource]
    @Binding var selection: HeroCollectionPickerSource.ID

    var body: some View {
        HeroCollectionSection(title: "Source") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sources) { source in
                    SettingsCheckableRow(
                        title: source.libraryTitle.map { Text(verbatim: $0) } ?? Text("Personal collections"),
                        subtitle: Text(verbatim: "\(source.serverName) / \(source.accountName)"),
                        subtitleProvider: source.providerKind,
                        titleLineLimit: nil, subtitleLineLimit: nil,
                        isChecked: source.id == selection,
                        flushLeading: false,
                        action: { selection = source.id }
                    )
                    .accessibilityIdentifier(source.id.focusID)
                    .modifier(ViewCustomizationRowFocus(id: source.id.focusID))
                }
            }
        }
    }
}

private struct HeroCollectionListView: View {
    @Binding var selections: [HeroCollectionSelection]
    let source: HeroCollectionPickerSource
    let serverUserID: String
    let onSelect: ((HeroCollectionSelection) -> Void)?
    @State private var model: HeroCollectionListModel
    @State private var request = 0

    init(
        selections: Binding<[HeroCollectionSelection]>,
        source: HeroCollectionPickerSource,
        provider: any MediaProvider,
        serverUserID: String,
        onSelect: ((HeroCollectionSelection) -> Void)? = nil
    ) {
        _selections = selections
        self.source = source
        self.serverUserID = serverUserID
        self.onSelect = onSelect
        _model = State(initialValue: HeroCollectionListModel(provider: provider, libraryID: source.id.libraryID))
    }

    var body: some View {
        HeroCollectionSection(title: "Collections") {
            ForEach(model.items) { collection in
                HeroCollectionChoice(
                    selections: $selections,
                    choice: HeroCollectionSelection(
                        accountID: source.id.accountID, libraryID: source.id.libraryID,
                        collectionID: collection.id, title: collection.title, serverUserID: serverUserID
                    ), onSelect: onSelect
                )
            }
            if model.isLoading {
                ProgressView()
            } else if let error = model.error {
                Text(error.userMessage)
                Button("Retry") { request += 1 }
                    .plozzActionButton(role: .secondary)
                    .modifier(ViewCustomizationRowFocus(id: "hero-collection-retry"))
            } else if model.hasMore {
                Button("Load more") { request += 1 }
                    .plozzActionButton(role: .secondary)
                    .modifier(ViewCustomizationRowFocus(id: "hero-collection-more"))
            } else if model.items.isEmpty {
                Text("No collections in this source.")
            }
        }
        .task(id: request) { await model.loadNextPage() }
    }
}

private struct HeroCollectionChoice: View {
    @Binding var selections: [HeroCollectionSelection]
    let choice: HeroCollectionSelection
    var source: HeroCollectionPickerSource? = nil
    var isSummary = false
    var onSelect: ((HeroCollectionSelection) -> Void)? = nil

    var body: some View {
        let selected = HeroCollectionPickerSelection.contains(choice, in: selections)
        let focusID = choice.pickerFocusID(isSummary: isSummary)
        Button {
            if let onSelect { onSelect(choice) }
            else { HeroCollectionPickerSelection.toggle(choice, in: &selections) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: choice.title).multilineTextAlignment(.leading)
                    if isSummary {
                        if let source {
                            if let libraryTitle = source.libraryTitle {
                                Text(verbatim: "\(libraryTitle) / \(source.serverName) / \(source.accountName)")
                                    .font(.caption)
                            } else {
                                Text("Personal collections").font(.caption)
                                Text(verbatim: "\(source.serverName) / \(source.accountName)").font(.caption)
                            }
                        } else {
                            Text("Unavailable source").font(.caption)
                        }
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            #endif
        }
        #if os(tvOS)
        .buttonStyle(SettingsFocusButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityIdentifier(focusID)
        .modifier(ViewCustomizationRowFocus(id: focusID))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct HeroCollectionSection<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
        #else
        SettingsSectionGroup(title, content: content)
        #endif
    }
}
#endif
