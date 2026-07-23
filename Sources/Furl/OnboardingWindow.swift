import SwiftUI
import AppKit

/// First-run welcome: the ⌘-drag gesture is not discoverable, so spell it out.
@MainActor
final class OnboardingWindowController {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView {
            window?.close()
            window = nil
        })
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.center()
        w.level = .floating
        window = w
        w.makeKeyAndOrderFront(nil)
        // LSUIElement apps can lose the ordering race right after launch;
        // force it in front regardless of activation state.
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct OnboardingView: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 26)

            Text("Welcome to Furl")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 16) {
                step(number: "1", symbol: "chevron.compact.left",
                     title: "Click ‹ next to the clock",
                     detail: "Furl tucks your menu bar icons away. Click the ‹ chevron (or hover it, or press ⌃⌥H) to show them; they slide away again on their own.")
                step(number: "2", symbol: "command",
                     title: "⌘-drag your keepers past the divider",
                     detail: "Hold ⌘ and drag the icons you always want visible to the RIGHT of Furl's │ divider, next to the chevron. Everything left of it hides.")
                step(number: "3", symbol: "gearshape",
                     title: "Right-click ‹ for settings",
                     detail: "Auto-hide delay, hover reveal, an always-hidden zone, launch at login.")
            }
            .frame(maxWidth: 400)

            Button(action: done) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: 400)
            .padding(.bottom, 26)
        }
        .padding(.horizontal, 34)
        .frame(width: 480)
    }

    private func step(number: String, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
