#if os(iOS)
import AniListService
import CoreUI
import MALService
import SimklService
import SwiftUI
import TraktService
import WetrakrService

struct PlozziOSTrackerSettingsView: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        List {
            Text(
                """
                Connections are stored separately for each Plozz profile. \
                Playback progress is sent to every connected tracker.
                """
            )
            .font(.footnote)
            .plozzForeground(.secondary)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            SettingsSectionGroup(verbatim: "Trakt") {
                TraktSettingsContent(service: appModel.traktService)
            }

            SettingsSectionGroup(verbatim: "Simkl") {
                SimklSettingsContent(service: appModel.simklService)
            }
            if appModel.wetrakrService.isConfigured {
                SettingsSectionGroup(verbatim: "WeTrakr") {
                    WetrakrSettingsContent(service: appModel.wetrakrService)
                }
            }

            SettingsSectionGroup(verbatim: "AniList") {
                AniListSettingsContent(service: appModel.anilistService)
            }

            SettingsSectionGroup(verbatim: "MyAnimeList") {
                MALSettingsContent(service: appModel.malService)
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
            if canReconnect {
                Button("Reconnect Trakt") { confirmingReconnect = true }
                    .settingsActionRow()
            }
        }
    }

    private var connectButton: some View {
        Button("Connect Trakt", action: connect)
            .settingsActionRow()
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
            .onChange(of: service.phase) { _, _ in confirmingReconnect = false }
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
        case let .syncError(message, canReconnect):
            errorStatus(message)
            Button("Retry") { Task { await service.refreshStatus() } }
                .settingsActionRow()
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
    Label("Connected as \(username)", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
}

private func errorStatus(_ message: LocalizedStringResource) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
}
#endif
