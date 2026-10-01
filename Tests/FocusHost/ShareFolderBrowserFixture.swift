import CoreUI
import FeatureShareOnboarding
import MediaTransportHTTP
import MediaTransportWebDAV
import SwiftUI
@testable import AppShell

struct ShareFolderBrowserFixture: View {
    @State private var model = UnifiedAddShareModel(webDAVProbe: FolderNavigationProbe())
    @State private var savedContent: String?

    var body: some View {
        UnifiedAddShareView(
            isPageReady: false, onBack: {},
            onSMBConfigured: { _ in },
            onWebDAVConfigured: { savedContent = $0.libraryConfiguration?.contentType.rawValue },
            viewModel: model
        )
        .environment(\.themePalette, .pureBlack)
        .preferredColorScheme(.dark)
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            if let savedContent {
                Text(savedContent).accessibilityIdentifier("saved-share-content")
            }
        }
        .task {
            model.openManualConnect()
            model.applyTransport(.webDAV)
            model.address = "https://fixture.example.test/Movies"
            model.connect()
        }
    }
}

private struct FolderNavigationProbe: WebDAVOnboardingProbing {
    func preflightTrust(url: URL) async -> WebDAVTrustPreflight { .systemTrusted }

    func validate(
        url: URL, credential: WebDAVCredential, trust: WebDAVOnboardingTrust
    ) async -> Result<Void, WebDAVOnboardingError> {
        .success(())
    }

    func listFolders(
        url: URL, path: String, credential: WebDAVCredential, trust: WebDAVOnboardingTrust
    ) async -> Result<[WebDAVOnboardingFolder], WebDAVOnboardingError> {
        .success((0..<1_551).map {
            let name = String(format: "Movie %04d (2026)", $0)
            return WebDAVOnboardingFolder(path: "\(path)/\(name)", name: name)
        })
    }
}
