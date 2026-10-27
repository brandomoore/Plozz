import SwiftUI
import CoreModels
import CoreUI
import FeatureAuthCore

public struct AccountReauthenticationView<ManagedSignIn: View>: View {
    @State private var model: AccountReauthenticationModel
    @State private var attempt = 0
    private let onCancel: () -> Void
    private let managedSignIn: (AccountReauthenticationModel) -> ManagedSignIn

    public init(
        model: AccountReauthenticationModel, onCancel: @escaping () -> Void,
        @ViewBuilder managedSignIn: @escaping (AccountReauthenticationModel) -> ManagedSignIn
    ) {
        _model = State(initialValue: model)
        self.onCancel = onCancel
        self.managedSignIn = managedSignIn
    }

    public var body: some View {
        ZStack {
            if let error = model.errorMessage {
                AccountRecoveryScreen(
                    provider: model.account.server.provider, name: model.account.userName,
                    message: error,
                    onRetry: {
                        model.retry()
                        attempt += 1
                    },
                    onCancel: cancel
                )
            } else {
                if model.account.server.provider == .plex {
                    PlexReauthenticationLink(model: model, onCancel: cancel)
                        .id(attempt)
                } else {
                    managedSignIn(model)
                        .id(attempt)
                }
            }
        }
        .onDisappear { model.cancel() }
        #if os(tvOS)
        .plozzDialogSurface()
        .onExitCommand(perform: cancel)
        #endif
    }

    private func cancel() {
        model.cancel()
        onCancel()
    }
}

private struct PlexReauthenticationLink: View {
    @State private var viewModel: PlexAuthViewModel
    let onCancel: () -> Void

    init(model: AccountReauthenticationModel, onCancel: @escaping () -> Void) {
        _viewModel = State(initialValue: PlexAuthViewModel(
            service: PlexAuthService(deviceID: model.deviceID),
            reconnectingAccount: model.account,
            onAuthenticated: model.complete
        ))
        self.onCancel = onCancel
    }

    var body: some View {
        PlexAccountLinkView(viewModel: viewModel, onCancel: onCancel)
    }
}
