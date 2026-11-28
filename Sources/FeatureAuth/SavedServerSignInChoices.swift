#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The ordinary form stays mounted and starts immediately. A bounded footer
/// offers verified alternatives without adding another scroll or navigation step.
public struct SavedServerSignInChoices<Fresh: View>: View {
    let accounts: [Account]
    let use: (Account) throws -> Void
    let fresh: Fresh
    @State private var failed = false

    public init(
        accounts: [Account], use: @escaping (Account) throws -> Void, @ViewBuilder fresh: () -> Fresh
    ) {
        self.accounts = accounts
        self.use = use
        self.fresh = fresh()
    }

    public var body: some View {
        fresh.safeAreaInset(edge: .bottom, spacing: 0) {
            if !accounts.isEmpty {
                VStack(spacing: PlozzTheme.Spacing.small) {
                    if accounts.count <= 2 {
                        actions.buttonStyle(.bordered)
                    } else {
                        Menu("Saved Sign-ins") { actions }
                    }
                    if failed {
                        Text("This saved sign-in is unavailable. Sign in again.")
                            .font(.footnote)
                    }
                }
                .padding(.vertical, PlozzTheme.Spacing.small)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var actions: some View {
        ForEach(accounts) { account in
            Button("Sign in as \(account.userName)") {
                do { try use(account) } catch { failed = true }
            }
        }
    }
}
#endif
