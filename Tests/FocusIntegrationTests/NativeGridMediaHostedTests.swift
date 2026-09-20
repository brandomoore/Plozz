#if os(tvOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import TVUIKit
import UIKit
import XCTest

@MainActor
final class NativeGridMediaHostedTests: XCTestCase {
    func testRealCollectionCellFocusEnlargesRenderedPosterWithoutProjectingCaption() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let url = URL(string: "https://native-grid-fixture.example.test/\(UUID().uuidString).png")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image {
            UIColor(red: 0.05, green: 0.25, blue: 0.9, alpha: 1).setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let requestURL = ArtworkImageVariant.posterCard.requestURL(for: url)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
            for: URLRequest(url: requestURL))
        let decoded = await ArtworkImageCache.shared.image(for: url, variant: .posterCard)
        XCTAssertNotNil(decoded)

        for style in [CardStyle.framed, .borderless] {
            let controller = GridController(style: style, artworkURL: url)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let cell = try XCTUnwrap(controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTVLibraryCell)
            let second = try XCTUnwrap(controller.collection.cellForItem(at: IndexPath(item: 1, section: 0)))
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            controller.focusedIndex = 1
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(second.isFocused)
            let rest = snapshot(window)
            let restPixels = try blueBounds(rest)

            controller.focusedIndex = 0
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(cell.isFocused, "UIKit, not a SwiftUI proxy or child lockup, must own focus.")
            XCTAssertNil(descendant(TVLockupView.self, in: cell))
            let media = try XCTUnwrap(descendant(TVMediaItemContentView.self, in: cell))
            let source = try XCTUnwrap(descendant(DetailTransitionSourceView.self, in: cell)?.reference)
            XCTAssertTrue(source.nativeArtworkView === media)
            let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: cell))
            XCTAssertFalse(caption.isDescendant(of: media))
            XCTAssertEqual(media.bounds.height / media.bounds.width, 1.5, accuracy: 0.02)
            let focused = snapshot(window)
            let focusedPixels = try blueBounds(focused)
            let projected = try XCTUnwrap(source.visibleFrame(in: window))
            XCTAssertEqual(projected.minX, focusedPixels.minX, accuracy: 2)
            XCTAssertEqual(projected.minY, focusedPixels.minY, accuracy: 2)
            XCTAssertEqual(projected.width, focusedPixels.width, accuracy: 2)
            XCTAssertEqual(projected.height, focusedPixels.height, accuracy: 2)
            XCTAssertGreaterThan(
                focusedPixels.width, restPixels.width + 10,
                "The actual painted image must grow; focus flags/guides alone are insufficient.")
            XCTAssertGreaterThan(focusedPixels.height, restPixels.height + 10)
            let captionFrame = caption.convert(caption.bounds, to: window)
            XCTAssertGreaterThanOrEqual(captionFrame.minY, focusedPixels.maxY - 1)
            for (name, image) in [("rest", rest), ("focus", focused)] {
                let attachment = XCTAttachment(image: image)
                attachment.name = "native-grid-\(style)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            print("NATIVE_GRID_PIXELS \(style) rest=\(restPixels) focused=\(focusedPixels)")
        }
    }

    func testReuseClearsSelectionAndFocusEligibility() {
        let cell = NativeTVLibraryCell(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        cell.configure(
            item: MediaItem(id: "one", title: "One", kind: .movie),
            spoilerSettings: .default, environment: EnvironmentValues())
        XCTAssertTrue(cell.canBecomeFocused)
        cell.prepareForReuse()
        XCTAssertNil(cell.item)
        XCTAssertFalse(cell.canBecomeFocused)
        cell.configure(item: nil, spoilerSettings: .default, environment: EnvironmentValues())
        XCTAssertTrue(cell.canBecomeFocused)
        XCTAssertFalse(cell.accessibilityElementsHidden)
        XCTAssertTrue(cell.accessibilityTraits.contains(.notEnabled))
        XCTAssertNotNil(cell.accessibilityLabel)
    }

    func testNativeFolderAndSharedCaptionMetadata() throws {
        let cell = NativeTVLibraryCell(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        var environment = EnvironmentValues()
        environment.locale = Locale(identifier: "en")
        let folder = MediaItem(id: "folder", title: "Movies", kind: .folder)
        cell.configure(item: folder, spoilerSettings: .default, environment: environment)
        XCTAssertEqual(cell.accessibilityLabel, "Movies")
        XCTAssertEqual(cell.accessibilityValue, "Folder")
        XCTAssertEqual(cell.accessibilityHint, "Open folder")

        let movie = MediaItem(id: "movie", title: "Film", kind: .movie, productionYear: 2020, runtime: 3600, resumePosition: 600)
        let runtime = try XCTUnwrap(movie.cardRuntimeText)
        XCTAssertEqual(movie.posterCaptionSubtitle(), "2020 · \(runtime) left")
        XCTAssertEqual(movie.posterCaptionSubtitle(showsSubtitle: false), "\(runtime) left")
        XCTAssertEqual(movie.posterCaptionSubtitle(showsRuntime: false), "2020")
        XCTAssertNil(movie.posterCaptionSubtitle(showsSubtitle: false, showsRuntime: false))
        cell.configure(item: movie, spoilerSettings: .default, environment: environment)
        XCTAssertEqual(cell.accessibilityLabel, "Film")
        XCTAssertNil(cell.accessibilityHint)
        XCTAssertEqual(cell.accessibilityValue, movie.posterCaptionSubtitle())
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func blueBounds(_ image: UIImage) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        // Excludes the second card and the window's unrelated chrome.
        for y in 80..<min(height, 950) {
            for x in 80..<min(width, 560) {
                let offset = (y * width + x) * 4
                if pixels[offset + 2] > 130 && Int(pixels[offset + 2]) > Int(pixels[offset]) + 80
                    && Int(pixels[offset + 2]) > Int(pixels[offset + 1]) + 50
                {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX, "The fixture poster must be painted before measuring focus.")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func descendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}

@MainActor
private final class GridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    let collection: UICollectionView
    let artworkURL: URL
    var environment = EnvironmentValues()
    var focusedIndex = 0

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [collection] }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        IndexPath(item: focusedIndex, section: 0)
    }

    init(style: CardStyle, artworkURL: URL) {
        self.artworkURL = artworkURL
        environment.plozzCardStyle = style
        environment.plozzCardFocusStyle = .system
        environment.plozzMetrics = .standard
        environment.themePalette = .dark
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 300, height: NativeTVLibraryCell.height(for: 300, environment: environment))
        layout.minimumInteritemSpacing = 180
        layout.sectionInset = UIEdgeInsets(top: 120, left: 180, bottom: 120, right: 180)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(NativeTVLibraryCell.self, forCellWithReuseIdentifier: "poster")
        view.addSubview(collection)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collection.frame = view.bounds
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 2 }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
        (cell as? NativeTVLibraryCell)?.configure(
            item: MediaItem(id: "\(indexPath.item)", title: "Native library poster", kind: .movie, posterURL: artworkURL),
            spoilerSettings: .default, environment: environment
        )
        return cell
    }
}
#endif
