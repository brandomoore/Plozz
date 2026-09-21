#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI

struct SiloServerAddressView: View {
    let onContinue: (MediaServer) -> Void
    let onBack: () -> Void
    @State private var address = ""
    @State private var invalidAddress = false

    var body: some View {
        VStack(spacing: 28) {
            ProviderBrandMark(provider: .silo, size: 80, showsBackground: false)
            Text("Connect to Silo").font(.largeTitle)
            Text("Enter the address you use to open Silo in a browser.")
            TextField("Server address", text: $address)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .frame(maxWidth: 700)
            if invalidAddress { Text("Enter a valid server address.").foregroundStyle(.red) }
            Button("Continue") {
                guard let url = ServerURLNormalizer.normalize(address) else {
                    invalidAddress = true
                    return
                }
                onContinue(MediaServer(id: url.absoluteString, name: "Silo", baseURL: url, provider: .silo))
            }
            Button("Back", action: onBack)
        }
        .onExitCommand(perform: onBack)
        .padding(60)
    }
}
#endif
