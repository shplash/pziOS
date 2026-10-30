# Building

This is the order things are built in. Several steps depend on files from **your own copy** of Project Zomboid (Mac version) which cannot be shared.
Steps marked *(reconstructed)* were written from the maintainer's working notes and have not been replayed from scratch; open an issue if one fails.

## 0. Requirements

- Mac with Xcode (iOS 27 SDK used so far), `xcodegen`, `lipo`, `vtool`, `install_name_tool`.
- An iPhone or iPad with Developer Mode on. TXM devices (A17/M4 and newer) need the debugger-based JIT path.
- The game: Project Zomboid Build 42.21 for Mac (any copy of `Project Zomboid.app`).

## 1. The JVM (OpenJDK 25 for iOS)

The JRE shipped in releases is built from the upstream tag `jdk-25.0.1+8` plus the full source change set `openjdk-25.0.1+8-pzios-source.patch.gz` (attached to every release; it applies cleanly with `git apply` on that tag). It contains the iOS port (from Baconium/iOS-JVM-s), our TXM sandbox fix (`patches/4_txm_sandbox.diff`) and the ZGC address-space probe and diagnostics (`patches/5_*.diff`, `6_*.diff`). The steps below show the path without the full patch.

1. Check out https://github.com/Baconium/iOS-JVM-s and apply `patches/baconium-scripts-build.sh.diff` (build script paths).
2. Copy `patches/4_txm_sandbox.diff` next to the other iOS patches and build JDK 25 with its scripts. The result is a JRE folder (`bin/java`, `lib/`).
3. Place it at `HostApp/runtime/jre`. The Xcode build phase `sign_jre.sh` signs every Mach-O in it.

## 2. Graphics: gl4es and MetalANGLE

1. Build gl4es (commit `ec16bed`, no changes) for iOS arm64 as `libgl4es_114.dylib`. *(reconstructed: CMake with the iOS toolchain, GLES2 backend)*
2. Get `MetalANGLE.framework` for iOS (it ships inside PojavLauncher iOS builds, or build it from the MetalANGLE repository) into `HostApp/Frameworks/`.

## 3. Our native libraries

```
ASTC_SRC=/path/to/astc-encoder GL4ES_DYLIB=/path/to/libgl4es_114.dylib native/build-natives.sh
```

This builds `libglfw`, `libEGLproxy`, `libfmodhal` (twice, as `libfmodhal_ca` too) and `libGLshim` into `HostApp/runtime/natives/`.

## 3b. Optional: the Zink graphics backend (experimental)
Developer Tools has a switch "Graphics Backend: Zink (Experimental)" that runs the game on Mesa's Zink (OpenGL 4.5 on Vulkan) over MoltenVK (Vulkan on Metal) instead of gl4es + MetalANGLE. It exists for mods that need desktop OpenGL 4.5 (for example Viewpoint). It is slower and uses more memory than the normal path, so it is off by default. Without the three libraries below the switch does nothing useful, so leave them out if you do not want it.

Put these in `HostApp/runtime/natives/zink/`:
1. `libMoltenVK.dylib`: MoltenVK (commit `5189f8d`, Apache-2.0), patched with `patches/MoltenVK-5189f8d-pzios.diff` (reports up to 64 samplers per stage when Metal argument buffers are in use, because some mods need more than 16). Build: clone, `git apply` the patch, `./fetchDependencies --ios`, `make ios`, then copy `Package/Release/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK` and name it `libMoltenVK.dylib`.
2. `libEGL.1.dylib` and `libgallium-26.2.5.dylib`: Mesa 26.2.5 (MIT), patched with `patches/mesa-26.2.5-zink-pzios.diff` (`patch -p1`). Cross-compile for iOS with meson (Python 3.10+, `mako`, `pyyaml`, `ply`, a recent bison and flex) using a cross file that targets `iphoneos` arm64 with `system = 'darwin'`:
   `meson setup build-ios --cross-file ios-cross.txt -Dgallium-drivers=zink -Dvulkan-drivers= -Dplatforms=macos -Dglx=disabled -Degl=enabled -Dllvm=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=enabled -Dbuildtype=release -Dvideo-codecs= -Dtools= -Dzstd=disabled -Dspirv-tools=disabled -Dlibunwind=disabled -Dglvnd=disabled -Dmoltenvk-dir=<absolute path of MoltenVK's Package/Release/MoltenVK>`
   with `-DVK_USE_PLATFORM_IOS_MVK` added to the C, C++ and Objective-C arguments and `-lobjc -framework Foundation` to the link arguments, then `ninja -C build-ios`. Copy `src/egl/libEGL.1.dylib` and `src/gallium/targets/dri/libgallium-26.2.5.dylib`, and give both an `@loader_path` rpath (`install_name_tool -add_rpath @loader_path`; remove libEGL's build-tree rpath).
3. `libGLzink.dylib`: built by `native/build-natives.sh` (sources in `native/glzink`; `gen.py` regenerates `glzink.c` from Mesa's `GL/gl.h` and `GL/glext.h`).

## 4. The game's own native libraries

Run `scripts/retag.sh <in.dylib> <out.dylib>` on every `.dylib` in the game's `Contents/Java` (and the lwjgl/FMOD libraries it ships), writing the results into `HostApp/runtime/natives/`.
The libraries include FMOD, RakNet, jemalloc, the PZ pathfinding and bullet libraries and others. They are Mac builds; retagging marks them as iOS and flattens framework paths.

## 5. StikJIT

Get `StikJIT.xcframework` from the StikJIT project (https://github.com/StikDebug/StikJIT, MPL-2.0; see its integration guide) and place it at `HostApp/Frameworks/StikJIT.xcframework`. The JIT helper app extension links it on device builds only. (StikDebug, the app, is not needed unless you use the manual JIT script.)

## 6. The app

```
cd HostApp && xcodegen generate
open pziOS.xcodeproj      # scheme pziOS (device) or ZomUIPreview (simulator, launcher UI only)
```

Set your own team and bundle identifier in `project.yml`. Install, then use the in-app Setup guide for the game files and JIT.

## 7. Building in CI

`.github/workflows/build.yml` compiles the launcher UI target on every push that touches code (docs and Markdown are
skipped). The device target cannot be built from the repository alone, so this is the compile check for the Swift
sources.

`.github/workflows/ipa.yml` ("Patched IPA") produces a testable IPA without needing the JRE, MetalANGLE sources,
StikJIT or the game's libraries: it compiles `libglfw.dylib` and the launcher executable from this repository, then
swaps them into an official release IPA (chosen with the `release_tag` input, or the latest), keeping that release's
runtime and JIT helper, and re-signs the app ad hoc with the release's entitlements. Run it from the Actions tab; the
result is the `pziOS-ipa` artifact. It runs on the standard macOS runner and needs no particular Xcode version.

`scripts/make-ipa.sh` remains the way to build a complete IPA from your own binaries (steps 1-5) on a Mac; the
workflow above is the shortcut for testing launcher and overlay changes only.

`docs/FEATURES.md` lists what the app can do, and what is still open.
