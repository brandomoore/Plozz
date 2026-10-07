import CoreModels
import CoreUI
import FeatureAuth
import SwiftUI

struct IPTVSetupFixture: View {
    private let mode: IPTVCredential.Mode
    private let address: String
    private let session: UserSession?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        mode = arguments.contains("--xtream") ? .xtream : .playlist
        address = arguments.contains("--http-playlist") ? "http://playlist.example.test/channels.m3u" : ""
        if arguments.contains("--reconnect") {
            do {
                let url = URL(string: "https://playlist.example.test/channels.m3u")!
                let credential = try IPTVCredential(
                    mode: .playlist, address: url, headers: ["Authorization": "Bearer fixture"]
                )
                session = UserSession(
                    server: .init(id: "fixture", name: "Fixture playlist", baseURL: url, provider: .iptv),
                    userID: "fixture", userName: "IPTV", deviceID: "fixture",
                    accessToken: try credential.encoded()
                )
            } catch {
                fatalError("Invalid IPTV setup fixture: \(error)")
            }
        } else {
            session = nil
        }
    }

    var body: some View {
        NavigationStack {
            IPTVSignInView(
                deviceID: "fixture", address: address, reconnecting: session, initialMode: mode,
                onAuthenticated: { _ in fatalError("The setup fixture must not connect.") },
                onCancel: {}
            )
        }
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        .environment(\.plozzMetrics, .touch(density: .standard))
        #endif
    }
}
