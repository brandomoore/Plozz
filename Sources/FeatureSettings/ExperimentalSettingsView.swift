#if os(tvOS)
import CoreUI
import SwiftUI

/// Manage Plozz › Experimental: features that are still being tested.
///
/// The page opens with one notice saying what to expect. Features are listed
/// beneath it; while there are none, a single line says so.
struct ExperimentalSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsFormMetrics.controlSpacing) {
                SettingsPageHeader("Experimental")
                // The notice takes focus: a page with nothing focusable leaves the
                // remote with nowhere to land, and its Back button never unlocks.
                ExperimentalSettingsNotice()
                    .settingsWorkspaceEntry()
                Text("Nothing to try right now.",
                     comment: "Shown on the Settings › Experimental page while it lists no experimental features.")
                    .settingsHelperText()
                    .padding(.horizontal, SettingsFormMetrics.pageInset)
                    .accessibilityIdentifier("settings-experimental-empty")
            }
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
        }
        .scrollClipDisabled()
    }
}

/// What to expect from everything on the Experimental page.
private struct ExperimentalSettingsNotice: View {
    var body: some View {
        FocusableSettingsPanel {
            HStack(alignment: .top, spacing: PlozzTheme.Spacing.medium) {
                Image(systemName: "flask")
                    .font(.system(size: 34, weight: .regular))
                    .plozzForeground(.secondary)
                    .frame(width: 48, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PlozzTheme.Spacing.xSmall) {
                    Text("Try new features early",
                         comment: "Heading of the notice at the top of Settings › Experimental, the page that lists features still being tested.")
                        .font(.headline)
                    Text("These are still being tested. They may change, break or be removed, and support is limited or not available.",
                         comment: "Notice at the top of Settings › Experimental. “These” are the experimental features listed on that page.")
                        .font(SettingsRowMetrics.helperFont)
                        .plozzForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("settings-experimental-notice")
    }
}
#endif
