#if os(iOS)
import AniListService
import CoreModels
import CoreUI
import MALService
import SimklService
import SwiftUI
import TraktService
import WetrakrService
import FeatureSettings

struct PlozziOSTrackerSettingsView: View {
    let appModel: PlozziOSAppModel
    @State private var destination: SettingsSearchPage?

    private var pages: [SettingsSearchPage] {
        let pages: [SettingsSearchPage] = [.trakt, .simkl, .wetrakr, .anilist, .myanimelist, .publicMetaDB]
        return pages.filter { $0 != .wetrakr || appModel.wetrakrService.isConfigured }
    }

    var body: some View {
        List {
            SettingsSectionGroup {
                ForEach(pages, id: \.self) { page in
                    if let account = page.trackerAccount {
                        Button { destination = page } label: {
                            SettingsDisclosureLabel { Text(verbatim: account.name) }
                        }
                        .settingsActionRow()
                        .accessibilityIdentifier("settings-page-\(account.rowID)")
                    }
                }
            } footer: {
                Text("Connect a tracker to report what you watch in this profile. Syncing history to media shares is optional.")
            }
        }
        .settingsPageSurface()
        .navigationTitle("Trackers")
        .navigationDestination(item: $destination) { page in
            PlozziOSTrackerAccountPage(page: page, appModel: appModel)
        }
    }
}

struct PlozziOSTrackerAccountPage: View {
    let page: SettingsSearchPage
    let appModel: PlozziOSAppModel

    var body: some View {
        if let account = page.trackerAccount, page != .lastfm,
           page != .wetrakr || appModel.wetrakrService.isConfigured {
            List {
                accountSection
                    .settingsSearchGroup(SettingsSearchCatalog.targets(on: page))
            }
            .settingsPageSurface()
            .navigationTitle(Text(verbatim: account.name))
            .task { await refreshStatus() }
        } else {
            ContentUnavailableView("Setting unavailable", systemImage: "magnifyingglass")
        }
    }

