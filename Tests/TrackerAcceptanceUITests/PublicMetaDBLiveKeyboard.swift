import XCTest

#if os(tvOS)
@MainActor
enum PublicMetaDBLiveKeyboard {
    enum Failure: Error {
        case unexpectedLayout
        case unreachableKey
    }

    // typeText records a prefix even for secure fields. Use ordinary remote events
    // without putting credential characters in XCTest query/action arguments.
    static func enter(_ text: String, in keyboard: XCUIElement) throws {
        let navigation = try Navigation(keyboard)
        for character in text {
            let value = String(character)
            if character.isLetter {
                try navigation.select(
                    character.isUppercase ? "Uppercase Letters" : "Lowercase Letters",
                    onlyIfUnselected: true
                )
            }
            try navigation.select(value)
        }
    }

    private final class Navigation {
        struct Key {
            let label: String
            let frame: CGRect
            let selected: Bool
        }
        let keyboard: XCUIElement
        var keys: [Key] = []
        var current = 0

        init(_ keyboard: XCUIElement) throws {
            self.keyboard = keyboard
            try reload()
        }

        func reload() throws {
            keys = keyboard.keys.allElementsBoundByIndex.map {
                Key(label: $0.label, frame: $0.frame, selected: $0.isSelected)
            }
            let enlarged = keys.indices.filter { keys[$0].frame.height > 70 }
            guard enlarged.count == 1 else { throw Failure.unexpectedLayout }
            current = enlarged[0]
        }

        func select(_ label: String, onlyIfUnselected: Bool = false) throws {
            guard let target = keys.firstIndex(where: { $0.label == label }) else {
                throw Failure.unexpectedLayout
            }
            if onlyIfUnselected && keys[target].selected { return }
            for _ in 0..<40 {
                // tvOS exposes focus on the keyboard; its focused key is enlarged.
                guard keyboard.keys.element(boundBy: current).frame.height > 70 else {
                    throw Failure.unexpectedLayout
                }
                if target == current {
                    XCUIRemote.shared.press(.select)
                    if onlyIfUnselected { try reload() }
                    return
                }
                let origin = keys[current].frame
                let vertical = keys[target].frame.midY - origin.midY
                let horizontal = keys[target].frame.midX - origin.midX
                let direction: XCUIRemote.Button
                let candidates: [Int]
                if abs(vertical) > 20 {
                    direction = vertical > 0 ? .down : .up
                    candidates = keys.indices.filter {
                        let delta = keys[$0].frame.midY - origin.midY
                        return vertical > 0 ? delta > 20 : delta < -20
                    }.sorted {
                        let lhs = keys[$0].frame, rhs = keys[$1].frame
                        let leftY = abs(lhs.midY - origin.midY), rightY = abs(rhs.midY - origin.midY)
                        if abs(leftY - rightY) > 20 { return leftY < rightY }
                        return abs(lhs.midX - origin.midX) < abs(rhs.midX - origin.midX)
                    }
                } else {
                    direction = horizontal > 0 ? .right : .left
                    candidates = keys.indices.filter {
                        let delta = keys[$0].frame.midX - origin.midX
                        return abs(keys[$0].frame.midY - origin.midY) < 20
                            && (horizontal > 0 ? delta > 0 : delta < 0)
                    }.sorted { abs(keys[$0].frame.midX - origin.midX) < abs(keys[$1].frame.midX - origin.midX) }
                }
                guard let expected = candidates.first else { throw Failure.unreachableKey }
                XCUIRemote.shared.press(direction)
                if keyboard.keys.element(boundBy: expected).frame.height > 70 {
                    current = expected
                } else {
                    let enlarged = keys.indices.filter {
                        keyboard.keys.element(boundBy: $0).frame.height > 70
                    }
                    guard enlarged.count == 1 else { throw Failure.unexpectedLayout }
                    current = enlarged[0]
                }
            }
            throw Failure.unreachableKey
        }
    }
}
#endif
