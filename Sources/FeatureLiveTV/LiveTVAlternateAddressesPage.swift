import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// Settings → Live TV → (source) → Backup server addresses: extra Xtream portal URLs
/// used for latency-based selection and automatic failover.
struct LiveTVAlternateAddressesPage: View {
    let model: LiveTVAlternateAddressesModel
    let accountID: String
    let sourceName: String
    @State private var address = ""

    var body: some View {
        LiveTVSettingsPage(title: "Backup server addresses", sourceName: sourceName) {
            let addresses = model.alternateAddresses(accountID: accountID) ?? []
            if !addresses.isEmpty {
                SettingsSectionGroup("Backup servers") {
                    ForEach(addresses, id: \.absoluteString) { url in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: url.absoluteString)
                                .lineLimit(2)
                                .privacySensitive()
                            Button(role: .destructive) {
                                model.remove(url, accountID: accountID)
                            } label: {
                                LiveTVSetupActionLabel(title: "Remove server address", symbol: "minus.circle")
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                            .accessibilityIdentifier("live-tv-remove-alternate-address")
                        }
                    }
                }
            }
            SettingsSectionGroup("Add a backup server") {
                LiveTVSetupField(
                    title: "Server address", text: $address, isAddress: true,
                    identifier: "live-tv-alternate-address-input", example: "https://backup.example.com"
                )
                Button {
                    if model.add(address, accountID: accountID) { address = "" }
                } label: {
                    LiveTVSetupActionLabel(title: "Add server address", symbol: "plus")
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || addresses.count >= LiveTVAlternateAddressesModel.maximumAlternateAddresses)
                .accessibilityIdentifier("live-tv-add-alternate-address")
                if let issue = model.issue { Text(issue.message) }
            } footer: {
                Text("Plozz automatically tests your configured server addresses to pick the fastest reachable server and fails over if one stops responding.")
            }
        }
        .onAppear {
            model.clearIssue()
            model.refresh()
        }
    }
}
