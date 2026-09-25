#if os(iOS)
import CoreModels
import FeaturePlayback
import SwiftUI

/// The subtitle font picker, shared by the player's Style screen and Settings:
/// Plozz's curated typefaces, each named in its own face, then System Fonts for
/// the device's own.
struct PlozziOSSubtitleFontList: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        List {
            Section {
                ForEach(SubtitleFontFamily.allCases, id: \.self) { family in
                    Button {
                        style.fontFamily = family
                        style.installedFontFamily = nil
                        style.fontWeight = style.fontWeight.snapped(to: family.availableWeights)
                    } label: {
                        HStack {
                            Text(verbatim: family.displayName)
                                .font(subtitlePreviewFont(for: family))
                            Spacer()
                            if style.installedFontFamily == nil, family == style.fontFamily {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    PlozziOSSystemFontList(style: $style)
                } label: {
                    LabeledContent("System Fonts", value: style.installedFontFamily ?? "")
                }
            }
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every font family installed on the device, each named in its own face.
private struct PlozziOSSystemFontList: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        List(InstalledSubtitleFonts.families, id: \.self) { family in
            Button {
                style.installedFontFamily = family
                style.fontWeight = style.fontWeight.snapped(
                    to: InstalledSubtitleFonts.weights(forFamily: family)
                )
            } label: {
                HStack {
                    Text(verbatim: family)
                        .font(.custom(family, size: 20))
                    Spacer()
                    if family == style.installedFontFamily {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("System Fonts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A curated family's name in its own Regular face — named faces via their
/// PostScript name, SF via the system font, and SF Rounded via the rounded
/// system design.
func subtitlePreviewFont(for family: SubtitleFontFamily) -> Font {
    let size: CGFloat = family == .openDyslexic ? 17 : 22
    if family.usesRoundedDesign {
        return .system(size: size, design: .rounded)
    }
    if let name = family.postScriptNameCandidates().first {
        return .custom(name, size: size)
    }
    return .system(size: size)
}
#endif
