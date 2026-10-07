#if canImport(SwiftUI) && canImport(CoreImage)
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreNetworking

public enum QRCodeCorrectionLevel: String, Sendable {
    case low = "L"
    case medium = "M"
    case quartile = "Q"
    case high = "H"
}

/// Renders a QR code for a string (typically a URL) so a user can scan it with a
/// phone instead of typing a code. Generated on-device with Core Image; no
/// network access.
///
/// Draw it on a light background — QR scanners expect dark modules on a light
/// field, so callers should place this over white (e.g. a white rounded card).
public struct QRCodeView: View {
    private let request: QRCodeImageRequest
    @State private var rendered: Rendered?

    private struct Rendered {
        let request: QRCodeImageRequest
        let image: CGImage
    }

    public init(
        _ content: String, correctionLevel: QRCodeCorrectionLevel = .medium,
        transparentBackground: Bool = false
    ) {
        request = QRCodeImageRequest(
            content: content, correctionLevel: correctionLevel,
            transparentBackground: transparentBackground
        )
    }

    public var body: some View {
        Group {
            if let rendered, rendered.request == request {
                Image(decorative: rendered.image, scale: 1)
                    .renderingMode(request.transparentBackground ? .template : .original)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .task(id: request, priority: .medium) {
            do {
                let image = try await QRCodeImageStore.shared.image(for: request)
                try Task.checkCancellation()
                rendered = Rendered(request: request, image: image)
            } catch is CancellationError {
                // A replaced or dismissed code must not publish its old pixels.
            } catch {
                PlozzLog.app.error("Unable to render QR code")
            }
        }
    }
}

struct QRCodeImageRequest: Hashable, Sendable {
    let content: String
    var correctionLevel: QRCodeCorrectionLevel = .medium
    var transparentBackground = false
}

/// Core Image initialization and rendering stay off the main actor. Only a
/// bounded in-memory set is retained; activation/pairing payloads never hit disk.
actor QRCodeImageStore {
    static let shared = QRCodeImageStore()
    private lazy var context = CIContext()
    private var images: [QRCodeImageRequest: CGImage] = [:]
    private var order: [QRCodeImageRequest] = []
    private var cost = 0
    private let maximumCost = 16 * 1_024 * 1_024
    private let capacity = 8

    enum RenderingError: Error { case unavailable }

    func image(for request: QRCodeImageRequest) throws -> CGImage {
        try Task.checkCancellation()
        if let image = images[request] {
            order.removeAll { $0 == request }
            order.append(request)
            return image
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(request.content.utf8)
        filter.correctionLevel = request.correctionLevel.rawValue
        guard var output = filter.outputImage else { throw RenderingError.unavailable }
        if request.transparentBackground {
            let colorize = CIFilter.falseColor()
            colorize.inputImage = output
            colorize.color0 = CIColor(red: 0, green: 0, blue: 0)
            colorize.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let mask = colorize.outputImage else { throw RenderingError.unavailable }
            output = mask
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            throw RenderingError.unavailable
        }
        try Task.checkCancellation()
        let imageCost = image.bytesPerRow * image.height
        if imageCost <= maximumCost {
            while !order.isEmpty && (order.count >= capacity || cost + imageCost > maximumCost) {
                if let removed = images.removeValue(forKey: order.removeFirst()) {
                    cost -= removed.bytesPerRow * removed.height
                }
            }
            images[request] = image
            order.append(request)
            cost += imageCost
        }
        return image
    }
}
#endif
