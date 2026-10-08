#if canImport(SwiftUI)
import SwiftUI
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders a QR code for an arbitrary string using CoreImage. tvOS has no
/// browser, so a scannable code is how Plozz hands a URL off to a phone (used
/// by both the About community links and the Report a Problem flow).
///
/// The generated image is nearest-neighbour scaled so the code stays crisp at
/// display size. `correctionLevel` trades error-resilience for density: use
/// `.high` for short URLs (About community links) and `.medium` for longer pre-filled URLs
/// (the GitHub issue link) so the code stays scannable on a TV at ~10 feet.
struct SettingsQRCode: View {
    let string: String
    var correctionLevel: QRCodeCorrectionLevel = .high
    var centerMark: String? = "GitHubMark"

    var body: some View {
        Group {
            #if canImport(UIKit)
            QRCodeView(string, correctionLevel: correctionLevel)
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous))
                .overlay {
                    if let centerMark {
                        Image(centerMark)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            #else
            placeholder
            #endif
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
            .fill(Color.secondary.opacity(0.2))
    }
}
#endif
