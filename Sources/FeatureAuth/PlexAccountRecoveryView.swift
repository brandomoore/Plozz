import SwiftUI
import CoreModels
import CoreUI
import FeatureAuthCore

/// Keeps account linking inside the unresolved profile gate, not behind it in Settings.
public struct PlexAccountRecoveryView: View {
    private let name: String
    private let message: LocalizedStringResource
    private let signIn: PlexAuthViewModel?
    private let onSignIn: () -> Void
    private let onRetry: () -> Void
    private let onCancel: () -> Void
    private let onCancelSignIn: () -> Void

    public init(
        name: String,
        message: LocalizedStringResource,
        signIn: PlexAuthViewModel?,
        onSignIn: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onCancelSignIn: @escaping () -> Void
    ) {
        self.name = name
        self.message = message
        self.signIn = signIn
        self.onSignIn = onSignIn
        self.onRetry = onRetry
        self.onCancel = onCancel
        self.onCancelSignIn = onCancelSignIn
    }

    public var body: some View {
        if let signIn {
            PlexAccountLinkView(viewModel: signIn, onCancel: onCancelSignIn)
        } else {
            AccountRecoveryScreen(
                provider: .plex, name: name, message: message,
                onSignIn: onSignIn, onRetry: onRetry, onCancel: onCancel
            )
            .accessibilityIdentifier("plex-account-recovery")
        }
    }
}

public struct PlexAccountLinkView: View {
    let viewModel: PlexAuthViewModel
    let onCancel: () -> Void

    public init(viewModel: PlexAuthViewModel, onCancel: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onCancel = onCancel
    }

    public var body: some View {
        #if os(iOS)
        PlexMobileRecoveryLinkView(viewModel: viewModel, onCancel: onCancel)
        #else
        PlexLinkView(viewModel: viewModel, onCancel: onCancel)
        #endif
    }
}

#if os(iOS)
private struct PlexMobileRecoveryLinkView: View {
    let viewModel: PlexAuthViewModel
    let onCancel: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                switch viewModel.phase {
                case .idle, .requesting:
                    ProgressView("Requesting a Plex link code…")
                case let .awaitingLink(code, authorizationURL, _):
                    Section("Link your Plex account") {
                        Text(verbatim: code)
                            .font(.largeTitle.monospaced())
                            .frame(maxWidth: .infinity)
                            .textSelection(.enabled)
                        Button("Open Plex to link") { openURL(authorizationURL) }
                    }
                case .loadingServers, .selectingServer:
                    ProgressView("Loading your Plex servers…")
                case let .error(message):
                    Text(message)
                    Button("Try Again") { viewModel.retry() }
                }
            }
            .settingsPageSurface()
            .navigationTitle("Sign In Again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
                }
            }
        }
        .onAppear { viewModel.startIfNeeded() }
        .onDisappear { viewModel.cancel() }
    }
}
#endif
