#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// Shared entry point; platforms retain their own grid and scrolling machinery.
public struct LibraryAlphabetMenu: View {
    let entries: [LibraryLetterIndexEntry]
    let isLoading: Bool
    let onSelect: (String) -> Void
    let onRetry: () -> Void

    public init(entries: [LibraryLetterIndexEntry], isLoading: Bool,
                onSelect: @escaping (String) -> Void, onRetry: @escaping () -> Void) {
        self.entries = entries
        self.isLoading = isLoading
        self.onSelect = onSelect
        self.onRetry = onRetry
    }

    public var body: some View {
        Menu {
            ForEach(entries, id: \.letter) { entry in
                Button(entry.letter) { onSelect(entry.letter) }
                    .accessibilityLabel("Jump to \(entry.letter)")
            }
            if entries.isEmpty {
                Button("Retry alphabet index", action: onRetry)
            }
        } label: {
            Label("Jump to letter", systemImage: "textformat.abc")
        }
        .disabled(isLoading)
        .accessibilityIdentifier("library-alphabet-menu")
    }
}

public struct LibraryAlphabetStatus: View {
    let letter: String?
    let message: LocalizedStringResource?
    let onCancel: () -> Void

    public init(letter: String?, message: LocalizedStringResource?, onCancel: @escaping () -> Void) {
        self.letter = letter
        self.message = message
        self.onCancel = onCancel
    }

    public var body: some View {
        if let letter {
            HStack(spacing: 18) {
                ProgressView("Finding \(letter)…")
                Button("Cancel", action: onCancel)
            }
            .padding()
        } else if let message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}
#endif
