import SwiftUI
import AppKit
import ApplicationServices

/// The second bar: a floating panel just below the menu bar showing the
/// hidden icons as a live captured strip, so revealing them never pushes the
/// visible ones back under the notch. Requires Screen Recording (falls back
/// to inline expand without it). Clicking the strip clicks the real item —
/// synthesized when Accessibility is granted, plain inline reveal otherwise.
@MainActor
final class FurlBar {
    static let shared = FurlBar()

    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var building = false
    private(set) var isVisible = false

    var panelFrame: NSRect { (isVisible ? panel?.frame : nil) ?? .zero }

    func toggle() {
        if isVisible { hide() } else { Task { await self.show() } }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        isVisible = false
    }

    private var promptedForCapture = false

    /// Latest strip of the hidden icons, refreshed for free at every collapse
    /// (the icons are on screen right before they hide). With a cache, opening
    /// the Furl Bar is instant — no flash, no inline movement. Persisted to
    /// disk because launch is the one moment a fresh capture can't work (the
    /// bar is mid-resort and photographs empty).
    var cache: HiddenStrip? {
        didSet { if let cache { persist(cache) } }
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Furl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("strip.png")
    }

    private func persist(_ strip: HiddenStrip) {
        Self.writePNG(strip.image, to: Self.cacheURL.path)
        UserDefaults.standard.set(Double(strip.anchorX), forKey: "furl.cacheAnchorX")
    }

    func loadPersistedCache() {
        guard cache == nil,
              let src = CGImageSourceCreateWithURL(Self.cacheURL as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let anchor = UserDefaults.standard.double(forKey: "furl.cacheAnchorX")
        guard anchor > 0, let screen = NSScreen.main else { return }
        cache = HiddenStrip(image: img, screen: screen, anchorX: anchor)
    }

    func show(auto: Bool = false) async {
        guard !building, !isVisible else { return }
        guard StripCapture.hasPermission else {
            // No capture permission: surface the system prompt once per
            // launch, and fall back to an inline expand meanwhile.
            if !promptedForCapture {
                promptedForCapture = true
                StripCapture.requestPermission()
            }
            BarManager.shared.expandBrieflyForActivation()
            return
        }

        if let cache {
            display(cache, auto: auto)
            return
        }

        building = true
        defer { building = false }
        guard let strip = await Self.captureHiddenStrip() else {
            BarManager.shared.expandBrieflyForActivation()
            return
        }
        cache = strip
        display(strip, auto: auto)
    }

    private func display(_ strip: HiddenStrip, auto: Bool) {
        let screen = strip.screen
        // Wider than fits → the panel scrolls horizontally.
        let maxWidth = screen.frame.width * 0.65
        let view = StripPanelView(image: strip.image, maxWidth: maxWidth) {
            [weak self] offsetFromRight in
            self?.activate(offsetFromRight: offsetFromRight)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)

        let p = panel ?? Self.makePanel()
        panel = p
        p.contentView = hosting
        p.setContentSize(hosting.fittingSize)

        let barH = StripCapture.menuBarHeight(of: screen)
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(
            x: min(strip.anchorX - size.width + 20,
                   screen.frame.maxX - size.width - 10),
            y: screen.frame.maxY - barH - size.height - 6))
        p.orderFrontRegardless()
        isVisible = true

        hideTimer?.invalidate()
        hideTimer = nil
        if auto { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: max(4, Prefs.autoCollapseDelay), repeats: false
        ) { _ in
            MainActor.assumeIsolated {
                let bar = FurlBar.shared
                guard bar.isVisible else { return }
                // Don't close under a hovering pointer — check again later.
                if BarManager.pointerOverBar(orIn: bar.panelFrame) {
                    bar.scheduleAutoHide()
                } else {
                    bar.hide()
                }
            }
        }
    }

    // MARK: - Collapse-time cache refresh

