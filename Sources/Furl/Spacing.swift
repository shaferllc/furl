import Foundation

/// Menu bar icon spacing via Apple's hidden global defaults
/// (NSStatusItemSpacing / NSStatusItemSelectionPadding, per current host).
/// The source of truth is the global domain itself, not Furl's prefs. Each
/// app picks the change up when it recreates its status item, so a full
/// logout/login applies it everywhere.
enum Spacing {
    /// macOS's own default when the keys are absent.
    static let systemDefault = 16

    /// Current spacing value (points between icons). Falls back to the system
    /// default when no override is set.
    static var current: Int {
        (CFPreferencesCopyValue("NSStatusItemSpacing" as CFString,
                                kCFPreferencesAnyApplication,
                                kCFPreferencesCurrentUser,
                                kCFPreferencesCurrentHost) as? Int) ?? systemDefault
    }

    /// Set the spacing between menu bar icons. Selection padding (the click
    /// highlight) scales with it so tight spacing doesn't overlap highlights.
    /// Passing the system default removes the override entirely.
    static func set(_ spacing: Int) {
        func write(_ key: String, _ value: Int?) {
            CFPreferencesSetValue(key as CFString, value.map { $0 as CFNumber },
                                  kCFPreferencesAnyApplication,
                                  kCFPreferencesCurrentUser,
                                  kCFPreferencesCurrentHost)
        }
        if spacing == systemDefault {
            write("NSStatusItemSpacing", nil)
            write("NSStatusItemSelectionPadding", nil)
        } else {
            write("NSStatusItemSpacing", spacing)
            write("NSStatusItemSelectionPadding", max(4, spacing - 2))
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesCurrentHost)
    }
}
