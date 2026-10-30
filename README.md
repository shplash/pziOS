<h1 align="center">pziOS</h1>

<p align="center"><b>Project Zomboid Build 42 on your iPhone and iPad.</b></p>

<p align="center">
  <a href="https://github.com/onlyknt/pziOS/releases"><img src="https://img.shields.io/github/downloads/onlyknt/pziOS/total?label=Downloads&style=for-the-badge&color=5865F2&labelColor=111111" alt="Total downloads (live)"></a>
  &nbsp;
  <a href="https://github.com/onlyknt/pziOS/releases"><img src="https://img.shields.io/github/v/release/onlyknt/pziOS?include_prereleases&label=Release&style=for-the-badge&color=brightgreen&labelColor=111111" alt="Latest release"></a>
  &nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL3-yellow?style=for-the-badge&labelColor=111111" alt="MIT licence"></a>
  &nbsp;
  <img src="https://img.shields.io/badge/iOS-17%2B-blue?style=for-the-badge&labelColor=111111" alt="iOS 17 or later">
</p>

pziOS runs Project Zomboid (Build 42) on an iPhone or iPad. It is a launcher
plus the runtime the game needs: a Java virtual machine built for iOS, an OpenGL-to-Metal graphics
stack, and audio and input layers. It runs **your own copy** of the game; no game assets are
included or downloaded.

> [!NOTE]
> **Free and non-commercial.** pziOS is not for sale, not for profit, and not for distribution on
> any app store. You need to own Project Zomboid. Project Zomboid is a work of The Indie Stone;
> this project is not affiliated with or endorsed by them.

> [!WARNING]
> **Beta (0.9.0).** Tested on an iPhone 16 Pro Max (A18 Pro, iOS 27) and an iPad Pro 11-inch
> 2nd generation (A12Z, iPadOS 26.6.2). Everything else is untested. Expect rough edges.

## How it works

