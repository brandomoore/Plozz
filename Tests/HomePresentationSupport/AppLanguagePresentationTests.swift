import CoreModels
import CoreUI
import CoreText
import SwiftUI
import UIKit
import XCTest

private struct LanguagePresentationProbe: View {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var direction
    let update: (Locale, LayoutDirection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings").font(.title)
            Text("Language")
            HStack {
                Button("Play") {}
                Button("Cancel") {}
            }
            .buttonStyle(.plain)
            .tint(.primary)
            ForEach([0, 1, 2, 5], id: \.self) { count in
                Text("\(count) episodes")
            }
        }
        .padding(32)
        .onChange(of: locale, initial: true) { _, value in
            update(value, direction)
        }
        .onChange(of: direction) { _, value in
            update(locale, value)
        }
    }
}

@MainActor
final class AppLanguagePresentationTests: XCTestCase {
    func testBengaliAndUrduBundleCopyAndGlyphCoverage() throws {
        for code in ["bn", "ur"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertTrue(AppLanguage.available().contains(.explicit(code)))
            for key in ["Settings", "Language", "Play", "Cancel"] {
                let text = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(text, key, "\(code): \(key) must not fall back to English.")
                let script: ClosedRange<UInt32> = code == "bn" ? 0x0980...0x09FF : 0x0600...0x06FF
                XCTAssertTrue(text.unicodeScalars.contains { script.contains($0.value) }, "\(code): \(key)")
                let attributed = NSAttributedString(
                    string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
                )
                let line = CTLineCreateWithAttributedString(attributed)
                let runs = try XCTUnwrap(CTLineGetGlyphRuns(line) as? [CTRun])
                for run in runs {
                    var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    XCTAssertFalse(glyphs.contains(0), "Missing glyph in \(code): \(key)")
                }
            }
        }
    }

    func testLiveBengaliUrduSwitchPreservesScopeAndMirrorsUrdu() async throws {
        let suite = "LanguagePresentation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppLanguageSettingsStore(defaults: defaults)
        store.save(.explicit("en"))
        let model = AppLanguageSettingsModel(store: store)
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        #if os(tvOS)
        window.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        #else
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        #endif
        var observedLocale: Locale?
        var observedDirection: LayoutDirection?
        let controller = UIHostingController(rootView:
            AppLanguageScope(model: model) {
                LanguagePresentationProbe {
                    observedLocale = $0
                    observedDirection = $1
                }
            }
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, .leftToRight)
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for code in ["bn", "ur", "bn"] {
            model.language = .explicit(code)
            let updateDeadline = ContinuousClock.now + .seconds(3)
            while (observedLocale?.language.languageCode?.identifier != code
                || observedDirection != (code == "ur" ? .rightToLeft : .leftToRight)),
                  ContinuousClock.now < updateDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            window.layoutIfNeeded()
            XCTAssertEqual(observedLocale?.language.languageCode?.identifier, code)
            XCTAssertEqual(observedDirection, code == "ur" ? .rightToLeft : .leftToRight)
            XCTAssertEqual(store.load(), .explicit(code))
            XCTAssertTrue(window.rootViewController === controller)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "language-scope-\(code)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