    /// Called by BarManager.collapse(): photograph the expanded strip (free —
    /// the icons are still on screen), collapse, then photograph the empty
    /// strip and diff to crop. No flash involved.
    private func trace(_ msg: String) {
        guard ProcessInfo.processInfo.environment["FURL_DEBUG_DUMP"] != nil else { return }
        let path = NSTemporaryDirectory() + "furl-cache-trace.log"
        let line = msg + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func cacheThenCollapse() async {
        let mgr = BarManager.shared
        trace("start toggleScreen=\(mgr.toggleScreen != nil) toggleLeftX=\(mgr.toggleLeftX.map { Int($0) } ?? -1)")
        // Right after item creation (app launch) the toggle's window sits at
        // x=0 until the bar lays it out — wait for a sane anchor.
        for _ in 0..<6 {
            if let s = mgr.toggleScreen, let x = mgr.toggleLeftX,
               x > s.frame.midX { break }
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard let screen = mgr.toggleScreen,
              let endX = mgr.toggleLeftX, endX > screen.frame.midX,
              let filter = await StripCapture.filter(for: screen)
        else {
            trace("no screen/anchor/filter")
            mgr.performCollapse()
            return
        }
        guard let expanded = await StripCapture.capture(screen: screen, endX: endX,
                                                        filter: filter)
        else {
            trace("expanded capture failed")
            mgr.performCollapse()
            return
        }
        trace("expanded=\(expanded.width)x\(expanded.height) endX=\(Int(endX))")
        mgr.performCollapse()
        try? await Task.sleep(for: .milliseconds(700))
        guard mgr.isCollapsed, !mgr.flashing,
              let emptyShot = await StripCapture.capture(
                screen: screen, endX: mgr.toggleLeftX ?? endX, filter: filter)
        else {
            trace("empty capture failed or state changed")
            return
        }
        trace("empty=\(emptyShot.width)x\(emptyShot.height)")
        if let dir = ProcessInfo.processInfo.environment["FURL_DEBUG_DUMP"] {
            Self.writePNG(expanded, to: dir + "/cache-e.png")
            Self.writePNG(emptyShot, to: dir + "/cache-c.png")
        }

        let w = min(expanded.width, emptyShot.width)
        guard let e = Self.rightAligned(expanded, width: w),
              let c = Self.rightAligned(emptyShot, width: w),
              let s = StripCapture.leftmostChange(c, e), w - s > 60 else {
            trace("diff found nothing")
            return
        }
        trace("diff start=\(s) of w=\(w)")
        let cropX = max(0, s + (expanded.width - w) - 8)
        if let cropped = expanded.cropping(
            to: CGRect(x: cropX, y: 0,
                       width: expanded.width - cropX, height: expanded.height)) {
            cache = HiddenStrip(image: cropped, screen: screen, anchorX: endX)
            trace("cached \(cropped.width)x\(cropped.height)")
        }
    }

    // MARK: - The flash capture

    struct HiddenStrip {
        let image: CGImage      // 2x pixels, cropped to the hidden icons
        let screen: NSScreen
        let anchorX: CGFloat    // global AppKit x the image's right edge maps to
    }

    /// Collapsed-strip capture → brief un-furl → expanded capture → re-furl →
    /// diff to find where the hidden icons start → crop.
    static func ftrace(_ msg: String) {
        guard ProcessInfo.processInfo.environment["FURL_DEBUG_DUMP"] != nil else { return }
        let path = NSTemporaryDirectory() + "furl-flash-trace.log"
        let line = msg + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    static func captureHiddenStrip() async -> HiddenStrip? {
        let mgr = BarManager.shared
        guard mgr.isCollapsed,
              let screen = mgr.toggleScreen,
              let endX = mgr.toggleLeftX,
              let filter = await StripCapture.filter(for: screen),
              let before = await StripCapture.capture(screen: screen, endX: endX,
                                                      filter: filter)
        else { ftrace("guard failed collapsed=\(mgr.isCollapsed) anchor=\(mgr.toggleLeftX.map{Int($0)} ?? -1)"); return nil }
        ftrace("before=\(before.width)x\(before.height) endX=\(Int(endX))")

        // Other apps' icons reflow back asynchronously via WindowServer and
        // return PROGRESSIVELY over several hundred ms — so don't grab the
        // first frame that shows any change (that snapshots a partial set,
        // the "missing icons" bug). Wait until the strip STOPS changing
        // between consecutive captures, i.e. every icon has settled.
        mgr.beginFlash()
        var after: CGImage?
        var prev: CGImage?
        var stableCount = 0
        var sawIcons = false
        var endXNow = endX
        for _ in 0..<14 {   // up to ~2.8s
            try? await Task.sleep(for: .milliseconds(200))
            guard let x = mgr.toggleLeftX else { continue }  // mid-repack
            endXNow = x
            guard let shot = await StripCapture.capture(screen: screen, endX: endXNow,
                                                        filter: filter) else { continue }

            // Has the strip changed from the collapsed baseline yet?
            let wb = min(before.width, shot.width)
            if let b = Self.rightAligned(before, width: wb),
               let s = Self.rightAligned(shot, width: wb),
               let d = StripCapture.leftmostChange(b, s), wb - d > 60 {
                sawIcons = true
            }

            // Stable = two consecutive captures essentially identical.
            if sawIcons, let prev, prev.width == shot.width,
               let pc = Self.rightAligned(prev, width: shot.width),
               StripCapture.leftmostChange(pc, shot) == nil {
                stableCount += 1
                if stableCount >= 2 { after = shot; break }   // settled
            } else {
                stableCount = 0
            }
            prev = shot
            after = shot
        }
        mgr.endFlash()
        ftrace("loop done sawIcons=\(sawIcons) stable=\(stableCount) after=\(after.map { "\($0.width)" } ?? "nil")")

        guard let after else { return nil }
        // Crop from where the settled strip first differs from the empty bar.
        let w = min(before.width, after.width)
        guard let b = Self.rightAligned(before, width: w),
              let a = Self.rightAligned(after, width: w),
              let s = StripCapture.leftmostChange(b, a), w - s > 60 else {
            ftrace("final diff nothing")
            if let dir = ProcessInfo.processInfo.environment["FURL_DEBUG_DUMP"] {
                Self.writePNG(before, to: dir + "/before.png")
                Self.writePNG(after, to: dir + "/after.png")
            }
            return nil
        }
        let start = s + (after.width - w)
        ftrace("final start=\(s) cropped=\(after.width - max(0, start - 8))")

        if let dir = ProcessInfo.processInfo.environment["FURL_DEBUG_DUMP"] {
            Self.writePNG(before, to: dir + "/before.png")
            Self.writePNG(after, to: dir + "/after.png")
        }
        let cropX = max(0, start - 8)
        guard let cropped = after.cropping(
            to: CGRect(x: cropX, y: 0,
                       width: after.width - cropX, height: after.height))
        else { return nil }
        return HiddenStrip(image: cropped, screen: screen, anchorX: endXNow)
    }

    // MARK: - Click-through

    private func activate(offsetFromRight: CGFloat) {
        hide()
        clickThrough(offsetFromRight: offsetFromRight)
    }

    /// Reveal the real icons and forward a click to the one at `offset` from
    /// the anchor. Shared by the Furl Bar panel and the inline overlay.
    func clickThrough(offsetFromRight: CGFloat) {
        BarManager.shared.expandBrieflyForActivation()

        // Literal key: the kAXTrustedCheckOptionPrompt global isn't
        // concurrency-safe to touch under Swift 6.
        guard AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        else { return }  // not trusted: bar is expanded, user clicks the real item

        // The repack takes ~0.6s before the icons even exist on screen, plus
        // layout time — then click where the tapped icon now lives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            let mgr = BarManager.shared
            guard let anchor = mgr.toggleLeftX,
                  let screen = mgr.toggleScreen else { return }
            let barH = StripCapture.menuBarHeight(of: screen)
            let clickX = anchor - offsetFromRight
            // Never let a bad mapping click outside the status-item area
            // (e.g. onto the frontmost app's menus).
            guard clickX > screen.frame.midX, clickX < anchor else { return }
            let appKitY = screen.frame.maxY - barH / 2
            // AppKit (bottom-left origin) → CG global (top-left of main).
            let mainMaxY = NSScreen.screens.first { $0.frame.origin == .zero }?
                .frame.maxY ?? screen.frame.maxY
            let pt = CGPoint(x: clickX, y: mainMaxY - appKitY)
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                    mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                    mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    static func rightAligned(_ img: CGImage, width: Int) -> CGImage? {
        guard img.width > width else { return img }
        return img.cropping(to: CGRect(x: img.width - width, y: 0,
                                       width: width, height: img.height))
    }

    static func writePNG(_ image: CGImage, to path: String) {
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        return p
    }
}

// MARK: - View

private struct StripPanelView: View {
    let image: CGImage
    let maxWidth: CGFloat
    let onTap: (CGFloat) -> Void   // offset in points from the image's right edge

    var body: some View {
        let widthPts = CGFloat(image.width) / 2
        ScrollView(.horizontal, showsIndicators: widthPts > maxWidth) {
            Image(decorative: image, scale: 2)
                // Gesture on the image itself: location is in image space, so
                // the mapping is immune to scroll offset.
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    onTap(widthPts - value.location.x)
                })
        }
        .defaultScrollAnchor(.trailing)
        .frame(width: min(widthPts, maxWidth))
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1))
        .fixedSize()
    }
}
