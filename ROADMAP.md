# Axe Roadmap

Items roughly in priority order. Nothing here is scheduled — just things worth building.

---

## Notch indicator polish

The `NotchIndicatorPanel` is new in v2.7.4. Known edge cases to harden:

- Survive screen sleep/wake and display reconfiguration (panel should re-anchor after `NSApplicationDidChangeScreenParametersNotification`)
- Verify behaviour when a full-screen app covers the notch area
- Verify it doesn't appear on displays without a notch (need to guard on `screen.safeAreaInsets.top > 0`)

---

## Search / filter in sessions

The sessions list grows fast once Save & Axe All is part of the workflow. Add a filter field at the top of the Sessions tab — typing narrows the list by session name or app name in real time.

---

## App list grouping

Group running apps by category (Productivity, Creativity, Developer Tools, etc.) derived from `LSApplicationCategoryType` in each app's Info.plist. Makes the list scannable on a loaded machine (15+ apps). Collapse/expand groups with a disclosure triangle.

---

## Onboarding / first-launch flow

New users open Axe and see a blank list with no explanation. A lightweight first-run sequence — one or two tooltip-style callouts — would reduce drop-off:

1. "Press ⌘Z to open Axe from anywhere" (shown on first launch, dismissed on first overlay open)
2. "Click any app to kill it" (shown on first overlay open, auto-dismissed after first kill)

No modal wizard — inline, dismissable, shown once.

---

## Menubar icon badge

Show the running regular-app count as a small number badge on the menubar icon itself, mirroring the notch indicator but available in all three UI modes (popover, spotlight, notch). Uses `NSStatusItem` with a custom image drawn via `NSBezierPath`.
