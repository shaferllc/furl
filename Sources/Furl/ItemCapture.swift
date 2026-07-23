import AppKit
import ScreenCaptureKit

/// Captures a menu bar item's window image via ScreenCaptureKit. The
/// desktop-independent window filter renders a window's content even when
/// Furl has pushed it off-screen — this is what lets the Furl Bar show live
/// icons and the update watcher diff them. Requires the Screen Recording
/// permission (opt-in; macOS applies a grant on the app's next launch).
enum ItemCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func capture(windowID: CGWindowID) async -> CGImage? {
        guard hasPermission else { return nil }
        guard let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let win = content.windows.first(where: { $0.windowID == windowID })
        else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        config.width = max(2, Int(win.frame.width) * 2)
        config.height = max(2, Int(win.frame.height) * 2)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }

    /// 16×16 grayscale fingerprint for cheap change detection.
    static func signature(of image: CGImage) -> [UInt8] {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return pixels }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        let mad = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / a.count
        return mad > 8
    }
}
