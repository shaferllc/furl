import AppKit

/// Show-on-update: on a configurable cadence, run a flash capture of the
/// hidden strip and reveal the bar when it changed since last check — a sync
/// spinner appearing, a badge, a state flip. Each check un-furls the bar for
/// ~0.3s, so the cadence is minutes, not seconds. Off by default; needs
/// Screen Recording.
@MainActor
final class UpdateWatcher {
    static let shared = UpdateWatcher()

    private var timer: Timer?
    private var lastSignature: [UInt8]?
    private var checking = false

    func applyPrefs() {
        let shouldRun = Prefs.triggersEnabled && StripCapture.hasPermission
        if !shouldRun {
            timer?.invalidate()
            timer = nil
            lastSignature = nil
            return
        }
        let interval = max(60, Prefs.triggerInterval)
        if let timer, abs(timer.timeInterval - interval) < 1 { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateWatcher.shared.check() }
        }
    }

    private func check() {
        guard BarManager.shared.isCollapsed, !FurlBar.shared.isVisible,
              !InlineOverlay.shared.isVisible, !checking else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            guard let strip = await FurlBar.captureHiddenStrip() else { return }
            let sig = StripCapture.signature(of: strip.image)
            let old = lastSignature
            lastSignature = sig
            guard let old, StripCapture.changed(old, sig) else { return }
            BarManager.shared.revealForUpdate()
        }
    }
}
