import Foundation

/// UserDefaults-backed preferences. SettingsView binds the same keys via
/// @AppStorage; BarManager re-reads on UserDefaults.didChangeNotification.
enum Prefs {
    static let autoCollapseKey = "furl.autoCollapse"
    static let autoCollapseDelayKey = "furl.autoCollapseDelay"
    static let hoverExpandKey = "furl.hoverExpand"
    static let alwaysHiddenKey = "furl.alwaysHiddenZone"
    static let startCollapsedKey = "furl.startCollapsed"
    static let onboardedKey = "furl.onboarded"
    static let furlBarKey = "furl.furlBar"
    static let triggersEnabledKey = "furl.triggersEnabled"
    static let triggerIntervalKey = "furl.triggerInterval"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoCollapseKey: true,
            autoCollapseDelayKey: 15.0,
            hoverExpandKey: true,
            alwaysHiddenKey: false,
            startCollapsedKey: true,
            furlBarKey: false,
            triggersEnabledKey: false,
            triggerIntervalKey: 300.0,
        ])
    }

    static var autoCollapse: Bool { UserDefaults.standard.bool(forKey: autoCollapseKey) }
    static var autoCollapseDelay: Double { UserDefaults.standard.double(forKey: autoCollapseDelayKey) }
    static var hoverExpand: Bool { UserDefaults.standard.bool(forKey: hoverExpandKey) }
    static var alwaysHiddenZone: Bool { UserDefaults.standard.bool(forKey: alwaysHiddenKey) }
    static var startCollapsed: Bool { UserDefaults.standard.bool(forKey: startCollapsedKey) }
    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: onboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardedKey) }
    }
    static var furlBar: Bool { UserDefaults.standard.bool(forKey: furlBarKey) }
    static var triggersEnabled: Bool { UserDefaults.standard.bool(forKey: triggersEnabledKey) }
    static var triggerInterval: Double { UserDefaults.standard.double(forKey: triggerIntervalKey) }
}
