import AppKit
import CoreGraphics

/// One third-party menu bar item. Status items are ordinary windows at the
/// status-bar level (25), so CGWindowList enumerates them — owner, frame,
/// on/off-screen — with no permissions. Items Furl has hidden sit ~10,000pt
/// left of any screen.
struct BarItem: Identifiable, Hashable {
    let windowID: CGWindowID
    let ownerName: String
    let pid: pid_t
    let frame: CGRect   // CoreGraphics coords (top-left origin)
    let isHidden: Bool

    var id: CGWindowID { windowID }
}

enum ItemScanner {
    /// Owners that live in the system-reserved area or draw menu bar chrome;
    /// they aren't meaningfully hideable/clickable third-party items.
    private static let systemOwners: Set<String> = [
        "Window Server", "WindowServer", "SystemUIServer", "Control Center",
        "Notification Center", "NotificationCenter", "TextInputMenuAgent",
        "Spotlight", "Siri",
    ]

    static func scan() -> [BarItem] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let leftmostX = NSScreen.screens.map { $0.frame.minX }.min() ?? 0

        var items: [BarItem] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 25,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let wid = info[kCGWindowNumber as String] as? UInt32,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            guard pid != myPID, !systemOwners.contains(owner) else { continue }

            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                               width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            // Menu bar items are small; skip backing/overlay windows that
            // share the status level.
            guard frame.width > 6, frame.width < 500, frame.height < 45 else { continue }

            // Hidden = pushed far left of every screen by the 10,000pt divider.
            let isHidden = frame.minX < leftmostX - 100
            items.append(BarItem(windowID: wid, ownerName: owner, pid: pid,
                                 frame: frame, isHidden: isHidden))
        }
        // Left-to-right, hidden first (matches their real bar order).
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func hiddenItems() -> [BarItem] { scan().filter(\.isHidden) }
}
