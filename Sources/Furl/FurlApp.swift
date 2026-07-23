import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct FurlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?

    /// Follow the system light/dark setting (read from the global domain, since
    /// `effectiveAppearance` is what's wrong here).
    static func syncAppearance() {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        let isDark = style?.lowercased().contains("dark") ?? false
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, never a foreground app.
        NSApp.setActivationPolicy(.accessory)

        // Accessory apps don't always inherit the system light/dark appearance
        // (depends on how they're launched), which left the Settings and
        // onboarding windows stuck light. Pin it to the system value and keep
        // it in sync on theme changes.
        AppDelegate.syncAppearance()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppDelegate.syncAppearance() }
        }

        Prefs.registerDefaults()
        BarManager.shared.start()

        // Global hot key: ⌃⌥H toggles hidden icons.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_H),
                        modifiers: UInt32(controlKey | optionKey)) {
            MainActor.assumeIsolated { BarManager.shared.toggle() }
        }

        // Scripting/verification hook: FURL_SET_SPACING=<points>
        if let pts = ProcessInfo.processInfo.environment["FURL_SET_SPACING"]
            .flatMap(Int.init) {
            Spacing.set(pts)
        }

        UpdateWatcher.shared.applyPrefs()

        // Scripting/verification hooks.
        if ProcessInfo.processInfo.environment["FURL_DEBUG_TOGGLEONLY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                BarManager.shared.debugRemoveToggleOnly()
            }
        }

        if ProcessInfo.processInfo.environment["FURL_DEBUG_FLASHHOLD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                BarManager.shared.beginFlash()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                BarManager.shared.endFlash()
            }
        }

        // Drive one expand→collapse cycle (builds the Furl Bar cache the way
        // real usage does).
        if ProcessInfo.processInfo.environment["FURL_DEBUG_CYCLE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                BarManager.shared.expand()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                BarManager.shared.collapse()
            }
        }

        // Simulate a chevron click after the cache is built (pair with CYCLE).
        if ProcessInfo.processInfo.environment["FURL_DEBUG_OVERLAY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) {
                BarManager.shared.toggle()
            }
        }

        if ProcessInfo.processInfo.environment["FURL_DEBUG_FURLBAR"] == "1" {
            // Wait past the collapse-time cache build, then open the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
                Task { @MainActor in
                    let cached = FurlBar.shared.cache
                    let log = "hasPermission=\(StripCapture.hasPermission)\n"
                        + "cache=\(cached.map { "\($0.image.width)x\($0.image.height) anchorX=\(Int($0.anchorX))" } ?? "nil")\n"
                    try? log.write(toFile: NSTemporaryDirectory() + "furl-debug.log",
                                   atomically: true, encoding: .utf8)
                    await FurlBar.shared.show()
                }
            }
        }

        if ProcessInfo.processInfo.environment["FURL_DEBUG_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SettingsWindowController.show()
            }
        }

        if !Prefs.onboarded || ProcessInfo.processInfo.environment["FURL_DEBUG_ONBOARDING"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                OnboardingWindowController.show()
            }
            Prefs.onboarded = true
        }
    }
}
