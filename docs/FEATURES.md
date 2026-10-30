# Features

What this fork can do today, grouped by area. Things marked **new** were added here on top of upstream pziOS
0.9.0-beta.5; **experimental** means it exists but may not work on every device.

## Running the game

- **Native runtime, no emulation.** OpenJDK 25 built for iOS runs the game's Java in-process; the game's Mac
  native libraries are converted, not emulated.
- **JIT, two ways.** Manual (run the bundled script in StikDebug after pressing Play) or built-in (a pairing file
  plus the bundled helper extension and LocalDevVPN). On iOS 17 and 18 the classic code-cache path is chosen
  automatically; the Developer Disk Image cache can be reset and JIT can be tested from the launcher.
- **Memory.** Four heap tiers picked from what iOS actually grants the app; **experimental** Increased Memory
  (Java heap in helper processes) with 3–6 GB.
- **Garbage collectors.** Parallel, pzGC, SGC and pzSGC, each explained in the launcher, each a trial that falls
  back to Parallel by itself if the game fails to start.
- **JIT compiler tiers.** C1 only (default), C1+C2 gentle, C1+C2 full, with the code-cache thresholds tuned to
  match.
- **Graphics path.** gl4es + MetalANGLE by default; **experimental** Zink (Mesa OpenGL 4.5 over MoltenVK) for mods
  that need it, with a feature probe and a detailed log.
- **Textures.** ASTC compression on upload with a persistent disk cache, plus a texture-shrink preset; the 2×
  (high definition) packs are optional.
- **Display.** Render resolution 540p/720p/900p/1080p, ProMotion up to 120 Hz, and a simulated aspect ratio for
  checking iPad layouts on a phone.
- **Audio.** The game's macOS FMOD libraries are bridged onto iOS audio, with the audio session configured before
  the game starts.
- **Game options applied on every launch.** `texture2x` follows the launcher setting, and the game's preview
  videos stay off because the library they need is macOS-only.

## Game files

- **Import from a zip or a folder**: the importer finds `projectzomboid.jar`, then the folder beside it that holds
  `media/`, and copies only what the game needs — Mac executables, libraries, `__MACOSX` and Finder clutter are
  skipped.
- **Resumable and cancellable**: files are written as `.part` and moved into place, unchanged files are skipped, so
  starting again continues where it stopped.
- **Free-space check** before copying, with the reason spelled out when it fails.
- **Native library check**: the imported game's libraries are fingerprinted against the ones inside the app, and
  the launcher warns if the game has been updated beyond what the app was built with.
- **Build detection**: the Project Zomboid version is read from the game's `version.txt`, tied to a fingerprint of
  the installed jar so a stale number is never shown.
- Game files and saves are excluded from iCloud backup.

## On-screen controls

- **Layout editor**: drag controls anywhere, resize each one, add or remove them, rename them, set opacity from 5%
  to 100%, and save named layouts to switch between.
- **Two layouts**: one for keyboard and mouse, one for the virtual gamepad, edited independently.
- **Aim stick** with an attack mode: Off, Release (one attack when you let go) or Auto (held while pushed).
- **new — Two-thumb play**: per button, *drag to aim* (holding an attack or shove button and dragging also moves the
  cursor, with its own speed), *long press to lock* (button stays held after you lift, e.g. right-click aiming) and
  *fire modes*: Default, Auto (re-pressed while held) or Release (hold only aims, lift to fire once).
- **new — Fire mode toggle**: a small control that switches a chosen button between Default and Release in game.
- **new — Scroll strip**: a tall bar that sends mouse-wheel notches at the cursor, so containers scroll and the
  world zooms with one thumb; speed and direction are configurable.
- **new — Radial menus**: a control holding 2–8 options (any key, mouse button, keyboard toggle, hide/show, PAD/TCH,
  or a fire-mode toggle). Hold it and the options fan out; slide to one and let go; let go where you started to
  cancel; a quick tap sends an option you nominate. Four shapes (ring, arc, column, row), the last three opening
  away from the nearest edge, a 60–160% spacing control, and the whole menu kept on screen.
- **Pointer modes**: PAD (drag the cursor, tap to click, long press to hold, two-finger tap to right-click) and TCH
  (direct touch), with a cursor speed setting; the two-finger zoom can be turned off if it fires by accident.
- **On-screen controls hide** when a real controller (or a keyboard and mouse together) is connected — unless you
  keep them.
- **new — Virtual gamepad**: the on-screen controls can drive a synthetic controller the game sees as a real one
  (two sticks, A/B/X/Y, d-pad, bumpers, triggers), with Xbox or PlayStation button names. Real controllers then
  take the next slots.

## Real controllers

