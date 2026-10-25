import CoreModels
import CoreNetworking
import CoreUI
@testable import FeatureSettings
import Foundation
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBPairingFixture: View {
    @State private var navigation = SettingsPageNavigation<Int>()
    @State private var service = PublicMetaDBService(
        credentials: PairingFixtureCredentials(),
        http: PairingFixtureHTTP(
            unavailable: ProcessInfo.processInfo.arguments.contains("--pairing-unavailable")
        ),
        namespace: "publicmetadb-focus-fixture"
    )

    var body: some View {
        SettingsPageStack(
            navigation: navigation, pageWidth: SettingsFormMetrics.pageWidth, onRootBack: {}
        ) {
            SettingsPageLink {
                SettingsFormRowPage(row: SettingsSplitRow(
                    id: "publicmetadb", verbatimTitle: "PublicMetaDB"
                ) {
                    PublicMetaDBSettingsContent(service: service)
                })
            } label: {
                Text("PublicMetaDB")
            }
            .accessibilityIdentifier("fixture.open-publicmetadb")
        } destination: { _ in
            EmptyView()
        }
        .safeAreaPadding(.top, 36)
        .ignoresSafeArea(.container, edges: .vertical)
        .buttonStyle(SettingsFocusButtonStyle())
        .environment(\.settingsInWorkspace, true)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .background(ThemePalette.dark.settingsBackground)
    }
}

private struct PairingFixtureCredentials: PublicMetaDBCredentialStoring {
    func load(namespace: String?) -> PublicMetaDBCredentials? { nil }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {}
    func clear(namespace: String?) throws {}
}

private struct PairingFixtureHTTP: HTTPClient {
    let unavailable: Bool

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let status: Int
        let data: Data
        switch (endpoint.method, endpoint.path) {
        case (.post, "/api/publicmetadb/pairing"):
            try await Task.sleep(for: .milliseconds(500))
            if unavailable { throw AppError.invalidResponse }
            status = 201
            data = try JSONSerialization.data(withJSONObject: [
                "code": "ABCDEFGH",
                "expiresAt": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000
            ])
        case (.post, "/api/publicmetadb/pairing/ABCDEFGH/redeem"):
            status = 202
            data = Data()
        case (.delete, "/api/publicmetadb/pairing/ABCDEFGH"):
            status = 204
            data = Data()
        case (.get, "/api/external/lists"):
            status = 200
            data = Data(#"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#.utf8)
        default:
            throw AppError.invalidResponse
        }
        guard let response = HTTPURLResponse(
            url: baseURL, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { throw AppError.invalidResponse }
        return (data, response)
    }
}
