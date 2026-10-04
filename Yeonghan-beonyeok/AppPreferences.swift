import SwiftUI
import Observation

@Observable @MainActor
final class AppPreferences {
    private let defaults: UserDefaults
    var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: "showMenuBar") } }
    var respectLowPower: Bool { didSet { defaults.set(respectLowPower, forKey: "respectLowPower") } }
    var trashRetentionDays: Int { didSet { defaults.set(trashRetentionDays, forKey: "trashRetentionDays") } }
    var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    var setupComplete: Bool { didSet { defaults.set(setupComplete, forKey: "setupComplete") } }
    var annotationColorHex: String { didSet { defaults.set(annotationColorHex, forKey: "annotationColorHex") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["showMenuBar": true, "respectLowPower": true,
                                     "speechIdleMinutes": 5, "trashRetentionDays": 0,
                                     "audioRetention": "failed", "appearance": "system"])
        showMenuBar = defaults.bool(forKey: "showMenuBar")
        respectLowPower = defaults.bool(forKey: "respectLowPower")
        trashRetentionDays = defaults.integer(forKey: "trashRetentionDays")
        appearance = defaults.string(forKey: "appearance") ?? "system"
        setupComplete = defaults.bool(forKey: "setupComplete")
        annotationColorHex = defaults.string(forKey: "annotationColorHex").flatMap(AnnotationColor.normalizedHex) ?? AnnotationColor.defaultHex
    }

    var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }
}
