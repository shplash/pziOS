# Performance notes

Frame time in pziOS comes from three places, in rough order of size:

1. **The game's Java** running on the JVM (C1 only by default, see the JIT Compiler setting).
2. **The graphics path**: the game calls desktop OpenGL, which gl4es turns into GLES, which MetalANGLE turns into Metal. Two translation layers means every draw, every uniform and every texture upload is touched twice.
3. **Textures**: the first launch compresses large textures to ASTC (~50 ms each) and writes a cache; later launches read the cache instead.

## What the GL layer does around every draw

`native/glshim/glshim.m` sits between gl4es and MetalANGLE, because gl4es' variants of the game's shaders do not line up with what the GLES driver really binds. Around each draw it:

- works out whether the bound program is a skinned (character) program,
- uploads the bone palette to the program that is actually used,
- optionally traces the draw (`ZOMIOS_SHADER_LOG` only).

Those three are on the hot path, so they now use plain C tables and reused buffers:

| Before | After |
|---|---|
| `NSNumber` + `NSDictionary` lookup to ask "is this program skinned", on every program switch and every draw | byte table indexed by program id |
| `NSNumber` + dictionary lookup to ask "does this program have the current palette", on every draw | unsigned table indexed by program id |
| `malloc` + `memcpy` + `free` of the palette copy, per skinned draw | one buffer, grown when the palette grows |
| `NSString` built with `stringWithFormat:` to recognise a driver-only uniform, per palette upload | fixed-size array of (program, location) pairs, scanned |
| `malloc` + `free` of the cached palette, per palette upload | one reused buffer |

Also fixed:

- `astc_in_set` used to take the state lock and probe an Objective-C set for every texture parameter call even when ASTC is off; it now returns immediately when it is off.
- `glfwMakeContextCurrent` logged every successful hand-over; on a build that renews the context every frame that is an unbuffered `stderr` write, a pipe write and a log append per frame. It now logs the first few and then only when the context moves to another thread.

## Settings that move the needle

- **Render Resolution** (Display): the biggest graphics lever; 540p is roughly a quarter of the pixels of 1080p.
- **Texture Compression** (Graphics) and **ASTC Compression** (Performance): lower texture memory, less memory bandwidth.
- **Memory Limit / Collector** (Performance): too small a heap means constant collection; `pzGC` keeps pauses near one frame.
- **Frame Autorelease Pool** (Tools, experimental): frees the graphics layer's per-frame objects at the buffer swap. In testing it removed a steady memory climb (~170 MB less after 2–3 minutes); it also costs a little per frame, so it is off by default.

## If frame time is bad in a specific spot

- Turn on **Log Memory Use** (Tools) and look for a footprint that only ever climbs.
- Turn on **Zink Detailed Log** only with the Zink backend; it costs a few writes every few seconds.
- Remove `-XX:-OmitStackTraceInFastThrow` from `Documents/launch.args` while testing: it makes the JVM build a full stack trace for every repeated exception, which is very expensive if the game or a mod throws in a hot loop. It is only worth keeping while diagnosing such a bug, and removing it is safe.
- `ZOMIOS_ASTC_QUALITY` (in `launch.args` as `@env`) lowers the ASTC encoder effort during a first launch; the cache makes later launches independent of it.

No frame-rate numbers are claimed here: this device could not run the game, and the numbers above come from the notes already in the repository (frame pool and memory tiers).
