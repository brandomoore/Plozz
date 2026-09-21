#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureAuthCore

public struct SiloSignInView: View {
    @State private var model: SiloAuthViewModel
    private let onCancel: () -> Void

    public init(server: MediaServer, deviceID: String,
                onAuthenticated: @escaping (UserSession) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: SiloAuthViewModel(server: server, deviceID: deviceID, onAuthenticated: onAuthenticated))
        self.onCancel = onCancel
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ProviderBrandMark(provider: .silo, size: 76, showsBackground: false)
                Text("Connect to Silo").font(.largeTitle.bold())
                content
                Button("Cancel") { model.cancel(); onCancel() }
            }
            .frame(maxWidth: 800)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .task { if model.phase == .idle { model.start() } }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("Connecting…")
        case let .pairing(code, match, url, expiresAt):
            Text("Scan this code and approve Plozz in your Silo account.")
                .multilineTextAlignment(.center)
            BrandQRCodeView(payload: url.absoluteString, size: 240)
            Text(url.absoluteString).font(.callout)
            Text(code).font(.largeTitle.monospaced().bold())
            Text("Check that the confirmation code is \(match).")
            Text(expiresAt, style: .timer).monospacedDigit()
        case let .profiles(profiles):
            Text("Choose a Silo profile").font(.title2)
            Text("This profile controls library access and watch history.")
                .multilineTextAlignment(.center)
            ForEach(profiles) { profile in
                Button { model.select(profile) } label: {
                    Label(profile.name, systemImage: profile.has_pin ? "lock.fill" : "person.fill")
                }
            }
        case let .pin(profile):
            Text("Enter the PIN for \(profile.name)").font(.title2)
            SecureField("Profile PIN", text: $model.pin)
                .textContentType(.oneTimeCode)
                .frame(maxWidth: 400)
                .onSubmit { model.submitPIN(profile) }
            if let error = model.pinError { Text(error).foregroundStyle(.red) }
            Button("Continue") { model.submitPIN(profile) }
                .disabled(model.pin.isEmpty)
        case let .error(message):
            Text(message).multilineTextAlignment(.center)
            Button("Try Again") { model.start() }
        }
    }
}
#endif
