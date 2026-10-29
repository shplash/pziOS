# Third-party components

pziOS uses the following projects. None of their binaries are committed here (Mesa and MoltenVK are only needed for the optional Zink backend); build or fetch them as described in `docs/BUILDING.md`.

| Component | Used for | Source | Licence |
|---|---|---|---|
| OpenJDK 25 | The JVM (built for iOS) | https://github.com/openjdk/jdk (tag jdk-25.0.1+8) + `openjdk-25.0.1+8-pzios-source.patch.gz` attached to each release | GPLv2 + Classpath Exception (`licenses/OpenJDK-GPLv2-with-Classpath-Exception.txt`) |
| Baconium/iOS-JVM-s | Patches and scripts to build OpenJDK for iOS | https://github.com/Baconium/iOS-JVM-s | see repository |
| gl4es | OpenGL 2.x to OpenGL ES (unmodified, commit ec16bed) | https://github.com/ptitSeb/gl4es | MIT (`licenses/gl4es-MIT.txt`) |
| MetalANGLE | OpenGL ES on Metal | https://github.com/kakashidinho/metalangle | BSD-3-Clause (`licenses/MetalANGLE-BSD-3-Clause.txt`) |
| astc-encoder | ASTC texture compression | https://github.com/ARM-software/astc-encoder | Apache-2.0 (`licenses/astc-encoder-Apache-2.0.txt`) |
| Mesa (Zink) | Optional experimental OpenGL 4.5 backend: OpenGL on Vulkan (26.2.5, patched, `patches/mesa-26.2.5-zink-pzios.diff`) | https://www.mesa3d.org / https://gitlab.freedesktop.org/mesa/mesa | MIT (`licenses/Mesa-MIT.txt`) |
| MoltenVK | Vulkan on Metal for the Zink backend (commit 5189f8d, patched, `patches/MoltenVK-5189f8d-pzios.diff`) | https://github.com/KhronosGroup/MoltenVK | Apache-2.0 (`licenses/MoltenVK-Apache-2.0.txt`) |
| SPIRV-Cross, SPIRV-Tools | Built into MoltenVK | https://github.com/KhronosGroup/SPIRV-Cross, https://github.com/KhronosGroup/SPIRV-Tools | Apache-2.0 (`licenses/SPIRV-Cross-Apache-2.0.txt`, `licenses/SPIRV-Tools-Apache-2.0.txt`) |
| cereal | Built into MoltenVK | https://github.com/USCiLab/cereal | BSD-3-Clause (`licenses/cereal-BSD-3-Clause.txt`) |
| StikJIT | Built-in JIT enabling (prebuilt `StikJIT.xcframework`, linked by the JIT helper) | https://github.com/StikDebug/StikJIT | MPL-2.0 (`licenses/StikJIT-MPL-2.0.txt`) |
| StikDebug | Only an optional external tool for the manual JIT script; not included or linked | https://github.com/StikDebug/StikDebug | AGPL-3.0 |
| GetMoreRam | Reference for the increased-memory-limit entitlement | https://github.com/hugeBlack/GetMoreRam | see repository |
| Zomdroid | Reference for the external controller remapping, stick deadzone, overlay toggle and live input preview (`HostApp/Sources/ControllerSettings.swift`, `ControllerEditor.swift`, and `pad_read` in `native/glfw-ios/glfw_ios.m`) | https://github.com/etonedemid/zomdroid- (fork of https://github.com/liamelui/zomdroid) | MIT (`licenses/Zomdroid-MIT.txt`) |

The release IPA also contains iOS-converted copies of the native libraries of Project Zomboid Build 42.21 (including FMOD by Firelight Technologies), which belong to their respective owners.

Project Zomboid is a trademark and work of The Indie Stone. pziOS is not affiliated with or endorsed by them and contains no game content.
