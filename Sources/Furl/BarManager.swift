import AppKit

/// Owns Furl's status items and the hide/show mechanics.
///
/// The technique (no permissions needed): Furl places a "divider" NSStatusItem
/// in the menu bar. Third-party icons the user ⌘-drags to the LEFT of the
/// divider become hideable. Collapsing sets the divider's length to 10,000pt,
/// which pushes everything left of it off the screen edge. An optional second
/// divider creates an "always hidden" zone that stays tucked away even when
/// the bar is expanded (revealable with ⌥-click).
@MainActor
final class BarManager: NSObject, NSMenuDelegate {
    static let shared = BarManager()

    private let statusBar = NSStatusBar.system
    private var toggleItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var alwaysHiddenItem: NSStatusItem?

    private(set) var isCollapsed = false
    private(set) var flashing = false
    private var revealingAlwaysHidden = false
    private var autoCollapseTimer: Timer?
    private var hoverCatcher: HoverCatcher?
    private var menuOpen = false

    // Hover-the-bar reveal: a NSEvent.mouseLocation poller (needs no
    // permissions, unlike CGEvent taps). Dwell counters debounce both edges.
    private var mouseTimer: Timer?
    private var inBarSamples = 0
    private var outBarSamples = 0
    private var expandedByHover = false

    private static let hiddenLength: CGFloat = 10_000
    private static let dividerLength: CGFloat = 8

    // MARK: - Lifecycle

