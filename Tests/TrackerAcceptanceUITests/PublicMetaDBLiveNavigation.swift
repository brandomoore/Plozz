import XCTest

@MainActor
enum PublicMetaDBLiveNavigation {
    enum Failure: Error {
        case unavailableControl(String)
    }

    static func openSettings(in app: XCUIApplication) throws {
        if app.buttons["publicmetadb.pair"].exists { return }
        #if os(tvOS)
        if app.buttons["live-tv-preview-disable"].exists {
            try select(app.buttons["live-tv-preview-disable"], moving: .right)
        }
        let integrations = app.buttons["settings-section-integrations"]
        if !integrations.exists || !integrations.isEnabled {
            let settings = app.buttons["Settings"]
            for _ in 0..<4 {
                if settings.exists && settings.isEnabled { break }
                XCUIRemote.shared.press(.left)
            }
            try select(settings, moving: .down)
        }
        let towardIntegrations: XCUIRemote.Button = integrations.frame.maxY < app.frame.minY ? .up : .down
        try select(integrations, moving: towardIntegrations)
        try select(app.buttons["settings-page-publicmetadb"], moving: .down)
        #else
        throw Failure.unavailableControl("Open PublicMetaDB settings before this iOS run.")
        #endif
        guard app.buttons["publicmetadb.pair"].waitForExistence(timeout: 5) else {
            throw Failure.unavailableControl("PublicMetaDB settings")
        }
    }

    #if os(tvOS)
    static func select(
        _ target: XCUIElement, moving direction: XCUIRemote.Button, maximumPresses: Int = 24
    ) throws {
        try focus(target, moving: direction, maximumPresses: maximumPresses)
        XCUIRemote.shared.press(.select)
    }

    static func focus(
        _ target: XCUIElement, moving direction: XCUIRemote.Button, maximumPresses: Int = 24
    ) throws {
        for _ in 0..<maximumPresses {
            if hasFocus(target) { break }
            XCUIRemote.shared.press(direction)
        }
        guard hasFocus(target) else {
            throw Failure.unavailableControl("Required control did not become focused.")
        }
    }

    private static func hasFocus(_ target: XCUIElement) -> Bool {
        guard target.exists, target.isEnabled else { return false }
        // Settings categories expose their actual native FocusState through selection.
        if target.identifier.hasPrefix("settings-section-"), target.isSelected { return true }
        return target.hasFocus || target.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
    }
    #endif
}
