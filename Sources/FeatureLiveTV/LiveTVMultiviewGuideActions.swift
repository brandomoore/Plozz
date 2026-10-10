import CoreUI
import FeatureLiveTVCore
import SwiftUI

enum LiveTVMultiviewSelection: Equatable {
    case add
    case replace(UUID)

    var title: LocalizedStringResource {
        switch self {
        case .add: "Add channel to Multiview"
        case .replace: "Replace channel in Multiview"
        }
    }

    @MainActor
    func apply(_ channel: LiveTVPrototypeChannel, to coordinator: LiveTVMultiviewCoordinator) {
        switch self {
        case .add: coordinator.add(channel)
        case .replace(let id): coordinator.replace(id, with: channel)
        }
    }
}

struct LiveTVMultiviewGuideSelectionHeader: View {
    let selection: LiveTVMultiviewSelection
    let cancel: () -> Void

    var body: some View {
        HStack {
            Text(selection.title)
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("live-multiview-guide-selection")
            Spacer()
            Button("Cancel", systemImage: "xmark", action: cancel)
                .buttonStyle(PrototypeButtonStyle(surface: .control))
                .accessibilityIdentifier("live-multiview-cancel-selection")
        }
        #if os(tvOS)
        .focusSection()
        .onExitCommand(perform: cancel)
        #endif
    }
}

struct LiveTVMultiviewGuideExit: ViewModifier {
    let cancel: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        if let cancel {
            content.onExitCommand(perform: cancel)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct LiveTVMultiviewFavoritesView: View {
    let model: LiveTVPrototypeModel
    let open: (LiveTVMultiviewFavorite) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 22

    var body: some View {
        #if os(tvOS)
        VStack(spacing: 24) {
            HStack(spacing: 20) {
                Text("Favorite Multiviews")
                    .font(.system(size: titleSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("live-multiview-favorites-title")
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Text("Done")
                        .font(.system(size: bodySize, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-close-sheet")
            }
            ScrollView {
                VStack(spacing: 24) {
                    favoritesContent
                }
                .frame(maxWidth: .infinity)
                .padding(8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .font(.system(size: bodySize))
        .padding(32)
        .frame(maxWidth: 640, maxHeight: 600, alignment: .top)
        .onExitCommand { dismiss() }
        #else
        LiveTVSettingsPage(title: "Favorite Multiviews") {
            favoritesContent
        }
        #endif
    }

    @ViewBuilder
    private var favoritesContent: some View {
        if model.favoriteMultiviews.isEmpty {
            #if os(tvOS)
            VStack(spacing: 16) {
                Image(systemName: "star")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityHidden(true)
                Text("No favorite Multiviews")
                    .font(.system(size: bodySize, weight: .semibold))
                Text("Favorite a Multiview to open its channels and layout here.")
                    .font(.system(size: detailSize))
                    .foregroundStyle(palette.secondaryText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420)
            .padding(.vertical, 32)
            .accessibilityIdentifier("live-multiview-favorites-empty")
            #else
            ContentUnavailableView(
                "No favorite Multiviews", systemImage: "star",
                description: Text("Favorite a Multiview to open its channels and layout here."))
            #endif
        } else {
            SettingsSectionGroup {
                ForEach(model.favoriteMultiviews) { favorite in
                    Button {
                        open(favorite)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(favorite.name).lineLimit(2)
                            HStack {
                                Text("\(favorite.channelIDs.count) channels")
                                Text(favorite.layout.title)
                            }
                            #if os(tvOS)
                            .font(.system(size: detailSize))
                            #else
                            .font(.caption)
                            #endif
                            .settingsRowSecondary()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #if os(tvOS)
                        .padding(12)
                        #endif
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-multiview-saved-\(favorite.id)")
                    .contextMenu {
                        Button("Remove from Favorites", systemImage: "star.slash") {
                            model.removeMultiviewFavorite(favorite.id)
                        }
                    }
                }
            }
        }
        if model.preferencesIssue != nil {
            SettingsSectionGroup {
                Text("Multiview favorites could not be loaded or saved. Retry to keep your changes.")
                Button("Retry", action: model.retryPreferences)
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            }
        }
    }
}