    @ViewBuilder private var accountSection: some View {
        if page == .publicMetaDB {
            PublicMetaDBSettingsContent(
                service: appModel.publicMetaDBService, makeHistoryImport: appModel.makePublicMetaDBHistoryImport
            )
        } else {
            switch page {
            case .trakt:
                account(appModel.traktService, appModel.makeTraktHistoryImport) { TraktSettingsContent(service: appModel.traktService) }
            case .simkl:
                account(appModel.simklService, appModel.makeSimklHistoryImport) { SimklSettingsContent(service: appModel.simklService) }
            case .wetrakr:
                account(appModel.wetrakrService, appModel.makeWetrakrHistoryImport) { WetrakrSettingsContent(service: appModel.wetrakrService) }
            case .anilist:
                account(appModel.anilistService, appModel.makeAniListHistoryImport) { AniListSettingsContent(service: appModel.anilistService) }
            case .myanimelist:
                account(appModel.malService, appModel.makeMALHistoryImport) { MALSettingsContent(service: appModel.malService) }
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private func account<Content: View>(
        _ tracker: any TrackerHistorySyncReading, _ makeSession: @escaping @MainActor () -> TrackerHistoryImportSession,
        @ViewBuilder credentials: () -> Content
    ) -> some View {
        if let connection = tracker.historyConnectionID {
            TrackerAccountSettingsRows(tracker: tracker, makeSession: makeSession).id(connection)
        }
        SettingsSectionGroup("Account", content: credentials)
    }

    private func refreshStatus() async {
        // Returning from a browser or reopening a page must not abandon a pending code.
        switch page {
        case .trakt: await appModel.traktService.refreshStatus()
        case .wetrakr: await appModel.wetrakrService.refreshStatus()
        case .simkl:
            if case .connecting = appModel.simklService.phase { return }
            await appModel.simklService.refreshStatus()
        case .anilist:
            if case .awaitingToken = appModel.anilistService.phase { return }
            await appModel.anilistService.refreshStatus()
        case .myanimelist:
            if case .awaitingAuthorizationCode = appModel.malService.phase { return }
            await appModel.malService.refreshStatus()
        default: break
        }
    }
}

private struct TraktSettingsContent: View {
    let service: TraktService
    @Environment(\.openURL) private var openURL
    @State private var browser = TrackerBrowserAuthorization()
    @State private var confirmingReconnect = false

    var body: some View {
        Group {
            content
        }
        .confirmationDialog("Reconnect Trakt for this profile?", isPresented: $confirmingReconnect, titleVisibility: .visible) {
            Button("Reconnect Trakt", role: .destructive, action: connect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Try Retry first. Reconnecting replaces this profile's Trakt connection on all your Plozz devices. Other profiles are not affected.")
        }
        .onChange(of: service.phase) { _, _ in
            confirmingReconnect = false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .unknown, .savingConnection:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            connectButton
        case .authorizing:
            loadingStatus
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
            .settingsActionRow()
        case let .connecting(userCode, verificationURL, _):
            Text("Enter this code on Trakt:")
                .plozzForeground(.secondary)
            Text(userCode)
                .font(.title2.monospaced().weight(.semibold))
                .textSelection(.enabled)
            if let url = URL(string: verificationURL) {
                Button("Open Trakt") {
                    openURL(url)
                }
                .settingsActionRow()
            }
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
            .settingsActionRow()
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
            .settingsActionRow()
        case let .error(message):
            errorStatus(message)
            connectButton
        case let .syncError(message, canReconnect):
            errorStatus(message)
            Button("Retry") {
                Task { await service.refreshStatus() }
            }
            .settingsActionRow()
            .trackerConnectionSearchTarget(.trakt)
            if canReconnect {
                Button("Reconnect Trakt") { confirmingReconnect = true }
                    .settingsActionRow()
            }
        }
    }

    private var connectButton: some View {
        Button("Connect Trakt", action: connect)
            .settingsActionRow()
            .trackerConnectionSearchTarget(.trakt)
    }

    private func connect() {
        if #available(iOS 17.4, *),
           Bundle.main.bundleIdentifier == "com.thatcube.Plozz" {
            service.connect { url, callback in
                try await browser.authorize(url: url, callback: callback)
            }
        } else {
            service.connect()
        }
    }
}

private struct WetrakrSettingsContent: View {
    let service: WetrakrService
    @Environment(\.openURL) private var openURL
    @State private var browser = TrackerBrowserAuthorization()
    @State private var confirmingReconnect = false

    var body: some View {
        Group { content }
            .confirmationDialog("Reconnect WeTrakr for this profile?", isPresented: $confirmingReconnect, titleVisibility: .visible) {
                Button("Reconnect WeTrakr", role: .destructive, action: connect)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Try Retry first. Reconnecting replaces this profile's WeTrakr connection on all your Plozz devices. Other profiles are not affected.")
            }
            .onChange(of: service.phase) { _, _ in
                confirmingReconnect = false
            }
    }

    @ViewBuilder private var content: some View {
        switch service.phase {
        case .unknown, .savingConnection:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            Button("Connect WeTrakr", action: connect)
                .settingsActionRow()
                .trackerConnectionSearchTarget(.wetrakr)
        case .authorizing:
            loadingStatus
            Button("Cancel", role: .cancel) { service.cancelConnect() }
                .settingsActionRow()
        case let .connecting(code, verificationURL, _):
            Text("Enter this code on WeTrakr:")
                .plozzForeground(.secondary)
            Text(code)
                .font(.title2.monospaced().weight(.semibold))
                .textSelection(.enabled)
            if let url = URL(string: verificationURL) {
                Button("Open WeTrakr") { openURL(url) }
                    .settingsActionRow()
            }
            Button("Cancel", role: .cancel) { service.cancelConnect() }
                .settingsActionRow()
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) { Task { await service.disconnect() } }
                .settingsActionRow()
        case let .error(message):
            errorStatus(message)
            Button("Connect WeTrakr", action: connect)
                .settingsActionRow()
                .trackerConnectionSearchTarget(.wetrakr)
        case let .syncError(message, canReconnect):
            errorStatus(message)
            Button("Retry") { Task { await service.refreshStatus() } }
                .settingsActionRow()
                .trackerConnectionSearchTarget(.wetrakr)
            if canReconnect {
                Button("Reconnect WeTrakr") { confirmingReconnect = true }
                    .settingsActionRow()
            }
        }
    }

    private func connect() {
        if #available(iOS 17.4, *), Bundle.main.bundleIdentifier == "com.thatcube.Plozz" {
            service.connect { url, callback in try await browser.authorize(url: url, callback: callback) }
        } else {
            service.connect()
        }
    }
}

private struct SimklSettingsContent: View {
    let service: SimklService
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch service.phase {
        case .unknown:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            connectButton
        case let .connecting(userCode, verificationURL, _):
            Text("Enter this code on Simkl:")
                .plozzForeground(.secondary)
            Text(userCode)
                .font(.title2.monospaced().weight(.semibold))
                .textSelection(.enabled)
            if let url = URL(string: verificationURL) {
                Button("Open Simkl") {
                    openURL(url)
                }
                .settingsActionRow()
            }
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
            .settingsActionRow()
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
            .settingsActionRow()
        case let .error(message):
            errorStatus(message)
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect Simkl") {
            service.connect()
        }
        .settingsActionRow()
        .trackerConnectionSearchTarget(.simkl)
    }
}

private struct AniListSettingsContent: View {
    let service: AniListService
    @Environment(\.openURL) private var openURL
    @State private var code = ""

