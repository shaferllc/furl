import SwiftUI
import AppKit
import ServiceManagement

/// Furl owns its settings window: for an LSUIElement app, the SwiftUI Settings
/// scene's `showSettingsWindow:` action is unreliable (opens behind, or not at
/// all). A plain floating NSWindow is deterministic.
@MainActor
final class SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "Furl Settings"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.level = .floating

        // The form is taller than short screens — cap the window to ~80% of
        // the visible screen height so the grouped Form scrolls internally
        // instead of running off the bottom with no way to reach it.
        let visible = (w.screen ?? NSScreen.main)?.visibleFrame ?? .init(x: 0, y: 0, width: 800, height: 900)
        let height = min(hosting.view.fittingSize.height, visible.height * 0.85)
        w.setContentSize(NSSize(width: 420, height: height))
        w.contentMinSize = NSSize(width: 420, height: 320)
        w.contentMaxSize = NSSize(width: 420, height: 100_000)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.autoCollapseKey) private var autoCollapse = true
    @AppStorage(Prefs.autoCollapseDelayKey) private var autoCollapseDelay = 15.0
    @AppStorage(Prefs.hoverExpandKey) private var hoverExpand = true
    @AppStorage(Prefs.alwaysHiddenKey) private var alwaysHiddenZone = false
    @AppStorage(Prefs.startCollapsedKey) private var startCollapsed = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Prefs.triggersEnabledKey) private var triggersEnabled = false
    @AppStorage(Prefs.triggerIntervalKey) private var triggerInterval = 300.0
    @State private var spacing = Double(Spacing.current)
    @State private var spacingChanged = false
    @State private var needsRelaunchForCapture = false

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    var body: some View {
        Form {
            Section("Hiding") {
                Toggle("Hide icons again automatically", isOn: $autoCollapse)
                if autoCollapse {
                    HStack {
                        Slider(value: $autoCollapseDelay, in: 2...60, step: 1) {
                            Text("After")
                        }
                        Text("\(Int(autoCollapseDelay))s")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Show icons when hovering the menu bar", isOn: $hoverExpand)
                Toggle("Start with icons hidden", isOn: $startCollapsed)
            }

            Section {
                LabeledContent("Screen Recording") {
                    if StripCapture.hasPermission {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else if needsRelaunchForCapture {
                        Button("Relaunch Furl to finish") { relaunch() }
                    } else {
                        Button("Grant…") {
                            StripCapture.requestPermission()
                            needsRelaunchForCapture = true
                        }
                    }
                }
            } header: {
                Text("Reveal")
            } footer: {
                Text("Revealed icons show as a scrollable strip on the menu bar — swipe left/right when there are more than fit beside the notch. Furl draws them from a screen capture, so this needs Screen Recording. Without it, Furl falls back to un-hiding the real icons in place (no scrolling).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Reveal when hidden icons change", isOn: $triggersEnabled)
                    .onChange(of: triggersEnabled) { _, on in
                        if on && !StripCapture.hasPermission {
                            StripCapture.requestPermission()
                            needsRelaunchForCapture = true
                        }
                    }
                if triggersEnabled && !StripCapture.hasPermission {
                    LabeledContent("Screen Recording") {
                        if needsRelaunchForCapture {
                            Button("Relaunch Furl to finish") { relaunch() }
                        } else {
                            Text("Not granted").foregroundStyle(.orange)
                        }
                    }
                }
                if triggersEnabled {
                    HStack {
                        Slider(value: $triggerInterval, in: 60...1800, step: 60) {
                            Text("Check every")
                        }
                        Text("\(Int(triggerInterval / 60))m")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Show on Update")
            } footer: {
                Text("Checks the hidden icons on a schedule and surfaces the bar when something changed — a sync starting, a badge appearing. Each check un-furls the bar for a fraction of a second. Uses Screen Recording to read the icons (nothing leaves your Mac).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Always-hidden zone", isOn: $alwaysHiddenZone)
            } footer: {
                Text("Adds a second, dashed divider. Icons left of it stay hidden even when the bar is expanded — ⌥-click the chevron to peek at them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Slider(value: $spacing, in: 2...32, step: 1) {
                        Text("Spacing")
                    } minimumValueLabel: {
                        Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: spacing) { _, value in
                        Spacing.set(Int(value))
                        spacingChanged = true
                    }
                    Text("\(Int(spacing))pt")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                if spacingChanged {
                    Button("Relaunch Furl to preview") { relaunch() }
                }
            } header: {
                Text("Menu Bar Spacing")
            } footer: {
                Text("Space between menu bar icons (macOS default is 16pt). Tighter fits more icons clear of the notch. Each app picks it up when it relaunches — log out and back in to apply everywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Toggle shortcut", value: "⌃⌥H")
            }

            Section {
                Text("Everything left of Furl's │ divider hides. ⌘-drag icons you always want visible to the right of the divider, next to the ‹ chevron.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
