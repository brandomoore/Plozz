#if os(iOS)
import CoreModels
import FeatureHomeCore
import SwiftUI

struct PlozziOSPlayerVersionSheet: View {
    let item: MediaItem
    let mediaSourceID: String?
    var onlySDR = false
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(onlySDR
                        ? PlayerVersionSelection.sdrAlternatives(for: item, mediaSourceID: mediaSourceID)
                        : PlayerVersionSelection.versions(for: item)) { version in
                        let selected = PlayerVersionSelection.isSelected(version, item: item, mediaSourceID: mediaSourceID)
                        Button {
                            dismiss()
                            if !selected { onSelect(version.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let label = version.displayLabel {
                                        Text(verbatim: label)
                                    } else {
                                        Text("Original")
                                    }
                                    if let name = version.fileName {
                                        Text(verbatim: name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if selected { Image(systemName: "checkmark") }
                            }
                            .foregroundStyle(.primary)
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                } footer: {
                    Text("Resumes at the current position. Different cuts may have different timing.")
                }
            }
            .navigationTitle(onlySDR ? "SDR versions" : "Version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