    var body: some View {
        switch service.phase {
        case .unknown:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            connectButton
        case let .awaitingToken(authorizationURL):
            authorizationForm(
                authorizationURL: authorizationURL,
                openButtonTitle: "Open AniList",
                submitButtonTitle: "Redeem Code"
            ) {
                Task { await service.submitToken(code) }
            }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
            .settingsActionRow()
        case let .error(message):
            errorStatus(message)
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect AniList") {
            code = ""
            service.connect()
        }
        .settingsActionRow()
        .trackerConnectionSearchTarget(.anilist)
    }

    @ViewBuilder
    private func authorizationForm(
        authorizationURL: String,
        openButtonTitle: String,
        submitButtonTitle: String,
        submit: @escaping () -> Void
    ) -> some View {
        Text("Authorize in your browser, then enter the short code shown there.")
            .plozzForeground(.secondary)
        if let url = URL(string: authorizationURL) {
            Button(openButtonTitle) {
                openURL(url)
            }
            .settingsActionRow()
        }
        TextField("Authorization code", text: $code)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        Button(submitButtonTitle, action: submit)
            .settingsActionRow()
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel", role: .cancel) {
            service.cancelConnect()
        }
        .settingsActionRow()
    }
}

private struct MALSettingsContent: View {
    let service: MALService
    @Environment(\.openURL) private var openURL
    @State private var code = ""

    var body: some View {
        switch service.phase {
        case .unknown:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            connectButton
        case let .awaitingAuthorizationCode(authorizationURL):
            Text("Authorize in your browser, then enter the short code shown there.")
                .plozzForeground(.secondary)
            if let url = URL(string: authorizationURL) {
                Button("Open MyAnimeList") {
                    openURL(url)
                }
                .settingsActionRow()
            }
            TextField("Authorization code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Redeem Code") {
                service.submitAuthorizationCode(code)
            }
            .settingsActionRow()
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
            .settingsActionRow()
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
            .settingsActionRow()
        case let .error(message):
            errorStatus(message)
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect MyAnimeList") {
            code = ""
            service.connect()
        }
        .settingsActionRow()
        .trackerConnectionSearchTarget(.myanimelist)
    }
}

private extension View {
    /// When account controls don't exist yet, reveal their connection prerequisite instead.
    func trackerConnectionSearchTarget(_ page: SettingsSearchPage) -> some View {
        settingsSearchAnchor("connect-\(page.rawValue)", fallbackFor: SettingsSearchCatalog.targets(on: page))
    }
}

private var loadingStatus: some View {
    HStack {
        ProgressView()
        Text("Checking connection…")
            .plozzForeground(.secondary)
    }
}

private var unavailableStatus: some View {
    Label("Unavailable in this build", systemImage: "exclamationmark.triangle")
        .plozzForeground(.secondary)
}

private func connectedStatus(username: String) -> some View {
    TrackerConnectedStatus(username: username)
}

private func errorStatus(_ message: LocalizedStringResource) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
}
#endif
