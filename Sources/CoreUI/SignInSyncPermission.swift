#if canImport(SwiftUI)
import SwiftUI

private struct SignInSyncPermission<Request: Identifiable & Equatable>: ViewModifier {
    let request: Request?
    let canPresent: Bool
    let sourceNames: (Request) -> String
    let resolve: (Request, Bool) -> Void
    @State private var displayed: Request?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: canPresent ? request : nil, initial: true) { _, pending in
                guard pending != displayed else { return }
                displayed = pending
                isPresented = pending != nil
            }
            .alert("Save Sign-ins to iCloud?", isPresented: $isPresented, presenting: displayed) { pending in
                Button("Keep on This Device", role: .cancel) { resolve(pending, false) }
                Button("Save to iCloud") { resolve(pending, true) }
            } message: { pending in
                Text("Save these sign-ins to this device's iCloud account to sign in automatically on your other devices. Check the account in system Settings.\n\n\(sourceNames(pending))",
                     comment: "Permission to upload existing server credentials; the substitution lists the affected sources.")
            }
    }
}

public extension View {
    func signInSyncPermission<Request: Identifiable & Equatable>(
        _ request: Request?,
        canPresent: Bool,
        sourceNames: @escaping (Request) -> String,
        resolve: @escaping (Request, Bool) -> Void
    ) -> some View {
        modifier(SignInSyncPermission(
            request: request, canPresent: canPresent, sourceNames: sourceNames, resolve: resolve))
    }
}
#endif
