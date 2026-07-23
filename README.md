# Furl

A native macOS menu bar manager — hide the icons you don't need, keep the bar
tidy. The Bartender category, built the house way: SwiftUI + AppKit, SwiftPM,
`make-app.sh`, no Xcode project, no external dependencies, **no special
permissions** (no screen recording, no accessibility).

*Furl (v.): to roll up and secure a sail.*

## How it works

Furl puts two items in the menu bar, pinned at the far **right** next to the
clock (deliberately: the left end is where the MacBook notch swallows icons
and makes them unclickable): a chevron `‹` and a divider `│`. Everything to
the **left** of the divider hides; ⌘-drag the icons you always want visible
to the right of the divider, next to the chevron. Collapsing stretches the
divider to 10,000pt, pushing everything left of it off the screen edge — the
same trick as Hidden Bar/Ice, which is why no permissions are needed.

## Features

- Click the chevron (or press **⌃⌥H** anywhere) to hide/show
- **Hover the menu bar** (right half, any display) to reveal — no click needed; re-furls when the pointer leaves
- **Smooth reveals**: the default reveal fades a cached capture of the icons
  into the bar row instantly (an overlay window over the menu bar) — the slow
  WindowServer re-pack only runs when you actually click an icon
- **Scroll back and forth**: when the revealed strip is wider than the clear
  run of bar right of the notch, it clips there and two-finger scrolls
  horizontally (right-anchored, left-edge fade hints at more)
- Icons **tuck away again automatically** after a configurable delay
- **Menu bar spacing** control (Compact/Default/Roomy) via the NSStatusItemSpacing global defaults — fits more icons clear of the notch
- **Furl Bar** (optional, off by default): hidden icons appear in a
  horizontally scrollable floating panel *below* the menu bar instead of
  expanding inline — they never shove visible icons back under the notch.
  Opens instantly from a strip photographed for free at each collapse
  (persisted across launches). Clicking one clicks the real item. Needs
  Screen Recording (+ Accessibility for click-through); falls back to the
  inline reveal without.
- **Show on update**: on a minutes cadence (off by default) Furl flash-checks
  the hidden icons and surfaces the bar when one changed (sync started,
  badge appeared)
- Optional **always-hidden zone** (second, dashed divider); ⌥-click to peek
- Launch at login, start collapsed, first-run welcome guide
- Settings: right-click the chevron → Settings…

## macOS Tahoe notes (hard-won)

- Third-party status items are WindowServer-hosted: anonymous in
  CGWindowList/SCShareableContent even with Screen Recording. Per-item window
  capture is impossible — Furl captures the bar *region* during a brief flash.
- Un-hiding is asymmetric: growing the divider hides icons, but the only way
  to bring them back is to remove ALL of Furl's items, let WindowServer
  re-pack (~0.6s), and recreate them (`BarManager.repack()`).
- The stretched divider's window parks at x ≈ -2×screen-width; anchor
  captures/click-mapping on the toggle chevron's frame, never the divider's.
- Positions are re-persisted from live window origins — Furl reseeds its
  preferred positions every launch.

## Build & run

```sh
./make-app.sh            # builds Furl.app onto the Desktop (ad-hoc signed)
./make-app.sh --install  # …and moves it to /Applications, launches it
```

## Layout

```
Sources/Furl/
  FurlApp.swift          @main, app delegate, hotkey, onboarding trigger
  BarManager.swift       status items + collapse/expand engine (the core)
  Prefs.swift            UserDefaults-backed settings
  SettingsView.swift     SwiftUI settings form (launch-at-login via SMAppService)
  OnboardingWindow.swift first-run welcome window
  HotKey.swift           Carbon global hotkey (house pattern)
make-icon.swift          draws AppIcon.icns programmatically
make-app.sh              bundles, signs, optionally installs
```
