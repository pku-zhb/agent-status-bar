import Foundation

final class MenuBarFeaturePreferences {
    private enum Key {
        static let showsStatusHalos = "menuBar.showsStatusHalos"
        static let showsUsage = "menuBar.showsUsage"
        static let showsUsageNumbers = "menuBar.showsUsageNumbers"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var showsStatusHalos: Bool {
        get { bool(forKey: Key.showsStatusHalos, defaultValue: true) }
        set { defaults.set(newValue, forKey: Key.showsStatusHalos) }
    }

    var showsUsage: Bool {
        get { bool(forKey: Key.showsUsage, defaultValue: true) }
        set { defaults.set(newValue, forKey: Key.showsUsage) }
    }

    var showsUsageNumbers: Bool {
        get { bool(forKey: Key.showsUsageNumbers, defaultValue: true) }
        set { defaults.set(newValue, forKey: Key.showsUsageNumbers) }
    }

    private func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}
