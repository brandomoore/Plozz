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

    var body: some View {
        List {
            Text(
                """
                Connections are stored separately for each Plozz profile. \
                Existing trackers keep their playback settings. Connecting PublicMetaDB does not import history to your servers.
                """
            )
            .font(.footnote)
            .plozzForeground(.secondary)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            SettingsSectionGroup(verbatim: "Trakt") {
                TraktSettingsContent(service: appModel.traktService, makeHistoryImport: appModel.makeTraktHistoryImport)
            }

            SettingsSectionGroup(verbatim: "Simkl") {
                SimklSettingsContent(service: appModel.simklService, makeHistoryImport: appModel.makeSimklHistoryImport)
            }
            if appModel.wetrakrService.isConfigured {
                SettingsSectionGroup(verbatim: "WeTrakr") {
                    WetrakrSettingsContent(service: appModel.wetrakrService, makeHistoryImport: appModel.makeWetrakrHistoryImport)
                }
            }

            SettingsSectionGroup(verbatim: "AniList") {
                AniListSettingsContent(service: appModel.anilistService, makeHistoryImport: appModel.makeAniListHistoryImport)
            }

            SettingsSectionGroup(verbatim: "MyAnimeList") {
                MALSettingsContent(service: appModel.malService, makeHistoryImport: appModel.makeMALHistoryImport)
            }
            SettingsSectionGroup(verbatim: "PublicMetaDB") {
                PublicMetaDBSettingsContent(
                    service: appModel.publicMetaDBService, makeHistoryImport: appModel.makePublicMetaDBHistoryImport
                )
            }
        }
        .settingsPageSurface()
        .navigationTitle("Trackers")
        .task {
            async let trakt: Void = appModel.traktService.refreshStatus()
            async let simkl: Void = appModel.simklService.refreshStatus()
            async let wetrakr: Void = appModel.wetrakrService.refreshStatus()
            async let anilist: Void = appModel.anilistService.refreshStatus()
            async let mal: Void = appModel.malService.refreshStatus()
            _ = await (trakt, simkl, wetrakr, anilist, mal)
        }
    }
}

private struct TraktSettingsContent: View {
    let service: TraktService
    let makeHistoryImport: @MainActor () -> TrackerHistoryImportSession
    @Environment(\.openURL) private var openURL
    @State private var browser = TrackerBrowserAuthorization()
    @State private var confirmingReconnect = false
    @State private var showingHistory = false

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
            if service.historyConnectionID == nil { showingHistory = false }
        }
        .sheet(isPresented: $showingHistory) {
            NavigationStack { TrackerHistoryImportView(makeSession: makeHistoryImport) }
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
            }
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Compare with server history") { showingHistory = true }
                .accessibilityIdentifier("trakt.compare-history")
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
        case let .error(message):
            errorStatus(message)
            connectButton
        case let .syncError(message, canReconnect):
            errorStatus(message)
            Button("Retry") {
                Task { await service.refreshStatus() }
            }
            if canReconnect {
                Button("Reconnect Trakt") { confirmingReconnect = true }
            }
        }
    }

    private var connectButton: some View {
        Button("Connect Trakt", action: connect)
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
    let makeHistoryImport: @MainActor () -> TrackerHistoryImportSession
    @Environment(\.openURL) private var openURL
    @State private var browser = TrackerBrowserAuthorization()
    @State private var confirmingReconnect = false
    @State private var showingHistory = false

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
                if service.historyConnectionID == nil { showingHistory = false }
            }
            .sheet(isPresented: $showingHistory) {
                NavigationStack { TrackerHistoryImportView(makeSession: makeHistoryImport) }
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
        case .authorizing:
            loadingStatus
            Button("Cancel", role: .cancel) { service.cancelConnect() }
        case let .connecting(code, verificationURL, _):
            Text("Enter this code on WeTrakr:")
                .plozzForeground(.secondary)
            Text(code)
                .font(.title2.monospaced().weight(.semibold))
                .textSelection(.enabled)
            if let url = URL(string: verificationURL) {
                Button("Open WeTrakr") { openURL(url) }
            }
            Button("Cancel", role: .cancel) { service.cancelConnect() }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Compare with server history") { showingHistory = true }
                .accessibilityIdentifier("wetrakr.compare-history")
            Button("Disconnect", role: .destructive) { Task { await service.disconnect() } }
        case let .error(message):
            errorStatus(message)
            Button("Connect WeTrakr", action: connect)
        case let .syncError(message, canReconnect):
            errorStatus(message)
            Button("Retry") { Task { await service.refreshStatus() } }
            if canReconnect {
                Button("Reconnect WeTrakr") { confirmingReconnect = true }
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
    let makeHistoryImport: @MainActor () -> TrackerHistoryImportSession
    @Environment(\.openURL) private var openURL
    @State private var showingHistory = false

    var body: some View {
        Group { content }
            .onChange(of: service.phase) { _, _ in
                if service.historyConnectionID == nil { showingHistory = false }
            }
            .sheet(isPresented: $showingHistory) {
                NavigationStack { TrackerHistoryImportView(makeSession: makeHistoryImport) }
            }
    }

    @ViewBuilder private var content: some View {
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
            }
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Compare with server history") { showingHistory = true }
                .accessibilityIdentifier("simkl.compare-history")
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
        case let .error(message):
            errorStatus(message)
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect Simkl") {
            service.connect()
        }
    }
}

private struct AniListSettingsContent: View {
    let service: AniListService
    let makeHistoryImport: @MainActor () -> TrackerHistoryImportSession
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var showingHistory = false

    var body: some View {
        Group { content }
            .onChange(of: service.phase) { _, _ in
                if service.historyConnectionID == nil { showingHistory = false }
            }
            .sheet(isPresented: $showingHistory) {
                NavigationStack { TrackerHistoryImportView(makeSession: makeHistoryImport) }
            }
    }

    @ViewBuilder private var content: some View {
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
            Button("Compare with server history") { showingHistory = true }
                .accessibilityIdentifier("anilist.compare-history")
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
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
        }
        TextField("Authorization code", text: $code)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        Button(submitButtonTitle, action: submit)
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel", role: .cancel) {
            service.cancelConnect()
        }
    }
}

private struct MALSettingsContent: View {
    let service: MALService
    let makeHistoryImport: @MainActor () -> TrackerHistoryImportSession
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var showingHistory = false

    var body: some View {
        Group { content }
            .onChange(of: service.phase) { _, _ in
                if service.historyConnectionID == nil { showingHistory = false }
            }
            .sheet(isPresented: $showingHistory) {
                NavigationStack { TrackerHistoryImportView(makeSession: makeHistoryImport) }
            }
    }

    @ViewBuilder private var content: some View {
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
            }
            TextField("Authorization code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Redeem Code") {
                service.submitAuthorizationCode(code)
            }
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Compare with server history") { showingHistory = true }
                .accessibilityIdentifier("mal.compare-history")
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
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