    func start() {
        createItems()
        if Prefs.startCollapsed { collapse(cacheRefresh: false) } else { expand() }
        if Prefs.hoverExpand { startMouseWatcher() }
        FurlBar.shared.loadPersistedCache()

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BarManager.shared.applyPrefs() }
        }
    }

    /// Pin our items at the far right, next to the system icons. Left is where
    /// the notch lives on MacBooks — icons that end up under it are hidden AND
    /// unclickable, which would make the chevron unreachable. Preferred
    /// positions are measured from the right screen edge and only read at item
    /// creation. Reseed on EVERY launch: macOS continuously persists positions
    /// from the live window origins, and while the divider is stretched to
    /// 10,000pt its origin is nonsense — a kill/crash in that state would
    /// otherwise anchor it mid-screen forever.
    private func seedPositions() {
        let d = UserDefaults.standard
        d.set(1, forKey: "NSStatusItem Preferred Position furl_toggle")
        d.set(20, forKey: "NSStatusItem Preferred Position furl_divider")
        d.set(48, forKey: "NSStatusItem Preferred Position furl_always_hidden")
    }

    private func createItems() {
        seedPositions()
        // Creation order matters on first run: each new item lands to the LEFT
        // of the previous one, giving  ⟨toggle⟩ ⟨divider⟩ ⟨always-hidden⟩
        // right-to-left. Autosave names persist any user re-arrangement.
        let toggle = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = "furl_toggle"
        if let b = toggle.button {
            b.image = Self.chevron(collapsed: isCollapsed)
            b.target = self
            b.action = #selector(toggleClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            let catcher = HoverCatcher { [weak self] in
                guard let self, Prefs.hoverExpand, self.isCollapsed, !self.flashing
                else { return }
                if InlineOverlay.shared.isVisible { return }
                if StripCapture.hasPermission {
                    self.revealInline(autoHide: false)
                } else {
                    self.expand()
                    self.expandedByHover = true
                }
            }
            b.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: catcher))
            hoverCatcher = catcher
        }
        toggleItem = toggle

        createDivider()

        if Prefs.alwaysHiddenZone { createAlwaysHiddenItem() }
    }

    private func createAlwaysHiddenItem() {
        guard alwaysHiddenItem == nil else { return }
        let item = statusBar.statusItem(withLength: Self.hiddenLength)
        item.autosaveName = "furl_always_hidden"
        item.button?.image = Self.dividerImage(dashed: true)
        item.button?.appearsDisabled = true
        alwaysHiddenItem = item
    }

    private func removeAlwaysHiddenItem() {
        guard let item = alwaysHiddenItem else { return }
        statusBar.removeStatusItem(item)
        alwaysHiddenItem = nil
    }

    // MARK: - Collapse / expand

    /// Manual toggle (click, hotkey, menu): an expand here sticks until
    /// auto-collapse rather than re-furling when the pointer leaves the bar.
    /// In Furl Bar mode the inline bar stays furled and the panel toggles
    /// instead — revealing inline on a notch Mac just shoves icons back
    /// under the notch.
    func toggle() {
        if isCollapsed {
            if InlineOverlay.shared.isVisible {
                InlineOverlay.shared.hide()
            } else if StripCapture.hasPermission {
                revealInline(autoHide: true)                 // scrollable inline
            } else {
                requestCaptureOnce()                         // no grant → real, ask once
                expand()
                expandedByHover = false
            }
        } else {
            collapse()
        }
    }

    private var promptedForCapture = false
    private func requestCaptureOnce() {
        guard !promptedForCapture else { return }
        promptedForCapture = true
        StripCapture.requestPermission()
    }

    /// Scrollable inline reveal: a cached copy of the hidden icons faded onto
    /// the bar row (scrolls when they don't all fit beside the notch). Uses
    /// the cache when present (instant); otherwise flash-captures once.
    private func revealInline(autoHide: Bool) {
        if let cache = FurlBar.shared.cache {
            InlineOverlay.shared.show(cache, autoHide: autoHide)
            return
        }
        Task { @MainActor in
            if let strip = await FurlBar.captureHiddenStrip() {
                FurlBar.shared.cache = strip
                InlineOverlay.shared.show(strip, autoHide: autoHide)
            } else {
                expand()   // capture failed — fall back to real un-hide
            }
        }
    }

    /// Keep the chevron glyph in sync with overlay-based reveals.
    func setChevron(expanded: Bool) {
        toggleItem?.button?.image = Self.chevron(collapsed: !expanded)
    }


    /// A watched hidden icon changed: surface it.
    func revealForUpdate() {
        if Prefs.furlBar {
            if !FurlBar.shared.isVisible {
                Task { await FurlBar.shared.show(auto: true) }
            }
        } else if isCollapsed {
            expand()
            expandedByHover = false
        }
    }

    /// Furl Bar click-through: reveal inline so the real item exists on
    /// screen to click; auto-collapse re-furls afterwards.
    func expandBrieflyForActivation() {
        expand()
        expandedByHover = false
    }

    // MARK: - Flash (capture) support

    /// Capture anchor: the toggle chevron's left edge. The toggle is thin and
    /// right-pinned so this is stable in every state — unlike the stretched
    /// divider, whose window WindowServer parks at x ≈ -2×screen-width while
    /// furled, making its frame useless as an anchor.
    var toggleScreen: NSScreen? { toggleItem?.button?.window?.screen }
    var toggleLeftX: CGFloat? { toggleItem?.button?.window?.frame.minX }

    /// Briefly un-furl so a capture can see the hidden icons, without touching
    /// collapse state, timers, or hover bookkeeping.
    func beginFlash() {
        flashing = true
        repack()
    }

    private func createDivider() {
        let divider = statusBar.statusItem(withLength: Self.dividerLength)
        divider.autosaveName = "furl_divider"
        divider.button?.image = Self.dividerImage(dashed: false)
        divider.button?.appearsDisabled = true
        dividerItem = divider
    }

    func endFlash() {
        if isCollapsed {
            dividerItem?.length = Self.hiddenLength
            toggleItem?.button?.image = Self.chevron(collapsed: true)
        }
        flashing = false
    }

    /// `cacheRefresh: false` for the launch collapse: at that moment the
    /// icons' positions are mid-resort and a capture sees an empty bar.
    func collapse(cacheRefresh: Bool = true) {
        guard orderIsValid() else { repairOrder(); return }
        // The icons are on screen RIGHT NOW — the free moment to photograph
        // them for the Furl Bar, so opening it later needs no flash at all.
        // Refresh the icon-strip cache for the inline reveal (free — the icons
        // are on screen right now, about to hide).
        if cacheRefresh, !isCollapsed, !flashing, StripCapture.hasPermission {
            Task { await FurlBar.shared.cacheThenCollapse() }
        } else {
            performCollapse()
        }
    }

    func performCollapse() {
        isCollapsed = true
        revealingAlwaysHidden = false
        expandedByHover = false
        dividerItem?.length = Self.hiddenLength
        alwaysHiddenItem?.length = Self.hiddenLength
        toggleItem?.button?.image = Self.chevron(collapsed: true)
        cancelAutoCollapse()
    }

    func expand(revealAll: Bool = false) {
        isCollapsed = false
        revealingAlwaysHidden = revealAll
        repack { [self] in
            if revealAll { alwaysHiddenItem?.length = Self.dividerLength }
            scheduleAutoCollapse()
        }
    }

    /// Tahoe's asymmetry: growing the divider pushes icons off-screen fine,
    /// but neither shrinking it, swapping button images, bouncing isVisible,
    /// nor removing the divider alone makes WindowServer bring them back.
    /// The only in-process trigger found: remove EVERY Furl status item, give
    /// WindowServer a beat to re-pack the bar, then recreate our items.
    /// Last toggle frame that was actually laid out on screen. Freshly
    /// created items report x=0 until WindowServer positions them, so the
    /// live frame can't always be trusted.
    private var lastGoodToggleFrame: NSRect?

    private func noteToggleFrame() {
        if let f = toggleItem?.button?.window?.frame,
           let s = toggleItem?.button?.window?.screen,
           f.minX > s.frame.midX {
            lastGoodToggleFrame = f
        }
    }

    private func repack(then completion: @escaping @MainActor () -> Void = {}) {
        // The re-pack requires our item count to hit zero, which would blink
        // the chevron out — cover its exact spot with a fake for the gap.
        noteToggleFrame()
        let coverFrame = lastGoodToggleFrame
        removeAllItems()
        if let coverFrame {
            ChevronCover.shared.show(at: coverFrame,
                                     image: Self.chevron(collapsed: false))
        }
        // WindowServer needs real time to re-pack the other apps' items;
        // recreating ours too soon cancels the re-pack and they stay hidden.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            createItems()
            // Re-apply current state to the fresh items.
            toggleItem?.button?.image = Self.chevron(collapsed: isCollapsed && !flashing)
            if isCollapsed && !flashing { dividerItem?.length = Self.hiddenLength }
            completion()
            hideCoverWhenToggleReady()
        }
    }

    /// Keep the cover up until the recreated chevron is verifiably laid out —
    /// a fixed delay raced the layout and blinked.
    private func hideCoverWhenToggleReady(checks: Int = 0) {
        let ready = toggleItem?.button?.window.map {
            $0.frame.minX > ($0.screen?.frame.midX ?? 0)
        } ?? false
        if ready || checks > 20 {
            noteToggleFrame()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                ChevronCover.shared.hide()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                hideCoverWhenToggleReady(checks: checks + 1)
            }
        }
    }

    /// Experiment: is the re-pack trigger removing the RIGHTMOST item rather
    /// than all items? Shrink divider, remove only the toggle.
    func debugRemoveToggleOnly() {
        dividerItem?.length = Self.dividerLength
        if let toggleItem {
            statusBar.removeStatusItem(toggleItem)
            self.toggleItem = nil
        }
    }

    func removeAllItems() {
        if let toggleItem {
            statusBar.removeStatusItem(toggleItem)
            self.toggleItem = nil
        }
        if let dividerItem {
            statusBar.removeStatusItem(dividerItem)
            self.dividerItem = nil
        }
        removeAlwaysHiddenItem()
    }

    /// True when the pointer is in the menu bar strip (any display) or inside
    /// `rect` — reveals must not close under a hovering pointer.
    static func pointerOverBar(orIn rect: NSRect? = nil) -> Bool {
        let loc = NSEvent.mouseLocation
        if let rect, rect != .zero, rect.insetBy(dx: -20, dy: -20).contains(loc) {
            return true
        }
        guard let screen = NSScreen.screens.first(where: {
            loc.x >= $0.frame.minX && loc.x <= $0.frame.maxX
                && loc.y >= $0.frame.minY && loc.y <= $0.frame.maxY + 1
        }) else { return false }
        let barH = StripCapture.menuBarHeight(of: screen)
        return loc.y >= screen.frame.maxY - barH
    }

    private func scheduleAutoCollapse() {
        cancelAutoCollapse()
        guard Prefs.autoCollapse, !menuOpen else { return }
        autoCollapseTimer = Timer.scheduledTimer(
            withTimeInterval: max(2, Prefs.autoCollapseDelay), repeats: false
        ) { _ in
            MainActor.assumeIsolated {
                let mgr = BarManager.shared
                guard !mgr.isCollapsed, !mgr.menuOpen else { return }
                // Hovering the icons means "keep them open" — check again later.
                if Self.pointerOverBar() {
                    mgr.scheduleAutoCollapse()
                } else {
                    mgr.collapse()
                }
            }
        }
    }

    private func cancelAutoCollapse() {
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
    }

    private func applyPrefs() {
        if Prefs.alwaysHiddenZone {
            createAlwaysHiddenItem()
            if isCollapsed || !revealingAlwaysHidden {
                alwaysHiddenItem?.length = Self.hiddenLength
            }
        } else {
            removeAlwaysHiddenItem()
        }
        if !isCollapsed { scheduleAutoCollapse() }
        Prefs.hoverExpand ? startMouseWatcher() : stopMouseWatcher()
        UpdateWatcher.shared.applyPrefs()
    }

    // MARK: - Hover-the-bar reveal

    private func startMouseWatcher() {
        guard mouseTimer == nil else { return }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            MainActor.assumeIsolated { BarManager.shared.pollMouse() }
        }
    }

    private func stopMouseWatcher() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        inBarSamples = 0
        outBarSamples = 0
    }

    private func pollMouse() {
        guard !menuOpen, !flashing else { return }
        noteToggleFrame()
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            loc.x >= $0.frame.minX && loc.x <= $0.frame.maxX
                && loc.y >= $0.frame.minY && loc.y <= $0.frame.maxY
        }) else { return }

        // Menu bar strip height: the notch makes it taller than the standard
        // 24pt, and safeAreaInsets reports it per screen.
        let barH = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : NSStatusBar.system.thickness + 1
        let inBar = loc.y >= screen.frame.maxY - barH
        // Only the status-item half triggers a reveal, so parking the pointer
        // on the app menus (left side) doesn't churn the bar.
        let inTriggerZone = inBar && loc.x >= screen.frame.midX

        // Inline reveal is open: close it when the pointer leaves the bar.
        if InlineOverlay.shared.isVisible {
            if ProcessInfo.processInfo.environment["FURL_DEBUG_PANELHOLD"] == "1" { return }
            let over = InlineOverlay.shared.frame.insetBy(dx: -20, dy: -20).contains(loc)
            outBarSamples = (inBar || over) ? 0 : outBarSamples + 1
            if outBarSamples >= 3 {
                outBarSamples = 0
                InlineOverlay.shared.hide()
            }
            return
        }

        if isCollapsed {
            inBarSamples = inTriggerZone ? inBarSamples + 1 : 0
            if inBarSamples >= 2 {   // ~0.24s dwell
                inBarSamples = 0
                if StripCapture.hasPermission {
                    revealInline(autoHide: false)
                } else {
                    expand()
                    expandedByHover = true
                }
            }
        } else if expandedByHover {
            outBarSamples = inBar ? 0 : outBarSamples + 1
            if outBarSamples >= 3 {  // ~0.36s clear of the bar
                outBarSamples = 0
                collapse()
            }
        }
    }

    // MARK: - Ordering guard

    /// True when the divider sits left of the toggle chevron. If a drag has put
    /// the divider to the right, collapsing would hide our own chevron.
    private func orderIsValid() -> Bool {
        guard let t = toggleItem?.button?.window?.frame,
              let d = dividerItem?.button?.window?.frame else { return true }
        return d.minX <= t.minX
    }

    /// Swap the saved positions so the divider lands left of the chevron, then
    /// rebuild the items (positions are only read at creation time).
    private func repairOrder() {
        let d = UserDefaults.standard
        let tKey = "NSStatusItem Preferred Position furl_toggle"
        let dKey = "NSStatusItem Preferred Position furl_divider"
        let t = d.double(forKey: tKey)
        let s = d.double(forKey: dKey)
        // Preferred positions grow leftward from the right screen edge.
        if s <= t {
            d.set(max(t, s), forKey: dKey)
            d.set(min(t, s), forKey: tKey)
            if t == s { d.set(t + 40, forKey: dKey) }
        }
        rebuild()
        collapse()
    }

    private func rebuild() {
        if let toggleItem { statusBar.removeStatusItem(toggleItem) }
        if let dividerItem { statusBar.removeStatusItem(dividerItem) }
        removeAlwaysHiddenItem()
        toggleItem = nil
        dividerItem = nil
        createItems()
    }

    // MARK: - Click handling

    @objc private func toggleClicked() {
        guard let event = NSApp.currentEvent else { toggle(); return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else if event.modifierFlags.contains(.option) {
            // ⌥-click: peek at the always-hidden zone too.
            isCollapsed || !revealingAlwaysHidden ? expand(revealAll: true) : collapse()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let toggleTitle = isCollapsed ? "Show Hidden Icons" : "Hide Icons"
        menu.addItem(withTitle: toggleTitle, action: #selector(menuToggle), keyEquivalent: "")
            .target = self
        if Prefs.alwaysHiddenZone {
            let reveal = menu.addItem(withTitle: "Reveal Always-Hidden Icons",
                                      action: #selector(menuRevealAll), keyEquivalent: "")
            reveal.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Move Furl Next to the Clock", action: #selector(menuResetPosition),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Welcome Guide", action: #selector(menuOnboarding), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "About Furl", action: #selector(menuAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Furl", action: #selector(menuQuit), keyEquivalent: "q")
            .target = self

        // Attach, pop, detach — keeps left-click as a plain action button.
        toggleItem?.menu = menu
        toggleItem?.button?.performClick(nil)
        toggleItem?.menu = nil
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuGrantCapture() {
        StripCapture.requestPermission()
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func menuResetPosition() {
        seedPositions()
        let wasCollapsed = isCollapsed
        rebuild()
        wasCollapsed ? collapse() : expand()
    }
    @objc private func menuRevealAll() { expand(revealAll: true) }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func menuSettings() {
        SettingsWindowController.show()
    }
    @objc private func menuOnboarding() { OnboardingWindowController.show() }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            BarManager.shared.menuOpen = true
            BarManager.shared.cancelAutoCollapse()
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            BarManager.shared.menuOpen = false
            if !BarManager.shared.isCollapsed { BarManager.shared.scheduleAutoCollapse() }
        }
    }

    // MARK: - Images

    private static func chevron(collapsed: Bool) -> NSImage? {
        let name = collapsed ? "chevron.compact.left" : "chevron.compact.right"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Furl")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        img?.isTemplate = true
        return img
    }

    /// A thin vertical line; dashed variant marks the always-hidden divider.
    private static func dividerImage(dashed: Bool) -> NSImage {
        let size = NSSize(width: 8, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            if dashed {
                path.setLineDash([2.5, 2.5], count: 2, phase: 0)
            }
            path.move(to: NSPoint(x: 4, y: 2))
            path.line(to: NSPoint(x: 4, y: 14))
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A borderless overlay that impersonates the chevron while the real status
/// items are removed during a repack (windows CAN sit over the menu bar at a
/// level above the status items — same trick ledge uses at the notch).
@MainActor
final class ChevronCover {
    static let shared = ChevronCover()

    private var window: NSWindow?
    private let imageView = NSImageView()

    func show(at frame: NSRect, image: NSImage?) {
        let w = window ?? makeWindow()
        window = w
        imageView.image = image
        w.setFrame(frame, display: true)
        w.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        imageView.imageAlignment = .alignCenter
        imageView.contentTintColor = .labelColor
        w.contentView = imageView
        return w
    }
}

/// Receives mouseEntered from a tracking area installed on the toggle button.
@MainActor
final class HoverCatcher: NSResponder {
    private let onEnter: () -> Void

    init(onEnter: @escaping () -> Void) {
        self.onEnter = onEnter
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onEnter() }
}
