import SwiftUI
import AppKit

/// Fake inline expansion: draws the cached strip of hidden icons directly
/// over the (empty) menu bar region left of the chevron, with a quick fade.
/// Instant and smooth — no WindowServer repack involved (the real one costs
/// 0.6s of dead time on Tahoe). Clicking an icon triggers the real reveal
/// underneath and forwards the click.
@MainActor
final class InlineOverlay {
    static let shared = InlineOverlay()

    private var window: NSWindow?
    private var hideTimer: Timer?
    private(set) var isVisible = false

    var frame: NSRect { (isVisible ? window?.frame : nil) ?? .zero }

    private func trace(_ msg: String) {
        guard ProcessInfo.processInfo.environment["FURL_DEBUG_DUMP"] != nil else { return }
        let path = NSTemporaryDirectory() + "furl-overlay-trace.log"
        let line = msg + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func show(_ strip: FurlBar.HiddenStrip, autoHide: Bool) {
        trace("show image=\(strip.image.width)x\(strip.image.height) anchor=\(Int(strip.anchorX)) screen=\(strip.screen.frame)")
        let widthPts = CGFloat(strip.image.width) / 2
        let screen = strip.screen
        let barH = StripCapture.menuBarHeight(of: screen)

        // Don't run under the notch (or, notchless, past mid-bar where the
        // app menus live) — clip there and let the content scroll instead.
        var leftBound = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        if let forced = ProcessInfo.processInfo.environment["FURL_DEBUG_MAXW"]
            .flatMap({ Double($0) }) {
            leftBound = strip.anchorX - CGFloat(forced)
        }
        let available = max(120, strip.anchorX - leftBound - 4)
        let overlayWidth = min(widthPts, available)
        let rect = NSRect(x: strip.anchorX - overlayWidth,
                          y: screen.frame.maxY - barH,
                          width: overlayWidth, height: barH)

        let view = OverlayStripView(image: strip.image, maxWidth: overlayWidth) {
            [weak self] offset in
            self?.activate(offsetFromRight: offset)
        }
        let w = window ?? makeWindow()
        window = w
        w.contentView = NSHostingView(rootView: view)
        w.setFrame(rect, display: true)
        w.alphaValue = 0
        w.orderFrontRegardless()
        trace("frame=\(w.frame) visible=\(w.isVisible)")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 1
        }
        isVisible = true
        BarManager.shared.setChevron(expanded: true)

        hideTimer?.invalidate()
        hideTimer = nil
        if autoHide, Prefs.autoCollapse { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: max(2, Prefs.autoCollapseDelay), repeats: false
        ) { _ in
            MainActor.assumeIsolated {
                let overlay = InlineOverlay.shared
                guard overlay.isVisible else { return }
                // Don't close under a hovering pointer — check again later.
                if BarManager.pointerOverBar(orIn: overlay.frame) {
                    overlay.scheduleAutoHide()
                } else {
                    overlay.hide()
                }
            }
        }
    }

    func hide() {
        guard isVisible, let w = window else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        isVisible = false
        BarManager.shared.setChevron(expanded: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if !InlineOverlay.shared.isVisible { w.orderOut(nil) }
            }
        })
    }

    private func activate(offsetFromRight: CGFloat) {
        hide()
        FurlBar.shared.clickThrough(offsetFromRight: offsetFromRight)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        return w
    }
}

/// The bare strip (its captured menu-bar background makes it seamless over
/// the real bar) with click mapping in image space. Wider than fits → scrolls
/// horizontally (two-finger swipe), anchored to the right end, with an edge
/// fade hinting at more content.
private struct OverlayStripView: View {
    let image: CGImage
    let maxWidth: CGFloat
    let onTap: (CGFloat) -> Void

    var body: some View {
        let widthPts = CGFloat(image.width) / 2
        let scrolls = widthPts > maxWidth + 1

        let strip = Image(decorative: image, scale: 2)
            // Gesture on the image: location is in image space, immune to
            // scroll offset.
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                onTap(widthPts - value.location.x)
            })

        Group {
            if scrolls {
                ScrollView(.horizontal, showsIndicators: false) { strip }
                    .defaultScrollAnchor(.trailing)
                    .frame(width: maxWidth)
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24)
                            Color.black
                        }
                    )
            } else {
                strip
            }
        }
    }
}
