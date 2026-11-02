#if canImport(UIKit)
import OSLog
import UIKit

/// Serializes compression away from the main-actor artwork resolver.
public actor TopShelfArtworkEncoder {
    public static let shared = TopShelfArtworkEncoder()

    public enum Format: Sendable {
        case png
        case jpeg
    }

    private let encode: @Sendable (UIImage, Format) -> Data?

    init(encode: @escaping @Sendable (UIImage, Format) -> Data? = { image, format in
        switch format {
        case .png: image.pngData()
        case .jpeg: image.jpegData(compressionQuality: 0.9)
        }
    }) {
        self.encode = encode
    }

    public func data(for image: UIImage, format: Format) -> Data? {
        guard !Task.isCancelled else { return nil }
        let data = autoreleasepool { encode(image, format) }
        guard !Task.isCancelled else { return nil }
        if data == nil {
            Logger(subsystem: "com.plozz.app", category: "top-shelf")
                .warning("Selected Top Shelf artwork could not be encoded.")
        }
        return data
    }
}
#endif
