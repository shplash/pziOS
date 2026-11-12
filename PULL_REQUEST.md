# Pull request: switch the touch layout by itself when you get in a vehicle

Copy the title and the body below into the pull request. This file is only a
helper: delete it (or leave it out of the PR) so the change itself stays the
four files listed at the end.

**Base:** `onlyknt/pziOS:main` · **Compare:** `shplash:vehicle-layout-switch`

---

## Title

Switch the touch layout by itself when you get in a vehicle

## Body

The on-screen controls can only be one layout at a time, and driving needs
different ones than walking around. This adds a second saved layout and swaps
between them by itself: while you are in a vehicle the driving layout is on
screen, and the normal one comes back when you get out. A DRIVE button switches
by hand in either direction.

How it works:

- `GameScripts/pziOSDrive.lua` writes `1` to `pzios_vehicle.txt` while the player
  is in a vehicle and `0` on foot, only when that changes. `main.m` installs it
  next to `pziOSSafeArea.lua` at every start and clears the marker from the last
  session so the game always begins on the normal layout.
- The overlay (`native/glfw-ios/glfw_ios.m`) polls that marker twice a second,
  swaps the saved layout when the state changes, and ignores a state it is
  already showing, so pressing DRIVE by hand is respected until you next get in
  or out of a car. If a driving layout has no way back, a FOOT button is added
  rather than leaving the player stuck.
- The touch editor gains the second layout with its own saved presets and an
  On foot / Driving switch, plus a DRIVE control to place on either layout. The
  launcher gets an "Edit driving layout" entry.

The driving layout has no joystick on purpose: steering is A and D, so the game
turns the wheel itself, with gas, brake and a held E-brake next to it.

Nothing else changes: the existing touch layout, presets, aim stick, margins
and JIT behaviour are untouched, and a player who never gets in a vehicle sees
exactly the layout they had before.

Files:

- `HostApp/GameScripts/pziOSDrive.lua` (new)
- `HostApp/Sources/main.m`
- `HostApp/Sources/ControlsEditor.swift`
- `HostApp/Sources/LauncherView.swift`
- `native/glfw-ios/glfw_ios.m`