| Component | What it does |
|---|---|
| **pziOS launcher** (SwiftUI) | Imports your game, sets options, starts everything. |
| **JVM** **[OpenJDK 25](https://github.com/openjdk/jdk)** | Runs the game's Java code natively on iOS. |
| **JIT** ([StikJIT](https://github.com/StikDebug/StikJIT)) | Attaches a debugger so iOS permits JIT. |
| **[MetalANGLE](https://github.com/kakashidinho/metalangle)** | Translates OpenGL ES calls into Apple's Metal. |
| **[gl4es](https://github.com/ptitSeb/gl4es)** | Turns desktop OpenGL 2 into OpenGL ES. |
| **GL shim** (`native/glshim`) | Routes LWJGL's GL calls and fixes shaders. |
| **[ASTC encoder](https://github.com/ARM-software/astc-encoder)** | Compresses textures on first run, then caches. |
| **GLFW layer** (`native/glfw-ios`) | Provides the window, touch, controller and keyboard input. |
| **Audio shim** (`native/fmodhal`) | Maps macOS audio calls onto iOS audio. |
| **EGL proxy** (`native/eglproxy`) | Bridges gl4es and MetalANGLE's EGL calls. |
| **Library converter** (`scripts/`) | Converts the game's Mac libraries for iOS. |

iOS only lets an app run freshly compiled code while a debugger is attached, which is why the JIT
step exists.

## Features

**Your own copy of the game.** Solo, mods, saves and direct-connect multiplayer. pziOS ships no game content; you
import yours.

**Runtime**
- Native **OpenJDK 25 for iOS**: the game's Java runs in-process, with no emulation layer underneath it.
- **JIT either way**: manual (run the bundled script in StikDebug) or built-in (a pairing file and the helper
  extension). The classic code-cache path is chosen automatically on iOS 17 and 18, JIT can be tested from the
  launcher, and the Developer Disk Image cache can be reset.
- **Memory tiers** picked from what iOS actually grants the app, plus **Increased Memory** (the Java heap held in
  helper processes) at 3–6 GB for devices that can spare it.
- **Four garbage collectors** — Parallel, pzGC, SGC and pzSGC — each explained where you choose it, and each a trial
  that falls back to Parallel by itself if the game then fails to start.
- **Three JIT compiler tiers** (C1, C1+C2 gentle, C1+C2 full), with the code-cache thresholds tuned to match.

**Graphics**
- gl4es and MetalANGLE by default, plus an experimental **Zink** backend (desktop OpenGL 4.5 over MoltenVK) for mods
  that need it, with a feature probe and a performance log.
- **ASTC texture compression** on the GPU with a persistent disk cache, a texture-shrink preset, and optional 2×
  (high definition) texture packs.
- Render resolution at **540p, 720p, 900p or 1080p**, ProMotion up to **120 Hz**, and a simulated aspect ratio for
  checking iPad layouts on a phone.
- Game options applied on every launch: `texture2x` follows your setting whenever the high definition packs are
  installed, and the game's preview videos stay off because the library they need is macOS-only.
- The game's macOS **FMOD** libraries bridged onto iOS audio, with the audio session configured before it starts.

**Game files**
- **Import a zip or a folder**: the importer finds `projectzomboid.jar`, then the data folder beside it that holds
  `media/`, and copies only what the game needs — Mac executables, libraries and Finder clutter are skipped.
- **Resumable and cancellable**: files are written as `.part` and moved into place, unchanged files are skipped, so
  starting again continues where it stopped. Free space is checked before it begins.
- A **native-library check** compares the imported game's libraries with the ones built into the app and says so if
  the game has been updated beyond what this build supports.
- The **Project Zomboid version** is read from the game and tied to a fingerprint of the installed jar, so a stale
  number is never shown. Game files and saves stay out of iCloud backup.

**Touch controls**
- A real **layout editor**: drag, resize, add, delete and relabel controls, set opacity from 5% to 100%, and save
  named layouts to switch between. Keyboard/mouse and virtual-gamepad layouts are edited separately.
- **Two-thumb play**: for any attack or shove button, *drag to aim* (dragging the held button also moves the cursor,
  at its own speed), *hold to lock* (the button stays held after you lift, e.g. for hands-free aiming) and *fire
  modes* (Default, Auto, Release). A **fire-mode toggle** control switches a chosen button between Default and
  Release in game.
- A **scroll strip** for containers and zoom, a **radial menu** holding 2–8 options in four shapes (ring, arc, column,
  row), and an **aim stick** with Off / Release / Auto attacks.
- **PAD and TCH pointer modes** (relative drag with tap, long press and two-finger right click, or direct touch), with
  a cursor speed setting and the two-finger zoom available or off.
- A **virtual gamepad**: the on-screen controls can drive a controller the game sees as real (two sticks, A/B/X/Y,
  d-pad, bumpers, triggers), with Xbox or PlayStation button names.
- On-screen controls **hide automatically** while a controller, or a keyboard and mouse together, are connected —
  or stay if you prefer.

**Real controllers**
- Any extended gamepad, hot-plugged at any time, **remappable** down to every button and axis, triggers usable as
  buttons, a **stick deadzone** (0–95%), **A/B swap** for Nintendo-style pads, a **live input preview** with battery
  level, and DualSense/DualShock touchpads that work as a mouse.
- The launcher itself can be navigated with a pad.

**Launcher**
- A home screen that tells you what matters: game files and build, JIT state, connected controller and battery,
  memory tier, and whether you are ready to play.
- Settings grouped by purpose, with the reason for every value spelled out, developer options behind a confirmation,
  and a Log page whose output you can share.
- A three-step **setup guide** with import progress, and a **screen margin editor** with a HUD preview.

**Diagnostics**
- `jvm.log` in the app's folder, rotated to `jvm-last.log` at every start so a crash survives a restart, plus
  optional memory logging and GPU texture accounting, and a Zink feature probe report.

**Building**
- An `xcodegen` project and scripts to build the native libraries, prepare and inject the game's libraries, build and
  sign an IPA, and rebuild for a different game build.
- CI that compiles the launcher on every push, and a workflow that builds the overlay and launcher and splices them
  into a release IPA for testing.

## Supported Devices

- **iPhone 12 Pro or later.**
- **iPad Pro A12z or later.**
- **iPad Air M1 or later.**
- **iPad Mini A17 Pro or later.**
- **iPad A16 or later.**
- Devices outside these bounds may run with **Increased Memory Limit** but results may vary.

## Requirements

- Supported iPhone or iPad on **iOS or iPadOS 17 or later** with **Developer Mode** turned on
  (Settings, Privacy & Security, Developer Mode).
- **Project Zomboid Build 42.21** for Mac. You need the game; pziOS only needs a copy of its files.
- About **5 GB** of free space for the game, plus about 250 MB for the app.
- **JIT**, set up in the app: either the built-in method (a pairing file for your device and a
  loopback VPN such as LocalDevVPN) or the included script in StikDebug. The pairing file can also be
  made with `idevice_pair` instead of the launcher.
- An **Apple ID** to sideload the app. A free account works, but its signing expires after 7 days,
  so the app has to be re-signed weekly. Your game files and saves are kept.
- A sideloading tool: Sideloadly, AltStore, Impactor or Xcode.

## Installing

1. Download **`pziOS-<version>-b42.21.ipa`** from the [latest release](https://github.com/onlyknt/pziOS/releases/latest)
   and sideload it with your own Apple ID.
2. On your Mac, **prepare the game files** (below), then AirDrop the zip to your device.
3. Open pziOS and follow the **Setup guide**: choose the zip, then set up JIT.
4. Press **Play**. The first start takes a while: the game loads and textures are compressed and cached.

### Prepare the game files

Find **Project Zomboid** on your Mac (Steam: Show in Finder), right-click it, choose
**Show Package Contents**, then right-click the **Contents** folder and choose **Compress**.
AirDrop the resulting `Contents.zip` to your iPhone or iPad. Compressing the whole app or the plain
game folder works too; pziOS searches the zip for `projectzomboid.jar`.

<p align="center">
  <img src="docs/assets/compress-for-airdrop.gif" alt="Compressing the Contents folder of Project Zomboid for AirDrop" width="720">
</p>

In pziOS tap **Choose zip or folder…** and pick the zip. Only the files the game needs are copied;
Mac executables and libraries are ignored.

### No Mac? Get the Mac version of the game with SteamCMD

pziOS needs the **macOS** copy of Project Zomboid: the Windows files do not match, and the game's
native libraries are matched to the Mac build. On Windows or Linux you can download the Mac depot
with [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD), using a Steam account that owns the game:

```
steamcmd +@sSteamCmdForcePlatformType macos +force_install_dir ./pz-mac +login <your steam user> +app_update 108600 validate +quit
```

Then zip the downloaded `Project Zomboid.app` folder (or its `Contents` folder) and move the zip to
your device.

### Manual JIT with StikDebug

If you do not use the built-in JIT, set **JIT Mode** to **Manual** in pziOS and use the script included in release.

1. Add the script to StikDebug's scripts.
2. Launch using StikDebug
3. In pziOS press **Play**.
4. The script attaches, hands the game its executable memory when it asks, and detaches.


## If something goes wrong

- **Black screen after Play**: make sure you installed the IPA that includes the game's libraries,
  and that JIT is on.
- **The game does not start or the app closes**: Settings, **Developer Tools**, Tools tab, then
  reset the launch arguments and try again.
- **Import fails**: the source has to be fully downloaded (not an iCloud placeholder) and there
  must be enough free space. You can cancel an import and start it again; finished files are kept.

**Bug reports**: open an issue with your device name and iOS version, the pziOS version shown at the
bottom of the launcher, what you did, and `jvm.log` (Files app, on your device, in the pziOS folder).
For a memory problem, turn on **Log Memory Use** in the Tools tab first, so the log carries the numbers.

## Building from source

The source tree has no binaries. [`docs/BUILDING.md`](docs/BUILDING.md) lists what to build and in
which order (the JRE, gl4es, MetalANGLE, StikJIT, our native libraries, then the app).
[`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md) describes the IPAs and what must stay out of them.

```sh
native/build-natives.sh      # our native libraries
scripts/make-ipa.sh          # an IPA without the game's libraries
scripts/build-release.sh "/path/to/Project Zomboid.app"   # both IPAs
```

**Your own identity**: bundle id, team id and display name come from
`HostApp/Config/Signing.xcconfig` (put your own values in `HostApp/Config/Signing.local.xcconfig`,
which git ignores). For an IPA, edit `release.config` in the repository root.

### Repository layout

| Path | Contents |
|---|---|
| `HostApp/` | The iOS app: SwiftUI launcher and settings, game importer, controls editor, setup guide, built-in JIT helper (`xcodegen` project in `project.yml`) |
| `native/glfw-ios/` | A GLFW 3.4 implementation for iOS (Metal layer view, touch, controller, keyboard and mouse input, on-screen controls) |
| `native/glshim/` | The OpenGL entry points LWJGL loads: routes to gl4es, ES-level shader fixes, ASTC texture compression with a disk cache |
| `native/eglproxy/` | A tiny library between gl4es and MetalANGLE; re-exports MetalANGLE and logs who destroys the display, context or surface |
| `native/fmodhal/` | Lets the game's macOS FMOD libraries run on iOS |
| `native/astc/` | C wrapper around ARM's astc-encoder |
| `patches/` | Patches for the iOS OpenJDK build |
| `scripts/` | Library conversion, IPA building and signing, the manual JIT script |
| `docs/` | Build, distribution, game file, JIT and performance guides |
| `licenses/` | Licence texts of the components we ship |

## Licensing and credits

The pziOS source code is under the [GPL-3 License](LICENSE). Third-party components keep their own
licences: they are listed in [`THIRD_PARTY.md`](THIRD_PARTY.md), their texts are in `licenses/`, and
the same texts are inside the app (`Licenses/`). The bundled JRE is OpenJDK (GPLv2 with the
Classpath Exception); each release attaches its complete source change set.

Thanks to the OpenJDK project, MetalANGLE, gl4es, ARM's astc-encoder, StikJIT,
Baconium's iOS JVM work, and to the LWJGL, FMOD and Project Zomboid teams whose libraries the game
runs on.
Thanks to **Claude** as a major contributor to the project.
**Project Zomboid is a trademark of The Indie Stone & not affiliated with pziOS.**
