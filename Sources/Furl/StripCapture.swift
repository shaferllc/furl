import AppKit
import ScreenCaptureKit

/// Region capture of the menu bar strip via ScreenCaptureKit.
///
/// On modern macOS (Tahoe+) third-party status items are hosted by
/// WindowServer — anonymized and not capturable per-window, even with Screen
/// Recording. So Furl uses the flash technique Bartender itself used: briefly
/// un-furl the real bar, capture the strip, re-furl, and diff against the
/// collapsed strip to isolate the hidden icons.
@MainActor
enum StripCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : NSStatusBar.system.thickness + 1
    }

    static func filter(for screen: NSScreen) async -> SCContentFilter? {
        guard hasPermission,
              let did = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == did })
        else { return nil }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    /// Capture the strip from the screen's left edge to `endX` (global AppKit
    /// x). Returns a 2x CGImage.
    static func capture(screen: NSScreen, endX: CGFloat,
                        filter: SCContentFilter) async -> CGImage? {
        let barH = menuBarHeight(of: screen)
        let width = endX - screen.frame.minX
        guard width > 10 else { return nil }
        let config = SCStreamConfiguration()
        // sourceRect is display-relative, top-left origin, in points.
        config.sourceRect = CGRect(x: 0, y: 0, width: width, height: barH)
        config.width = Int(width) * 2
        config.height = Int(barH) * 2
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }

    // MARK: - Pixel comparison

    static func rgba(_ img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    /// Leftmost pixel column where the two equally-sized strips differ
    /// noticeably; nil when they match (nothing was hidden). Tolerates a few
    /// px of horizontal drift between the shots (the bar re-packs between
    /// them), otherwise a 2px shift flags every column including the app
    /// menus.
    static func leftmostChange(_ a: CGImage, _ b: CGImage) -> Int? {
        guard a.width == b.width, a.height == b.height,
              let pa = rgba(a), let pb = rgba(b) else { return 0 }
        let w = a.width, h = a.height
        let rows = Array(stride(from: 2, to: max(3, h - 2), by: 6))

        func colDiff(_ xa: Int, _ xb: Int) -> Int {
            var total = 0
            for y in rows {
                let ia = (y * w + xa) * 4, ib = (y * w + xb) * 4
                total += abs(Int(pa[ia]) - Int(pb[ib]))
                    + abs(Int(pa[ia + 1]) - Int(pb[ib + 1]))
                    + abs(Int(pa[ia + 2]) - Int(pb[ib + 2]))
            }
            return total / rows.count
        }

        for x in 0..<w {
            var minDiff = Int.max
            for dx in -4...4 {
                let xa = min(max(x + dx, 0), w - 1)
                minDiff = min(minDiff, colDiff(xa, x))
                if minDiff < 25 { break }
            }
            if minDiff >= 25 { return x }
        }
        return nil
    }

    /// Coarse fingerprint of a strip for the update watcher: 48×8 grayscale.
    static func signature(of image: CGImage) -> [UInt8] {
        let w = 48, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return pixels }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }

    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        let mad = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / a.count
        return mad > 6
    }
}
