#if canImport(SwiftUI)
import CoreModels
import CoreUI
import Observation
import SwiftUI

/// Profile-scoped channel browsing preferences for Live TV.
public struct LiveTVSettingsView: View {
    private let store: any LiveTVViewSettingsStoring
    private let sourceManagement: ((AnyView) -> AnyView)?
    private let searchPage: SettingsSearchPage
    @State private var settings: LiveTVViewSettings
    @State private var hiddenChannelsModel: LiveTVHiddenChannelsSettingsModel

    public init(
        store: any LiveTVViewSettingsStoring = LiveTVViewSettingsStore(),
        preferencesStore: any LiveTVPreferencesStoring = LiveTVPreferencesStore(),
        sourceManagement: ((AnyView) -> AnyView)? = nil, searchPage: SettingsSearchPage = .liveTV
    ) {
        self.store = store
        self.sourceManagement = sourceManagement
        self.searchPage = searchPage
        self._settings = State(initialValue: store.load())
        self._hiddenChannelsModel = State(
            initialValue: LiveTVHiddenChannelsSettingsModel(store: preferencesStore)
        )
    }

    public var body: some View {
        content
        .onAppear {
            hiddenChannelsModel.reload()
        }
        .onChange(of: settings) { _, settings in
            store.save(settings)
        }
    }

    @ViewBuilder private var content: some View {
        if searchPage == .liveTVGuide {
            LiveTVPreferencesPage(title: "Guide preferences") {
                LiveTVGuidePreferences(settings: $settings)
            }
        } else if searchPage == .liveTVVisibility {
            LiveTVPreferencesPage(title: "Channel visibility") {
                LiveTVChannelVisibilitySettings(settings: $settings, hiddenChannels: hiddenChannelsModel)
            }
        } else {
        LiveTVPreferencesPage(title: "Live TV") {
            let preferences = AnyView(LiveTVBrowsingSettingsSections(
                settings: $settings, hiddenChannels: hiddenChannelsModel
            ))
            if let sourceManagement {
                sourceManagement(preferences)
            } else {
                preferences
            }
        }
        }
    }
}

private struct LiveTVBrowsingSettingsSections: View {
    @Binding var settings: LiveTVViewSettings
    let hiddenChannels: LiveTVHiddenChannelsSettingsModel

    var body: some View {
        SettingsSectionGroup("Guide & browsing") {
            SettingsMenuRow(
                title: "Live TV opens to",
                value: Text(settings.startsWithCategories ? LocalizedStringResource("Categories") : "Guide")
            ) {
                Picker("Live TV opens to", selection: $settings.startsWithCategories) {
                    Text("Categories").tag(true)
                    Text("Guide").tag(false)
                }
            }
            .accessibilityIdentifier("live-tv-start-view")
            .settingsSearchAnchor("live-start")
            SettingsMenuRow(
                title: "Channel order",
                value: Text(settings.sortByName ? LocalizedStringResource("Name") : "Channel number")
            ) {
                Picker("Channel order", selection: $settings.sortByName) {
                    Text("Channel number").tag(false)
                    Text("Name").tag(true)
                }
            }
            .accessibilityIdentifier("live-tv-channel-order")
            .settingsSearchAnchor("channel-order")
            SettingsPageLink {
                LiveTVPreferencesPage(title: "Guide preferences") {
                    LiveTVGuidePreferences(settings: $settings)
                }
            } label: {
                SettingsDisclosureLabel { Label("Guide preferences", systemImage: "calendar") }
            }
            .buttonStyle(SettingsFormButtonStyle())
            .accessibilityIdentifier("live-tv-guide-preferences")
            .settingsSearchAnchor("guide-preferences")
            SettingsPageLink {
                LiveTVPreferencesPage(title: "Channel visibility") {
                    LiveTVChannelVisibilitySettings(settings: $settings, hiddenChannels: hiddenChannels)
                }
            } label: {
                SettingsDisclosureLabel { Label("Channel visibility", systemImage: "eye") }
            }
            .buttonStyle(SettingsFormButtonStyle())
            .accessibilityIdentifier("live-tv-channel-visibility")
            .settingsSearchAnchor("channel-visibility")
        }
        #if os(iOS)
        SettingsSectionGroup("Playback") {
            Toggle("Stop without Wi-Fi or Ethernet", isOn: $settings.wifiOnly).settingsSearchAnchor("live-network")
        } footer: {
            Text("Stops Live TV after detecting a change away from Wi-Fi or Ethernet. Brief cellular data use may occur during the change. Cellular playback is allowed when this setting is off.")
        }
        #endif
    }
}

