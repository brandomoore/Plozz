#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import SeerService
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import FeatureSettings

@MainActor
final class ProfileSeerrSetupPresentationTests: XCTestCase {
    func testConnectedSetupKeepsPageGuttersAndOnlyShowsSavedAccounts() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 320, height: 568),
                     CGSize(width: 768, height: 1024), CGSize(width: 844, height: 390)] {
            try await render(size: size) { window, scroll, _ in
                let image = try self.capture(window)
                self.attach(image, name: "Seerr connected \(Int(size.width))x\(Int(size.height))")
                let text = try self.recognize(image, size: size)
                let title = try XCTUnwrap(text.first { $0.text.localizedCaseInsensitiveContains("Seerr") })
                XCTAssertTrue(text.contains { $0.text == "Home" })
                XCTAssertGreaterThanOrEqual(title.frame.minX, 20)
                XCTAssertLessThanOrEqual(title.frame.maxX, size.width - 23)
                XCTAssertFalse(title.text.contains("—"))
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                XCTAssertTrue(text.contains { $0.text.contains("Alex") })
                let account = try XCTUnwrap(text.first { $0.text.contains("Alex") })
                try self.assertPanelGutters(image, rowY: account.frame.midY)
                XCTAssertFalse(text.contains { $0.text == "Sam" })
                XCTAssertFalse(text.contains { $0.text.contains("Choose whose") })
                XCTAssertFalse(text.contains { $0.text == "Add account" || $0.text == "Ask each time" })
                try await self.scrollToBottom(scroll, window: window)
                let bottom = try self.capture(window)
                self.attach(bottom, name: "Seerr actions \(Int(size.width))x\(Int(size.height))")
                let bottomText = try self.recognize(bottom, size: size)
                XCTAssertTrue(bottomText.contains { $0.text == "Continue" })
                for line in bottomText {
                    XCTAssertGreaterThanOrEqual(line.frame.minX, 20, line.text)
                    XCTAssertLessThanOrEqual(line.frame.maxX, size.width - 23, line.text)
                }
            }
        }
    }

    func testLongNamesAndAccessibilityTextStayScrollableWithoutHorizontalOverflow() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            try await render(
                size: .init(width: 390, height: 844), typeSize: .accessibility3,
                direction: direction, longNames: true
            ) { window, scroll, _ in
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                self.attach(try self.capture(window), name: "Seerr large text top \(direction)")
                try await self.scrollToBottom(scroll, window: window)
                let image = try self.capture(window)
                self.attach(image, name: "Seerr large text actions \(direction)")
                let text = try self.recognize(image, size: window.bounds.size)
                XCTAssertTrue(text.contains { $0.text == "Continue" })
                XCTAssertFalse(text.contains { $0.text.contains("…") })
                for line in text {
                    XCTAssertGreaterThanOrEqual(line.frame.minX, 23, line.text)
                    XCTAssertLessThanOrEqual(line.frame.maxX, 367, line.text)
                }
            }
        }
    }

    func testDisconnectedAndFailedConnectionsKeepAnExplicitRecoveryPath() async throws {
        for state in [SeerrSetupHTTP.State.unconfigured, .differentProfile, .failed] {
            try await render(size: .init(width: 390, height: 844), state: state) { window, scroll, _ in
                let image = try self.capture(window)
                self.attach(image, name: "Seerr \(state)")
                let text = try self.recognize(image, size: window.bounds.size)
                let expected: String
                switch state {
                case .unconfigured: expected = "Set up manually"
                case .differentProfile: expected = "Switch to this profile"
                case .failed: expected = "Try again"
                case .connected: expected = "Alex"
                }
                XCTAssertTrue(text.contains { $0.text.localizedCaseInsensitiveContains(expected) })
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                for line in text {
                    XCTAssertGreaterThanOrEqual(line.frame.minX, 23, line.text)
                    XCTAssertLessThanOrEqual(line.frame.maxX, 367, line.text)
                }
            }
        }
    }

    func testRequestAccountChoiceCanPresentAboveAnExistingDetailSheet() async throws {
        try await render(size: .init(width: 390, height: 844)) { window, _, service in
            let root = try XCTUnwrap(window.rootViewController)
            let sheet = UIHostingController(rootView: Text("Title details"))
            root.present(sheet, animated: false)
            defer { sheet.dismiss(animated: false) }
            try await Task.sleep(for: .milliseconds(150))
            try service.updateSelection(defaultID: service.profileConnections.defaultID, rememberLastUsed: false, askEachTime: true)
            let request = Task { await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie)) }
            defer { request.cancel(); service.chooseDestination(nil) }
            let deadline = ContinuousClock.now + .seconds(3)
            while sheet.presentedViewController == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let choice = try XCTUnwrap(sheet.presentedViewController as? UIAlertController,
                                      "Request choice must not be hidden behind the detail sheet")
            XCTAssertEqual(choice.title, "Request as")
            XCTAssertEqual(choice.actions.count, 2)
            XCTAssertTrue(choice.actions.first?.title?.contains("Alex") == true)
            service.chooseDestination(nil)
            let outcome = await request.value
            XCTAssertEqual(outcome, .failure(.cancelled))
        }
    }

    func testDiscoveryPreselectsTheAccountWithoutMovingControlsOrOpeningAForm() async throws {
        var scans = 0
        var continuation: AsyncStream<DiscoveredSeerServer>.Continuation?
        let discovered = URL(string: "https://nearby.example")!
        try await render(size: .init(width: 390, height: 844), state: .unconfigured, configure: { service in
            service.discoverServers = { _ in
                scans += 1
                return AsyncStream { continuation = $0 }
            }
            service.loginOptions = {
                [.init(id: "alex", name: "Alex", mediaServerType: 2, authenticate: { _ in throw AppError.unauthorized })]
            }
        }) { window, _, service in
            defer { continuation?.finish() }
            XCTAssertEqual(scans, 1)
            XCTAssertNotNil(UIImage(named: "SeerrIcon"), "The shared server logo must be bundled on iOS too")
            let before = try self.recognize(self.capture(window), size: window.bounds.size)
            self.attach(try self.capture(window), name: "Seerr detecting server")
            let continueBefore = try XCTUnwrap(before.first { $0.text == "Continue" })
            XCTAssertEqual(self.activityIndicators(in: window).filter(\.isAnimating).count, 1)
            XCTAssertFalse(before.contains { $0.text.contains("Checking sign-in options") })
            XCTAssertTrue(before.contains { $0.text == "Set up manually" })
            continuation?.yield(.init(baseURL: discovered, version: "1"))
            try await Task.sleep(for: .milliseconds(150))
            window.layoutIfNeeded()
            let text = try self.recognize(self.capture(window), size: window.bounds.size)
            self.attach(try self.capture(window), name: "Seerr suggested account")
            let continueAfter = try XCTUnwrap(text.first { $0.text == "Continue as Alex" },
                                            "A usable server must be ready while the remaining scan is still suspended")
            XCTAssertEqual(continueBefore.frame.minY, continueAfter.frame.minY, accuracy: 2)
            XCTAssertTrue(text.contains { $0.text.contains("nearby.example") })
            XCTAssertGreaterThanOrEqual(text.filter { $0.text == "Seerr" }.count, 2,
                                       "The detected server must retain the shared named server row")
            XCTAssertTrue(self.textFields(in: window).isEmpty)
            XCTAssertEqual(self.activityIndicators(in: window).filter(\.isAnimating).count, 0)
            XCTAssertNil(service.profileConnections.setupServer)
            XCTAssertFalse(text.contains { $0.text.contains("Find on local network") })
            XCTAssertTrue(text.contains { $0.text == "Set up manually" })
            XCTAssertFalse(service.isConfigured, "Finding a server must not authenticate or save an account")
        }
    }

    func testLateDiscoveryCannotReplaceTypedAddressOrCrossProfiles() async throws {
        for switchProfile in [false, true] {
            var continuation: AsyncStream<DiscoveredSeerServer>.Continuation?
            try await render(size: .init(width: 390, height: 844), state: .unconfigured, manualForm: true, configure: { service in
                service.discoverServers = { _ in
                    AsyncStream { continuation = $0 }
                }
            }) { window, _, service in
                defer { continuation?.finish() }
                let field = try XCTUnwrap(self.textFields(in: window).first)
                if switchProfile {
                    let other = Profile(id: "replacement", name: "Replacement")
                    service.configureProfiles(store: InMemorySeerAccountConnectionStore(), profiles: [other], current: { other })
                } else {
                    field.text = "https://typed.example"
                    field.sendActions(for: .editingChanged)
                }
                try await Task.sleep(for: .milliseconds(50))
                continuation?.yield(.init(baseURL: URL(string: "https://late.example")!, version: "1"))
                continuation?.finish()
                try await Task.sleep(for: .milliseconds(100))
                if !switchProfile { XCTAssertEqual(field.text, "https://typed.example") }
                let text = try self.recognize(self.capture(window), size: window.bounds.size)
                XCTAssertFalse(text.contains { $0.text.contains("late.example") })
                XCTAssertFalse(service.isConfigured)
            }
        }
    }

    func testDiscoveryChoicesUseNamedRowsSeparateFromManualEntry() async throws {
        let urls = [URL(string: "http://192.168.1.9:5055")!, URL(string: "http://192.168.1.10:5055")!]
        try await render(size: .init(width: 768, height: 1024), state: .unconfigured, manualForm: true, configure: { service in
            service.discoverServers = { _ in
                AsyncStream {
                    for url in urls { $0.yield(.init(baseURL: url, version: "3.5.2")) }
                    $0.finish()
                }
            }
        }) { window, scroll, service in
            let text = try self.recognize(self.capture(window), size: window.bounds.size)
            let addresses = text.filter { line in urls.contains { line.text.contains($0.host!) } }
            XCTAssertEqual(addresses.count, 2)
            XCTAssertGreaterThanOrEqual(text.filter { $0.text == "Seerr" }.count, 3)
            let entry = try XCTUnwrap(self.textFields(in: window).first)
            let entryFrame = entry.convert(entry.bounds, to: window)
            XCTAssertTrue(addresses.allSatisfy { $0.frame.maxY < entryFrame.minY },
                          "Discovered servers belong above the separate manual address field")
            XCTAssertTrue(text.contains { $0.text.localizedCaseInsensitiveCompare("Scan Again") == .orderedSame },
                          text.map(\.text).joined(separator: " | "))
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            XCTAssertFalse(service.isConfigured)
        }
    }

    func testPluginSuggestionPreselectsWithoutAuthenticatingOrOpeningAForm() async throws {
        try await render(size: .init(width: 390, height: 844), state: .unconfigured, configure: { service in
            service.suggestedAddresses = { [URL(string: "https://suggested.example")!] }
            service.discoverServers = { _ in
                XCTFail("A supplied address should not start a subnet scan")
                return AsyncStream { $0.finish() }
            }
            service.loginOptions = {
                [.init(id: "alex", name: "Alex", mediaServerType: 2, authenticate: { _ in throw AppError.unauthorized })]
            }
            service.prepareSetup()
            let deadline = ContinuousClock.now + .seconds(3)
            while service.setupDiscovery.isSearching, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertNotNil(service.setupDiscovery.selected, "Prepare before the Seerr page mounts")
            service.suggestedAddresses = { XCTFail("Page entry must reuse preparation"); return [] }
            service.discoveryMethods = { _ in XCTFail("Page entry must reuse capabilities"); throw AppError.invalidResponse }
        }) { window, _, service in
            let text = try self.recognize(self.capture(window), size: window.bounds.size)
            XCTAssertTrue(text.contains { $0.text.contains("suggested.example") })
            XCTAssertTrue(text.contains { $0.text == "Continue as Alex" })
            XCTAssertTrue(self.textFields(in: window).isEmpty)
            XCTAssertNil(service.profileConnections.setupServer)
            XCTAssertFalse(service.isConfigured)
        }
    }

    func testResumedSetupKeepsTheChosenPlexServerAndOffersItsAccount() async throws {
        let selected = URL(string: "https://plex.example.test:15056/seerr")!
        try await render(size: .init(width: 390, height: 844), state: .unconfigured, serverType: 1, configure: { service in
            try service.rememberSetupServer(selected, expectedProfileID: "fixture")
            service.suggestedAddresses = { XCTFail("Resume must not replace the chosen server"); return [] }
            service.discoverServers = { _ in XCTFail("Resume must not scan again"); return AsyncStream { $0.finish() } }
            let authentication = service.authentication
            service.authentication = { url in
                XCTAssertEqual(url, selected)
                return authentication(url)
            }
            service.loginOptions = {
                [.init(id: "alex", name: "Alex", mediaServerType: 1, authenticate: { _ in throw AppError.unauthorized })]
            }
        }) { window, _, service in
            let text = try self.recognize(self.capture(window), size: window.bounds.size).map(\.text)
            XCTAssertTrue(text.contains("Continue as Alex"))
            XCTAssertFalse(text.contains { $0.contains("Jellyfin") })
            XCTAssertFalse(service.isConfigured)
        }
    }

    private func textFields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields)
    }

    private func activityIndicators(in view: UIView) -> [UIActivityIndicatorView] {
        ((view as? UIActivityIndicatorView).map { [$0] } ?? []) + view.subviews.flatMap(activityIndicators)
    }

    func testIncompatibleServerDoesNotOfferTheExistingPlexAccount() async throws {
        try await render(size: .init(width: 390, height: 844), state: .unconfigured, serverType: 2, configure: { service in
            service.suggestedAddresses = { [URL(string: "https://jellyfin-seerr.example")!] }
            service.loginOptions = {
                [.init(id: "plex", name: "Alex", mediaServerType: 1, authenticate: { _ in
                    XCTFail("Detection must never authenticate"); throw AppError.unauthorized
                })]
            }
        }) { window, _, service in
            let text = try self.recognize(self.capture(window), size: window.bounds.size).map(\.text)
            XCTAssertFalse(text.contains("Continue as Alex"))
            XCTAssertTrue(text.contains("Sign in with Jellyfin"))
            XCTAssertFalse(text.contains { $0.contains("Choose a sign-in method") })
            XCTAssertTrue(text.contains("Set up manually"))
            XCTAssertTrue(self.textFields(in: window).isEmpty)
            XCTAssertFalse(service.isConfigured)
        }
    }

    func testEmbyUsernameCanBeSuggestedWithoutClaimingSessionReuse() async throws {
        try await render(size: .init(width: 390, height: 844), state: .unconfigured, serverType: 3, configure: { service in
            service.suggestedAddresses = { [URL(string: "https://emby-seerr.example")!] }
            service.embyUsernames = { ["Emby Alex"] }
        }) { window, _, service in
            let text = try self.recognize(self.capture(window), size: window.bounds.size).map(\.text)
            XCTAssertTrue(text.contains("Continue as Emby Alex"))
            XCTAssertTrue(text.contains("Set up manually"))
            XCTAssertTrue(self.textFields(in: window).isEmpty)
            XCTAssertTrue(service.loginOptions().isEmpty)
            XCTAssertFalse(service.isConfigured)
        }
    }

    func testPasswordlessMediaAccountCanSubmit() async throws {
        try await render(size: .init(width: 768, height: 1024), state: .unconfigured, serverType: 3, manualForm: true, configure: { service in
            try service.rememberSetupServer(URL(string: "https://suggested.example")!, expectedProfileID: "fixture")
        }) { window, _, _ in
            let fields = self.textFields(in: window)
            let username = try XCTUnwrap(fields.first { !$0.isSecureTextEntry })
            let password = try XCTUnwrap(fields.first { $0.isSecureTextEntry })
            username.text = "Passwordless"
            username.sendActions(for: .editingChanged)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(password.text?.isEmpty != false)
            password.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(150))
            let text = try self.recognize(self.capture(window), size: window.bounds.size).map(\.text)
            XCTAssertTrue(text.contains("Use this account"), "An empty media password must reach server authentication")
        }
    }

    func testSupportedSignInMethodsAreVisibleWithoutOpeningAMenu() async throws {
        for (serverType, expected) in [(1, "Use another Plex account"), (2, "Use another Jellyfin account"), (3, "Emby account")] {
            try await render(size: .init(width: 768, height: 1024), state: .unconfigured, serverType: serverType, manualForm: true, configure: { service in
                try service.rememberSetupServer(URL(string: "https://suggested.example")!, expectedProfileID: "fixture")
                service.loginOptions = {
                    guard serverType != 3 else { return [] }
                    return [.init(id: "alex", name: "Alex", mediaServerType: serverType, authenticate: { _ in throw AppError.unauthorized })]
                }
            }) { window, _, service in
                let text = try self.recognize(self.capture(window), size: window.bounds.size).map(\.text)
                XCTAssertEqual(text.contains("Sign in as Alex"), serverType != 3)
                XCTAssertTrue(text.contains { $0.localizedCaseInsensitiveCompare(expected) == .orderedSame })
                XCTAssertTrue(text.contains("Seerr account"))
                XCTAssertTrue(text.contains("Use API key"))
                XCTAssertFalse(text.contains("Other sign-in options"))
                XCTAssertFalse(service.isConfigured)
            }
        }
    }

    func testMobilePlexSignInUsesBrowserInsteadOfScanningTheSameDevice() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 390, height: 844), CGSize(width: 768, height: 1024)] {
            let signInURL = URL(string: "https://app.plex.tv/auth#fixture")!
            let opened = expectation(description: "Open Plex directly from the sign-in action")
            opened.assertForOverFulfill = true
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            let host = UIHostingController(rootView:
                SeerPlexSignInView(url: signInURL, onCancel: {})
                    .padding(24)
                    .environment(\.themePalette, ThemePalette.dark)
                    .environment(\.locale, Locale(identifier: "en"))
                    .environment(\.openURL, OpenURLAction { url in
                        XCTAssertEqual(url, signInURL)
                        opened.fulfill()
                        return .handled
                    })
            )
            host.overrideUserInterfaceStyle = .dark
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(150))
            window.layoutIfNeeded()
            let text = try recognize(capture(window), size: size).map(\.text)
            XCTAssertTrue(text.contains("Open Plex sign-in"))
            XCTAssertTrue(text.contains("Waiting for sign-in"))
            XCTAssertTrue(text.contains("Cancel"))
            XCTAssertFalse(text.contains { $0.localizedCaseInsensitiveContains("scan") })
            await fulfillment(of: [opened], timeout: 1)
        }
    }

    private func render(
        size: CGSize, typeSize: DynamicTypeSize = .large,
        direction: LayoutDirection = .leftToRight, longNames: Bool = false,
        state: SeerrSetupHTTP.State = .connected,
        serverType: Int = 2,
        manualForm: Bool = false,
        configure: (SeerService) async throws -> Void = { _ in },
        inspect: (UIWindow, UIScrollView, SeerService) async throws -> Void
    ) async throws {
        let http = SeerrSetupHTTP(state: state, longNames: longNames, serverType: serverType)
        let store = InMemorySeerConnectionStore(connection: state == .unconfigured ? nil : .init(
            baseURL: URL(string: "https://fixture.invalid")!, apiKey: "fixture"
        ))
        let service = SeerService(connectionStore: store, http: http)
        service.discoverServers = { _ in AsyncStream { $0.finish() } }
        service.authentication = { SeerAuthentication(baseURL: $0, http: http) }
        service.discoveryMethods = { try await SeerAuthentication(baseURL: $0, http: http).methods() }
        var profile = Profile(id: "fixture", name: longNames ? "A household profile with a very long name" : "Home")
        profile.seerrUserID = 2
        profile.seerrUserName = longNames ? "Alex with an exceptionally long household display name" : "Alex"
        profile.seerrServerIdentity = SeerServerIdentity(baseURL: URL(string: "https://fixture.invalid")!)
        let current = state == .differentProfile ? Profile(id: "other", name: "Other") : profile
        service.configureProfiles(store: InMemorySeerAccountConnectionStore(), profiles: [profile, current], current: { current })
        try await configure(service)
        let view = Group {
            if manualForm {
                ScrollView {
                    VStack(spacing: 24) {
                        Text(verbatim: "Seerr")
                        SeerSignInForm(seer: service)
                    }
                    .padding(24)
                }
            } else {
                ProfileSeerrSetupView(
                    seer: service,
                    profile: profile,
                    onSelect: { _ in }, onContinue: {}
                )
            }
        }
        .seerRequestDestination(service)
        .environment(\.themePalette, ThemePalette.dark)
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.layoutDirection, direction)
        .environment(\.locale, Locale(identifier: "en"))
        let deadline = ContinuousClock.now + .seconds(5)
        while UIApplication.shared.connectedScenes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let ready = ContinuousClock.now + .seconds(5)
        let expectsProbe = state == .connected || state == .failed
        while !(await http.finished), expectsProbe, ContinuousClock.now < ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        if expectsProbe { let finished = await http.finished; XCTAssertTrue(finished) }
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(in: host.view).first)
        try await inspect(window, scroll, service)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func scrollToBottom(_ scroll: UIScrollView, window: UIWindow) async throws {
        scroll.setContentOffset(CGPoint(x: 0, y: max(
            -scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        )), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
    }

    private func capture(_ window: UIWindow) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func assertPanelGutters(_ image: UIImage, rowY: CGFloat) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.bitsPerPixel, 32)
        guard cgImage.bitsPerPixel == 32 else { return }
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let scale = CGFloat(cgImage.width) / image.size.width
        let y = Int(rowY * scale)
        let expected = max(24, (image.size.width - 720) / 2)
        // Locate the real panel border, before any avatar/text. Native scroll
        // bounds stay edge-to-edge: SwiftUI applies these gutters to its content.
        for trailing in [false, true] {
            var strongest = (delta: 0, inset: CGFloat.zero)
            for distance in 1..<Int((expected + 8) * scale) {
                let x = trailing ? cgImage.width - distance : distance
                let offset = y * cgImage.bytesPerRow + x * 4
                let delta = (0..<3).reduce(0) {
                    $0 + abs(Int(bytes[offset + $1]) - Int(bytes[offset - 4 + $1]))
                }
                if delta > strongest.delta { strongest = (delta, CGFloat(distance) / scale) }
            }
            XCTAssertGreaterThan(strongest.delta, 20, "Expected a visible panel boundary")
            XCTAssertEqual(strongest.inset, expected, accuracy: 1)
        }
    }

    private func attach(_ image: UIImage, name: String) {
        if let directory = ProcessInfo.processInfo.environment["PLOZZ_SEERR_CAPTURE_DIR"] {
            do {
                let data = try XCTUnwrap(image.pngData())
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            } catch { XCTFail("Could not save Seerr presentation evidence: \(error)") }
            return
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func recognize(_ image: UIImage, size: CGSize) throws -> [(text: String, frame: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap {
            guard let text = $0.topCandidates(1).first?.string else { return nil }
            let box = $0.boundingBox
            return (text, CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                 width: box.width * size.width, height: box.height * size.height))
        }
    }
}

private actor SeerrSetupHTTP: HTTPClient {
    enum State { case connected, unconfigured, differentProfile, failed }
    let state: State
    let longNames: Bool
    let serverType: Int
    private(set) var finished = false

    init(state: State, longNames: Bool, serverType: Int) {
        self.state = state
        self.longNames = longNames
        self.serverType = serverType
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let json: String
        if endpoint.path.hasSuffix("/settings/public") {
            json = #"{"initialized":true,"mediaServerType":\#(serverType),"mediaServerLogin":true,"localLogin":true}"#
        } else if endpoint.path.hasSuffix("/status") {
            json = #"{"version":"1.0"}"#
        } else if endpoint.path.hasSuffix("/auth/me") {
            finished = true
            if state == .failed { throw AppError.serverUnreachable }
            json = #"{"id":2,"displayName":"Alex","permissions":8}"#
        } else if endpoint.path.hasSuffix("/auth/jellyfin") {
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(endpoint.body)) as? [String: String]
            XCTAssertEqual(body?["username"], "Passwordless")
            XCTAssertEqual(body?["password"], "")
            return (Data("{}".utf8), HTTPURLResponse(
                url: baseURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "connect.sid=fixture; Path=/; HttpOnly"]
            )!)
        } else {
            throw AppError.invalidResponse
        }
        return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
