#if os(iOS)
import CoreModels
import CoreUI
import FeatureSyncSetup
import SwiftUI

/// Retain the accepted offer through progress, failure and completion, including
/// when another root presentation becomes eligible while setup is in flight.
@MainActor
struct PlozziOSSyncSetupOfferPresenter: ViewModifier {
    let appModel: PlozziOSAppModel
    let canPresent: Bool
    var makeModel: (() -> SyncSetupPairingModel)?
    @State private var activeOffer: SyncPairingRendezvous?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: appModel.pendingSyncSetupOffer, initial: true) { _, _ in presentIfReady() }
            .onChange(of: canPresent) { _, _ in presentIfReady() }
            .plozzFullScreenCover(item: Binding(
                get: { isPresented ? activeOffer : nil },
                set: { if $0 == nil { isPresented = false } }
            ), onDismiss: {
                if let activeOffer { appModel.declineSyncSetupOffer(activeOffer) }
                activeOffer = nil
                presentIfReady()
            }) { offer in
                PlozziOSSyncSetupSendFlow(
                    appModel: appModel, request: .offer(offer), model: makeModel?()
                ) {
                    isPresented = false
                }
            }
    }

    private func presentIfReady() {
        guard canPresent, activeOffer == nil, let offer = appModel.pendingSyncSetupOffer else { return }
        activeOffer = offer
        isPresented = true
    }
}

@MainActor
struct PlozziOSSyncSetupSendFlow: View {
    enum Request {
        case offer(SyncPairingRendezvous)
        case link(String)
    }

    let appModel: PlozziOSAppModel
    let request: Request
    let onClose: () -> Void
    @State private var model: SyncSetupPairingModel
    @State private var started = false
    @State private var sendTask: Task<Void, Never>?

    init(appModel: PlozziOSAppModel, request: Request, model: SyncSetupPairingModel? = nil,
         onClose: @escaping () -> Void) {
        self.appModel = appModel
        self.request = request
        self.onClose = onClose
        _model = State(initialValue: model ?? appModel.makeSyncSetupSender())
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Set Up Device")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.phase != .sent {
                            Button("Cancel", systemImage: "xmark", action: close)
                                .accessibilityIdentifier("setup-send-cancel")
                        }
                    }
                }
        }
        .interactiveDismissDisabled()
        .onAppear {
            if case .link = request { startSending() }
        }
        .onChange(of: model.canSend, initial: true) { _, _ in model.authorizationDidChange() }
        .onDisappear {
            sendTask?.cancel()
            model.cancelSending()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            if case .offer(let offer) = request {
                offerConfirmation(offer)
            } else {
                ProgressView()
            }
        case .sent:
            SyncSetupSentSuccessView(
                accounts: appModel.accounts.filter { requestedAccountID == nil || $0.id == requestedAccountID },
                profiles: requestedAccountID == nil ? appModel.profiles.profiles : [],
                onDone: close
            )
        case .confirmingSAS(let code):
            ScrollView {
                SyncSetupSASConfirmView(code: code) { model.confirmSASMatch($0) }
                    .padding(24)
            }
            .defaultScrollAnchor(.center, for: .alignment)
        case .failed(let message):
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle).foregroundStyle(.orange)
                    Text("Setup didn’t finish").font(.title3.bold())
                    Text(message).plozzForeground(.secondary).multilineTextAlignment(.center)
                    Text("If the other device shows a new setup code, close this screen and start again with the new code.")
                        .font(.footnote).plozzForeground(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") {
                        started = false
                        model.reset()
                        startSending()
                    }
                    .disabled(!model.canSend)
                    .syncPrimaryButtonStyle()
                    .accessibilityIdentifier("setup-send-retry")
                }
                .padding(24)
            }
            .defaultScrollAnchor(.center, for: .alignment)
        default:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Setting up the other device…")
                    .font(.headline).plozzForeground(.secondary)
            }
            .padding(24)
        }
    }

    private var requestedAccountID: String? {
        if case .offer(let offer) = request { return offer.requestedAccountID }
        return nil
    }

    private func offerConfirmation(_ offer: SyncPairingRendezvous) -> some View {
        let server = offer.requestedAccountID.flatMap { id in appModel.accounts.first { $0.id == id }?.server.name }
        let title: LocalizedStringResource = if let server {
            "Set up “\(server)” on “\(offer.deviceName)”?"
        } else {
            "Set up “\(offer.deviceName)”?"
        }
        let message: LocalizedStringResource = if let server {
            "Sign this device in to “\(server)”."
        } else {
            "Send your servers and sign-in so it’s ready to watch."
        }
        return ScrollView {
            VStack(spacing: 24) {
                Text(title).font(.title2.bold())
                Text(message).plozzForeground(.secondary)
                Button("Set Up", action: startSending)
                    .disabled(!model.canSend)
                    .syncPrimaryButtonStyle()
                    .accessibilityIdentifier("setup-send-confirm")
                Button("Not Now", role: .cancel, action: close)
            }
            .multilineTextAlignment(.center)
            .padding(24)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }

    private func startSending() {
        guard !started, model.canSend else { return }
        started = true
        sendTask = Task {
            switch request {
            case .offer(let offer): await model.adopt(offer)
            case .link(let invite): await model.send(deepLink: invite)
            }
        }
    }

    private func close() {
        sendTask?.cancel()
        model.cancelSending()
        onClose()
    }
}
#endif
