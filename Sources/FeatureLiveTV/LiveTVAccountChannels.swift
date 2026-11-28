import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// A connected media server need not have Live TV. Checking is read-only;
/// only an explicit selection adds this account to the profile's guide.
struct LiveTVAvailableAccountControls: View {
    let choice: LiveTVServerChoice
    let model: LiveTVSourceManagementModel
    let canManage: @MainActor () -> Bool
    @State private var probe: LiveTVServerProbeModel
    @State private var attempt = 0
    @Environment(NavigationStyleSettingsModel.self) private var navigation: NavigationStyleSettingsModel?

    init(choice: LiveTVServerChoice, model: LiveTVSourceManagementModel,
         resolver: @escaping LiveTVServerProviderResolver, canManage: @escaping @MainActor () -> Bool) {
        self.choice = choice
        self.model = model
        self.canManage = canManage
        _probe = State(initialValue: LiveTVServerProbeModel(resolver: resolver))
    }

    var body: some View {
        Group {
            if probe.canAdd {
                SettingsSectionGroup("Live TV") {
                    Toggle(isOn: Binding(get: { false }, set: { enabled in
                        guard enabled, canManage() else { return }
                        model.perform {
                            try model.addServer(probe.checkedChoice())
                            navigation?.showsLiveTV = true
                        }
                    })) {
                        Label("Show in guide", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            } else if probe.isChecking {
                ProgressView("Checking Live TV")
            } else if let failure = probe.failure, failure != .unsupportedAPI {
                SettingsSectionGroup("Live TV") {
                    InlineErrorMessage(Text(failure.userDescription))
                    retryButton
                }
            } else if let availability = probe.availability, availability.status == .serviceUnavailable {
                SettingsSectionGroup("Live TV") {
                    LiveTVServerAvailabilitySummary(availability: availability)
                    retryButton
                }
            }
        }
        .task(id: attempt) {
            guard canManage() else { return }
            probe.beginCheck(choice)
            if let request = probe.pendingRequest { await probe.perform(request) }
        }
    }

    private var retryButton: some View {
        Button("Retry") { attempt &+= 1 }
            .plozzActionButton(role: .secondary)
    }
}

struct LiveTVAccountChannels: View {
    let catalog: LiveTVSourcesCatalog
    let accountID: String
    let sourceID: String
    let canManage: @MainActor () -> Bool
    @State private var query = ""
    @State private var refresh = 0

    private var isAvailable: Bool {
        canManage() && catalog.isPresentationCurrent && catalog.imports.configuration.servers.contains {
            $0.id == sourceID && $0.accountID == accountID && $0.isEnabled
        }
    }

    var body: some View {
        LiveTVSettingsPage(title: "Manage channels") {
            if isAvailable {
                let model = catalog.catalog
                let hidden = model.effectiveHiddenChannelIDs
                let references = catalog.imports.serverChannelReferences
                let channels = model.channels.filter {
                    references[$0.id]?.sourceID == sourceID && references[$0.id]?.accountID == accountID
                        && (query.isEmpty || $0.name.localizedStandardContains(query))
                }
                LiveTVOrganizationFailure(model: model)
                if let failure = status?.failure {
                    SettingsSectionGroup {
                        InlineErrorMessage(Text(failure.userDescription))
                        Button("Retry") { refresh &+= 1 }.plozzActionButton(role: .secondary)
                    }
                }
                SettingsSectionGroup {
                    TextField("Find a channel", text: $query).autocorrectionDisabled()
                }
                if channels.isEmpty {
                    if status?.phase == .loading || catalog.isLoading {
                        ProgressView("Loading channels")
                    } else {
                        ContentUnavailableView("No channels", systemImage: "tv")
                    }
                } else {
                    LazyVStack(spacing: SettingsRowMetrics.formRowSpacing) {
                        ForEach(channels) { channel in
                            SettingsCheckableRow(
                                title: Text(verbatim: channel.name), isChecked: !hidden.contains(channel.id),
                                isEnabled: !model.scanHiddenChannelIDs.contains(channel.id)
                            ) {
                                guard isAvailable, catalog.isCurrent,
                                      let current = catalog.imports.serverChannelReferences[channel.id],
                                      current == references[channel.id], let row = model.channel(id: channel.id)
                                else { return }
                                model.reloadPreferences()
                                guard model.preferencesIssue == nil else { return }
                                if model.effectiveHiddenChannelIDs.contains(row.id) { _ = model.showChannel(row.id) }
                                else { _ = model.hideChannel(row) }
                            }
                            .accessibilityIdentifier("live-tv-channel-visibility-\(channel.id)")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Source unavailable", systemImage: "lock")
            }
        }
        .task(id: refresh) {
            guard isAvailable, refresh > 0 || status?.phase == .idle else { return }
            await catalog.refresh(sourceID: sourceID)
        }
    }

    private var status: LiveTVServerSourceStatus? {
        catalog.imports.serverSources.first { $0.id == sourceID && $0.source.accountID == accountID }
    }
}