private struct LiveTVGuidePreferences: View {
    @Binding var settings: LiveTVViewSettings

    var body: some View {
        #if os(tvOS)
        SettingsSectionGroup {
            Toggle("Auto preview", isOn: Binding(
                get: { settings.allowsAutomaticPreview },
                set: { settings.chooseAutoPreview($0) }
            ))
            .settingsSearchAnchor(
                "live-auto-preview", fallbackFor: settings.autoPreview ? [] : ["live-keep-watching"]
            )
        } footer: {
            Text("Preview the focused channel as you browse.")
        }
        SettingsSectionGroup {
            Toggle("Keep watching while browsing", isOn: $settings.keepWatchingWhileBrowsing)
                .disabled(!settings.autoPreview)
                .settingsSearchAnchor(settings.autoPreview ? "live-keep-watching" : "live-keep-watching-disabled")
        } footer: {
            Text("Keep the watched channel playing instead of previewing other channels.")
        }
        #endif
        SettingsSectionGroup {
            Toggle("Preview after watching", isOn: $settings.previewAfterWatching).settingsSearchAnchor("live-preview-after")
            Toggle("Recently watched", isOn: $settings.showsRecentChannels).settingsSearchAnchor("live-recent")
        } footer: {
            Text("Preview after watching keeps the channel playing behind the guide when you leave full screen. Recently watched shows the channels you watched last at the top of the guide.")
        }
    }
}

private struct LiveTVChannelVisibilitySettings: View {
    @Binding var settings: LiveTVViewSettings
    let hiddenChannels: LiveTVHiddenChannelsSettingsModel

    var body: some View {
        SettingsSectionGroup("Filters") {
            Toggle("Favorites only", isOn: $settings.favoritesOnly).settingsSearchAnchor("live-favorites-only")
            Toggle("With guide listings", isOn: $settings.guideOnly).settingsSearchAnchor("live-guide-only")
        }
        SettingsSectionGroup {
            SettingsPageLink {
                LiveTVPreferencesPage(title: "Hidden channels") {
                    LiveTVHiddenChannelsListContent(model: hiddenChannels)
                }
                .onAppear { hiddenChannels.reload() }
            } label: {
                HiddenChannelsNavigationLabel(count: hiddenChannels.hiddenChannels.count)
            }
            .buttonStyle(SettingsFormButtonStyle())
            .accessibilityIdentifier("live-tv-hidden-channels")
        }
    }
}

private struct LiveTVPreferencesPage<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: () -> Content
    #if os(tvOS)
    @SettingsPageDismiss private var dismiss
    @Environment(\.settingsInWorkspace) private var inWorkspace
    #endif

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsFormMetrics.sectionSpacing) {
                SettingsPageHeader(title)
                    .environment(\.settingsPageBackButton, inWorkspace ? AnyView(
                        SettingsBackButton { dismiss() }
                            .settingsPageEntryFocus()
                            .accessibilityIdentifier("live-tv-settings-back")
                    ) : nil)
                content()
            }
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.top, SettingsFormMetrics.pageTopInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
        }
        .scrollClipDisabled()
        .background { SettingsPageBackground() }
        #else
        SettingsPageScroll(content: content)
            .navigationTitle(Text(title))
        #endif
    }
}

private struct HiddenChannelsNavigationLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 16) {
            Label("Hidden channels", systemImage: "eye.slash")
            Spacer()
            if count > 0 {
                Text(count, format: .number)
                    .settingsRowSecondary()
            }
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .settingsRowSecondary()
        }
    }
}

private struct LiveTVHiddenChannelsListContent: View {
    let model: LiveTVHiddenChannelsSettingsModel