- Any extended gamepad, hot-plugged at any time, with the standard mapping by default.
- **new — Remap everything**: every button and axis, triggers usable as buttons, with a press-the-control-you-want
  screen.
- **new — Stick deadzone** (0–95%, applied radially with a rescale) so a drifting stick stops walking you into a
  horde.
- **new — A/B swap** for Nintendo-style pads.
- **new — Live input preview**: connected controllers with battery level in the launcher, and a screen showing live
  stick and trigger values and every pressed button.
- **new — Overlay auto-hide is optional**, for playing with a controller in one hand and touch buttons under the
  other.
- DualSense/DualShock touchpads work as a mouse; the launcher itself can be navigated with a pad.

## Launcher

- **new — Home screen** with a live status panel (game files and build, JIT mode and pairing state, connected
  controller and battery, memory tier), a ready/setup chip, and quick tiles for Settings, Game Files, Mods and the
  Setup guide.
- **new — Settings** grouped into pages with a short description each, an explanation of the *selected* value under
  every option, press feedback and haptics throughout, and Developer Tools gated behind a confirmation.
- **new — Log page** with a Share button (the current log, or the previous run's if this one is empty).
- **Setup guide** in three steps (game files, JIT, ready) with import progress and cancel.
- **Screen margin editor**: drag the four edges to the region the game UI may use, with a HUD mock-up and the Auto
  outline for reference.

## Diagnostics

- `jvm.log` in the app's folder, **new** rotated to `jvm-last.log` at every start so a crash survives a restart.
- Memory logging (footprint, Java heap, graphics, native), GPU texture accounting, shader and input logging, and a
  Zink feature probe that saves `zink-probe.txt`.

## Building and shipping

- `xcodegen` project, with scripts to build the native libraries, prepare and inject the game's libraries, build
  and sign an IPA, and rebuild with a different game build.
- **new — CI**: the launcher UI target builds on every push; a **Patched IPA** workflow compiles `libglfw.dylib`
  and the launcher executable and splices them into an official release IPA (keeping its JRE, graphics libraries
  and JIT helper), so a testable IPA can be produced without the JRE, StikJIT or Xcode 26.

## What this fork adds over upstream

| Area | Change |
|---|---|
| Launcher | Two-column home with live status; grouped settings with explanations; Share-log |
| Controllers | Remapping with live preview, stick deadzone, A/B swap, optional overlay hiding |
| Touch | Drag-to-aim, long-press lock, fire modes and toggle, scroll strip, radial menus, 5% opacity floor, uniform editor |
| Virtual gamepad | Actually wired to a synthetic GLFW joystick (was settings-only) |
| Settings that did nothing | Two-finger zoom, pad cursor sensitivity, aim-stick attack mode are applied |
| Runtime | Startup failures release the PLAY button; `jvm.log` rotation |
| Performance | GL hot path without per-draw allocations, strings or dictionary lookups; ASTC check short-circuits |
| Safety | EGL proxy null-checks resolved symbols and rate-limits tracing |
| Build | Launcher CI + patched-IPA workflow; `docs/PERFORMANCE.md` |

## Known limits

- One game installation; no per-build profiles or Build 41 support (each build needs its own converted natives).
- No controller rumble or light-bar support.
- The Zink backend is slower than the default path and is for specific mods.
- The classic JIT path (iOS 17/18) is implemented but far less tested than the iOS 26+ path.
- No custom icons or images per control, and no gesture-to-action mapping.
- Everything added in this fork is compiled by CI but has **not** been run on a device here.

## Open jobs

A tidy backlog, roughly in the order that pays off.

**Runtime and performance**
- Measure the GL hot path before/after on a real device and record the numbers in `docs/PERFORMANCE.md`.
- Decide whether the frame autorelease pool should default on (it removed a memory climb in testing).
- Controller rumble: check whether the game's input path can surface it.

**Touch controls**
- Test the two-thumb additions on hardware: drag-to-aim feel, lock timing, auto re-press rate.
- Add a "reset this control" action in the editor, next to delete.
- Optional: a confirm step for radial menus (release outside = cancel) for players who fire by accident.

**Launcher**
- Show which saved layout preset is active.
- Per-setting search in Settings once the page count grows.
- Surface the pairing/JIT state as a step-by-step hint when Play fails.

**Build and CI**
- Have the patched-IPA workflow run automatically on a tag and attach the result.
- Cache XcodeGen and the release IPA download between runs.
- Keep `docs/DISTRIBUTION.md` in step with whatever the patched-IPA workflow produces.

**Verification**
- Run the launcher on device and confirm controller remapping, the virtual gamepad, drag-to-aim, the scroll strip
  and radial menus; file issues for anything that misbehaves.
- Re-check the game's `options.ini` handling after a game update (the `texture2x` / video-effects keys).
