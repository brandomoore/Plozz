import Foundation

/// Converts remote travel into whole steps while retaining fractional movement.
struct SettingsAdjustmentSwipe {
    private static let pointsPerStep = 20.0
    private var lastTranslation: Double
    private var remainder: Double
    let initialSteps: Int

    init(translation: Double, forward: Bool) {
        lastTranslation = translation
        let steps = Int(translation / Self.pointsPerStep)
        initialSteps = steps == 0 ? (forward ? 1 : -1) : steps
        remainder = steps == 0 ? 0 : translation.truncatingRemainder(dividingBy: Self.pointsPerStep)
    }

    mutating func advance(to translation: Double) -> Int {
        remainder += translation - lastTranslation
        lastTranslation = translation
        let steps = Int(remainder / Self.pointsPerStep)
        remainder -= Double(steps) * Self.pointsPerStep
        return steps
    }
}
