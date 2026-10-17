# Parked: Den's Dock and widgets

Taken out of the app on 2026-10-14. It wasn't working well enough yet. Nothing here is compiled.

- `Dock.swift`: saved macOS Dock layouts (⌃⌥1…9) and Den's own Dock: open plus pinned apps, magnification, badges,
  minimized windows, full-screen hiding, the Appearance settings and the widget gallery.
- `Widgets.swift`: the widget cards (calendar, now playing, focus, system, battery, weather, …).
- `Checks.swift.txt`: their self-checks, which go back inside `selfCheck()` in `Sources/Check.swift`.

To bring it back, move the two Swift files into `Sources/`, then:

- Put back the wiring: the sidebar's `Dock` row (`mac:dock`), the `DockPane()` route in `ContentArea`, `"mac:dock"` in
  `ownPane` and in `title`, `DockController.shared.start(model)` at startup, the menu bar's Docks menu, and
  `--dock` in the snapshot harness.
- Before testing: "Den's Dock instead" changes the macOS Dock's
  `autohide` and `autohide-delay` settings, and the snapshot harness runs the real app. Check both before and after.

Its saved state is still on disk: `~/Library/Application Support/Den/docks.json` and the `dock*` keys in Den's
defaults.
