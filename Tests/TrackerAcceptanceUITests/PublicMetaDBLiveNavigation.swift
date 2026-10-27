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
        try select(integrations, moving: .down)
        try select(app.buttons["settings-page-publicmetadb"], moving: .down)
        #else
        throw Failure.unavailableControl("Open PublicMetaDB settings before this iOS run.")
        #endif
        guard app.buttons["publicmetadb.pair"].waitForExistence(timeout: 5) else {
            throw Failure.unavailableControl("PublicMetaDB settings")
        }
    }

    #if os(tvOS)
    static func select(_ target: XCUIElement, moving direction: XCUIRemote.Button) throws {
        try focus(target, moving: direction)
        XCUIRemote.shared.press(.select)
    }

    static func focus(_ target: XCUIElement, moving direction: XCUIRemote.Button) throws {
        for _ in 0..<24 {
            if target.exists && target.hasFocus { break }
            XCUIRemote.shared.press(direction)
        }
        guard target.exists, target.hasFocus, target.isEnabled else {
            throw Failure.unavailableControl("Required control did not become focused.")
        }
    }
    #endif
}