    var body: some View {
        if model.isLoading && !model.hasLoadedPreferences {
            SettingsSectionGroup {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading hidden channels")
                }
            }
        } else if !model.hasLoadedPreferences {
            SettingsSectionGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Hidden channels couldn't be loaded.", systemImage: "exclamationmark.triangle.fill")
                    Button("Retry") {
                        model.retry()
                    }
                    .plozzActionButton(role: .secondary)
                }
            }
        } else {
            if model.hasVisibilityRules {
                SettingsSectionGroup {
                    Text("Category and regional filtering is active. Review filtered channels in Live TV > Manage channels > Hidden channels.")
                    Button("Reset category and region visibility") {
                        model.resetVisibility()
                    }
                    .buttonStyle(SettingsFormButtonStyle())
                    .disabled(model.hasPendingChanges)
                }
            }
            if let issue = model.issue {
                LiveTVHiddenChannelsFailureSection(issue: issue) {
                    model.retry()
                }
            }

            if model.hiddenChannels.isEmpty {
                SettingsSectionGroup {
                    ContentUnavailableView(
                        model.hasVisibilityRules ? "No individually hidden channels" : "No hidden channels",
                        systemImage: "eye"
                    )
                }
            } else {
                SettingsSectionGroup {
                    ForEach(model.hiddenChannels) { channel in
                        HStack(spacing: 16) {
                            Text(channel.name)
                                .lineLimit(2)
                            Spacer()
                            Button("Restore") {
                                model.restoreChannel(id: channel.id)
                            }
                            .plozzActionButton(role: .secondary)
                            .accessibilityLabel("Restore \(channel.name)")
                            .disabled(model.hasPendingChanges)
                        }
                    }
                }

                if model.hiddenChannels.count > 1 {
                    SettingsSectionGroup {
                        Button("Restore all") {
                            model.restoreAllChannels()
                        }
                        .buttonStyle(SettingsFormButtonStyle())
                        .disabled(model.hasPendingChanges)
                    }
                }
            }
        }
    }
}

private struct LiveTVHiddenChannelsFailureSection: View {
    let issue: LiveTVHiddenChannelsSettingsModel.Issue
    let retry: () -> Void

    var body: some View {
        SettingsSectionGroup {
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                Button("Retry", action: retry)
                    .plozzActionButton(role: .secondary)
            }
        }
    }

    private var message: LocalizedStringResource {
        switch issue {
        case .loadFailed:
            "Hidden channels couldn't be refreshed."
        case .saveFailed:
            "That change couldn't be saved."
        }
    }
}

@MainActor
@Observable
final class LiveTVHiddenChannelsSettingsModel {
    enum Issue: Equatable {
        case loadFailed
        case saveFailed
    }

    private enum PendingMutation: Equatable {
        case restore(String)
        case restoreAll
        case resetVisibility
    }

    @ObservationIgnored
    private let store: any LiveTVPreferencesStoring
    private var preferences: LiveTVPreferences?
    @ObservationIgnored
    private var pendingMutation: PendingMutation?

    private(set) var isLoading = false
    private(set) var issue: Issue?

    var hiddenChannels: [LiveTVHiddenChannel] {
        preferences?.hiddenChannels ?? []
    }
    var hasVisibilityRules: Bool { preferences?.organization.hasVisibilityRules == true }

    var hasLoadedPreferences: Bool {
        preferences != nil
    }

    var hasPendingChanges: Bool {
        pendingMutation != nil
    }

    init(store: any LiveTVPreferencesStoring) {
        self.store = store
    }

    func reload() {
        if let pendingMutation {
            apply(pendingMutation)
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            preferences = try store.load()
            issue = nil
        } catch {
            issue = .loadFailed
        }
    }

    func restoreChannel(id: String) {
        apply(.restore(id))
    }

    func restoreAllChannels() {
        apply(.restoreAll)
    }

    func resetVisibility() {
        apply(.resetVisibility)
    }

    func retry() {
        reload()
    }

    private func apply(_ mutation: PendingMutation) {
        pendingMutation = mutation
        let current: LiveTVPreferences
        do {
            current = try store.load()
        } catch {
            issue = .loadFailed
            return
        }

        var updated: LiveTVPreferences
        switch mutation {
        case let .restore(id):
            updated = current.restoringChannel(id: id)
        case .restoreAll:
            updated = current.restoringAllChannels()
        case .resetVisibility:
            updated = current
            updated.organization = current.organization.resettingVisibility()
        }

        guard updated != current else {
            preferences = current
            pendingMutation = nil
            issue = nil
            return
        }

        do {
            try store.save(updated)
            preferences = updated
            pendingMutation = nil
            issue = nil
        } catch {
            preferences = current
            issue = .saveFailed
        }
    }
}
#endif
