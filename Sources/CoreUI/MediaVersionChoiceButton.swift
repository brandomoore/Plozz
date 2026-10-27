#if canImport(SwiftUI)
import CoreModels
import SwiftUI

private struct VersionPickerAudioLanguageKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    var versionPickerAudioLanguage: String? {
        get { self[VersionPickerAudioLanguageKey.self] }
        set { self[VersionPickerAudioLanguageKey.self] = newValue }
    }
}

public struct MediaVersionChoiceButton: View {
    private let presentation: MediaVersion.PickerPresentation
    private let isSelected: Bool
    private let isFocused: Bool
    private let action: () -> Void
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.versionPickerAudioLanguage) private var preferredAudioLanguage

    public init(
        presentation: MediaVersion.PickerPresentation,
        isSelected: Bool = false,
        isFocused: Bool = false,
        action: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                #if os(tvOS)
                .environment(\.themePalette, isFocused ? .light : palette)
                .environment(\.colorScheme, isFocused ? .light : colorScheme)
                #endif
        }
        .plozzActionButton(role: .secondary)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        let languages = presentation.prioritizedAudioLanguages(
            preferredLanguage: preferredAudioLanguage ?? LanguageMatch.deviceLanguageCode,
            locale: locale
        )
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = presentation.summaryWithoutBadges {
                    Text(verbatim: summary)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                } else if presentation.badges.isEmpty {
                    Text("Original")
                }
                if let releaseName = presentation.releaseName {
                    Text(verbatim: MediaSourceDisplayName.wrappingFileName(releaseName))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(verbatim: releaseName))
                }
                if !presentation.badges.isEmpty {
                    versionBadges(languages: languages)
                        #if os(tvOS)
                        .environment(\.mediaBadgeScale, 1.7)
                        #else
                        .environment(\.mediaBadgeScale, 0.85)
                        #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func versionBadges(languages: [String]) -> some View {
        if languages.count == 2 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: badgeSpacing) {
                    formatBadges
                    languageBadge("\(languages[0]) | +1", languages: languages)
                }
                .fixedSize(horizontal: true, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    WrappingHStackLayout(spacing: badgeSpacing, lineSpacing: 6) { formatBadges }
                    ViewThatFits(in: .horizontal) {
                        languageBadge(languages.joined(separator: " | "), languages: languages)
                            .fixedSize(horizontal: true, vertical: true)
                        WrappingHStackLayout(spacing: badgeSpacing, lineSpacing: 6) {
                            ForEach(languages, id: \.self) { language in
                                languageBadge(language, languages: [language])
                            }
                        }
                    }
                }
            }
        } else {
            WrappingHStackLayout(spacing: badgeSpacing, lineSpacing: 6) {
                formatBadges
                if let language = languages.first {
                    languageBadge(
                        languages.count > 1 ? "\(language) | +\(languages.count - 1)" : language,
                        languages: languages
                    )
                }
            }
        }
    }

    private var badgeSpacing: CGFloat {
        #if os(tvOS)
        MetadataBadgeSpacing.betweenBadges
        #else
        8
        #endif
    }

    private var formatBadges: some View {
        ForEach(presentation.formatBadges) { badge in
            versionBadge(badge)
        }
    }

    private func versionBadge(_ badge: MediaBadge) -> some View {
        MetadataMediaBadgeChip(badge: badge, adjacentSpacing: badgeSpacing)
    }

    private func languageBadge(_ label: String, languages: [String]) -> some View { // l10n:content - language names already resolved for the current locale.
        versionBadge(MediaBadge(label, style: .audio))
            .accessibilityLabel(Text(verbatim: languages.joined(separator: ", ")))
    }
}

/// A sheet entry point shared by player and context-menu version actions.
public struct MediaVersionPicker: View {
    private let versions: [MediaVersion]
    private let selectedVersionID: String?
    private let title: LocalizedStringKey
    private let footer: LocalizedStringKey?
    private let onSelect: (String) -> Void
    private let loadVersions: MediaVersionInventoryLoader?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var focusedID: String?

    public init(
        versions: [MediaVersion],
        selectedVersionID: String?,
        title: LocalizedStringKey = "Version",
        footer: LocalizedStringKey? = nil,
        loadVersions: MediaVersionInventoryLoader? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.versions = versions
        self.selectedVersionID = selectedVersionID
        self.title = title
        self.footer = footer
        self.onSelect = onSelect
        self.loadVersions = loadVersions
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    MediaVersionInventoryContent(versions: versions, loadVersions: loadVersions) { inventory in
                        ForEach(inventory.sortedForPicker()) { version in
                            MediaVersionChoiceButton(
                                presentation: .init(version, locale: locale),
                                isSelected: version.id == selectedVersionID,
                                isFocused: focusedID == version.id
                            ) {
                                dismiss()
                                onSelect(version.id)
                            }
                            .focused($focusedID, equals: version.id)
                            .accessibilityIdentifier("version-choice-\(version.id)")
                        }
                        #if os(tvOS)
                        .onAppear { focusedID = selectedVersionID ?? inventory.sortedForPicker().first?.id }
                        #endif
                    }
                    if let footer {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("version-picker-close")
                }
                #else
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                #endif
            }
            #if os(tvOS)
            .defaultFocus($focusedID, selectedVersionID ?? versions.sortedForPicker().first?.id)
            #endif
        }
    }
}
#endif
