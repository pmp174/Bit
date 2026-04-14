# Plan: Port xemu to OpenEmu ("Bit") as Xbox Core Plugin

## Overview
Integrate xemu (QEMU-based Xbox emulator) as an `.oecoreplugin` for the Bit fork. xemu already has full macOS ARM64 support via QEMU's TCG JIT. We'll build it as a static library via Meson, then link into a plugin bundle with Objective-C++ bridge files following the PCSX2 integration pattern.

**Rendering:** Vulkan via MoltenVK (translates to Metal)
**Controllers:** 4 players from the start
**HDD:** Auto-create sparse QCOW2 on first launch

---

## Phase 1: System Plugin — Xbox

Create `OpenEmu/SystemPlugins/Xbox/` with button definitions, controller mappings, and system metadata.

### New files:
- `OpenEmu/SystemPlugins/Xbox/OEXboxSystemResponderClient.h` — Button enum (A/B/X/Y/White/Black/DPad/Start/Back/L3/R3/triggers/sticks = 24 entries) + `@protocol OEXboxSystemResponderClient`
- `OpenEmu/SystemPlugins/Xbox/OEXboxSystemController.h` — `@interface OEXboxSystemController : OESystemController`
- `OpenEmu/SystemPlugins/Xbox/OEXboxSystemController.m` — Disc detection (check for "MICROSOFT*XBOX*MEDIA" signature in ISO), serial extraction from XBE default.xbe header
- `OpenEmu/SystemPlugins/Xbox/OEXboxSystemResponder.h` — `@interface OEXboxSystemResponder : OESystemResponder`
- `OpenEmu/SystemPlugins/Xbox/OEXboxSystemResponder.m` — Route HID events to responder client methods
- `OpenEmu/SystemPlugins/Xbox/Xbox-Info.plist` — System identifier `openemu.system.xbox`, file suffixes `iso`/`xiso`, 4 players, optical disc media, control list with D-Pad + face buttons + White/Black + triggers + sticks + Start/Back/L3/R3
- `OpenEmu/SystemPlugins/Xbox/Controller-Mappings.plist` — Map standard controllers (Xbox Series, PS5 DualSense, etc.) to OEXbox buttons. White→LB, Black→RB on modern controllers
- `OpenEmu/SystemPlugins/Xbox/Controller-Preferences.plist` — Default controller preferences
- `OpenEmu/SystemPlugins/Xbox/Keyboard-Mappings.plist` — WASD + arrow keys + etc.

---

## Phase 2: Build System — xemu as Static Library

Build xemu via its existing Meson system but produce a static library instead of an executable.

### Steps:
1. Create `xemu/build-openemu.sh` — Build script that:
   - Runs `./configure --target-list=i386-softmmu --extra-cflags="-DOPENEMU=1" --disable-sdl --enable-opengl`
   - Runs `meson setup` / `ninja` targeting `i386-softmmu`
   - After build, collects all `.o` files and `ar` archives them into `libxemu.a`
   - Also builds MoltenVK if not already present (or expects it pre-built)

2. Create `xemu/OpenEmu/CMakeLists.txt` or Xcode project that:
   - Compiles the bridge `.mm`/`.c` files
   - Links against `libxemu.a`, MoltenVK, system frameworks (OpenGL, IOKit, CoreAudio, etc.)
   - Produces `XEMU.oecoreplugin` bundle

### Key build flags:
- `-DOPENEMU=1` — Guards around SDL-dependent code paths
- `--disable-sdl` — Don't link SDL3
- Keep OpenGL enabled (NV2A GL renderer as fallback)
- Link MoltenVK for Vulkan backend

---

## Phase 3: Stubs — SDL/UI Elimination

Create stubs to replace SDL3 and xemu UI dependencies that aren't needed in the plugin.

### New file: `xemu/OpenEmu/xemu_openemu_stubs.c`
Stub implementations for:
- All SDL functions referenced by xemu code not excluded by `--disable-sdl`
- `xemu_hud_init/update/render/should_skip_rendering` — empty/return false
- `xemu_toggle_fullscreen` — no-op
- `xemu_get_window` — return NULL
- `xemu_monitor_init` — no-op
- `xemu_queue_notification` — log to `/tmp/xemu_openemu.log`
- `xemu_net_*` functions — no-op (no Xbox Live)
- `xemu_snapshots_*` UI functions — no-op for now (Phase 8 adds real support)
- `xemu_settings_load/save` — no-op (we populate g_config programmatically)
- ImGui functions (`ImGui_ImplOpenGL3_*`) — no-op

### Modifications to xemu source:
- `xemu/ui/xemu.c` — Add `#ifndef OPENEMU` around `main()`, SDL window creation, event loop
- `xemu/ui/xemu-input.c` — Add `#ifdef OPENEMU` path to skip SDL gamepad enumeration
- `xemu/system/vl.c` — Ensure `qemu_init()` can be called without xemu_settings_load() having run

---

## Phase 4: Display Backend — Headless Framebuffer Capture

Redirect xemu's NV2A rendering output to a CPU-side pixel buffer for OpenEmu's 2DVideo mode.

### Approach:
The NV2A GPU renderer (either GL or Vulkan) renders the Xbox framebuffer internally. In xemu's normal mode, `nv2a_get_framebuffer_surface()` returns a GL texture ID that the SDL display reads. For OpenEmu:

1. Create a CGL offscreen OpenGL context (for the NV2A GL path) OR use MoltenVK headless Vulkan instance (for VK path)
2. After each frame, read back the NV2A framebuffer texture to a CPU buffer via `glReadPixels` (GL) or `vkMapMemory` (VK)

### New file: `xemu/OpenEmu/xemu_openemu_display.c`
- `xemu_openemu_display_init()` — Create offscreen CGL/Vulkan context, register a minimal DisplayChangeListener
- `xemu_openemu_render_frame(uint32_t *buffer, int w, int h)` — Capture NV2A framebuffer to CPU buffer
- Register as QEMU display type via `dpy_gl_scanout_texture` callback

### Modifications:
- `xemu/hw/xbox/nv2a/pgraph/pgraph.c` — Ensure context creation works without SDL window (accept externally-provided CGL/VK context)
- `xemu/ui/meson.build` — Conditionally compile `xemu-openemu-display.c` when OPENEMU=1

### Video specs:
- Resolution: 640x480 (standard), up to 720x480 (widescreen)
- Format: BGRA8 (matches `OEPixelFormat_BGRA`)
- Frame rate: 59.94 Hz (NTSC)

---

## Phase 5: Audio Backend — Custom QEMU Audio Driver

Create a QEMU audio backend that writes PCM samples to OpenEmu's ring buffer.

### New file: `xemu/OpenEmu/xemu_openemu_audio.c`
Implement `audio_driver` interface:
```c
static struct audio_driver openemu_audio_driver = {
    .name           = "openemu",
    .descr          = "OpenEmu audio output",
    .init           = oe_audio_init,
    .fini           = oe_audio_fini,
    .pcm_ops        = &oe_pcm_ops,
    ...
};
```

The `oe_write()` callback copies samples to a function pointer set by `XEMUGameCore`:
```c
void (*g_oe_audio_write)(const void *buf, size_t len);
```

### Modifications:
- `xemu/audio/meson.build` — Add openemu backend
- Audio driver registration in audio subsystem init

### Audio specs:
- Sample rate: 48000 Hz
- Channels: 2 (stereo)
- Format: 16-bit signed integer (S16LE)
- Buffer: 200ms ring buffer (same as PCSX2)

---

## Phase 6: Input Bridge — Direct ControllerState Injection

Bypass SDL gamepad input and populate `ControllerState` directly from OpenEmu button callbacks.

### Implementation in `xemu/OpenEmu/XEMUHost.c`:
- Allocate 4 `ControllerState` structs at startup
- `xemu_openemu_input_init()` — Create virtual controllers and bind to ports 1-4
- `xemu_openemu_update_buttons(int port, uint16_t buttons)` — Set digital button bitmask
- `xemu_openemu_update_axis(int port, int axis, int16_t value)` — Set analog axis

### Button mapping (OEXboxButton → xemu bitmask):
| OEXboxButton | xemu mask |
|---|---|
| OEXboxButtonA | CONTROLLER_BUTTON_A (1<<0) |
| OEXboxButtonB | CONTROLLER_BUTTON_B (1<<1) |
| OEXboxButtonX | CONTROLLER_BUTTON_X (1<<2) |
| OEXboxButtonY | CONTROLLER_BUTTON_Y (1<<3) |
| OEXboxButtonWhite | CONTROLLER_BUTTON_WHITE (1<<10) |
| OEXboxButtonBlack | CONTROLLER_BUTTON_BLACK (1<<11) |
| OEXboxButtonDpadUp | CONTROLLER_BUTTON_DPAD_UP (1<<5) |
| OEXboxButtonDpadDown | CONTROLLER_BUTTON_DPAD_DOWN (1<<7) |
| OEXboxButtonDpadLeft | CONTROLLER_BUTTON_DPAD_LEFT (1<<4) |
| OEXboxButtonDpadRight | CONTROLLER_BUTTON_DPAD_RIGHT (1<<6) |
| OEXboxButtonStart | CONTROLLER_BUTTON_START (1<<9) |
| OEXboxButtonBack | CONTROLLER_BUTTON_BACK (1<<8) |
| OEXboxButtonLeftStick | CONTROLLER_BUTTON_LSTICK (1<<12) |
| OEXboxButtonRightStick | CONTROLLER_BUTTON_RSTICK (1<<13) |

Triggers and sticks map to `ControllerState.axis[]` indices 0-5.

### Modifications:
- `xemu/ui/xemu-input.c` — Add `#ifdef OPENEMU` to skip SDL init, expose `bound_controllers[]` for external population

---

## Phase 7: Game Core Bridge — XEMUGameCore

The main plugin class tying everything together. Follows the PCSX2GameCore pattern exactly.

### New files:

**`xemu/OpenEmu/XEMUGameCore.h`**
```objc
@interface XEMUGameCore : OEGameCore <OEXboxSystemResponderClient>
@end
```

**`xemu/OpenEmu/XEMUGameCore.mm`** (~600-800 lines)

Key sections:
1. **OpenEmuXboxBridge namespace** — Shared state (atomic buttons, axis values, video buffer, audio callback, frame sync CV/mutex, shutdown flag, paths)

2. **`-loadFileAtPath:error:`** — Store ISO path

3. **`-setupEmulation`** — Populate `g_config` programmatically:
   - `g_config.sys.files.bootrom_path` = biosPath + "mcpx_1.0.bin"
   - `g_config.sys.files.flashrom_path` = biosPath + "xbox_bios.bin"
   - `g_config.sys.files.eeprom_path` = supportPath + "eeprom.bin"
   - `g_config.sys.files.hdd_path` = supportPath + "xbox_hdd.qcow2"
   - `g_config.sys.files.dvd_path` = romPath
   - Auto-create HDD QCOW2 if missing (call `qemu_img_create("qcow2", path, "8G")`)
   - Auto-generate EEPROM if missing (call `xemu_eeprom_generate()`)

4. **`-startEmulation`** — Spawn emulation thread:
   - Construct fake argc/argv matching what `vl.c` expects
   - Call `qemu_init(argc, argv)`
   - Call `qemu_main_loop()`
   - On exit: cleanup

5. **`-executeFrame`** — Wait on frame CV (50ms timeout), same pattern as PCSX2

6. **`-stopEmulation`** — Set shutdown flag, call `qemu_system_shutdown_request()`, join thread with 5s timeout

7. **Video properties:**
   - `gameCoreRendering` → `OEGameCoreRendering2DVideo`
   - `bufferSize` → 640×480
   - `aspectSize` → 4:3
   - `frameInterval` → 59.94
   - `getVideoBufferWithHint:` → return g_videoBuffer

8. **Audio properties:**
   - `audioSampleRate` → 48000
   - `channelCount` → 2

9. **Input methods:**
   - `didPushXboxButton:forPlayer:` → set bit in atomic button state, call bridge
   - `didReleaseXboxButton:forPlayer:` → clear bit
   - `didMoveXboxJoystickDirection:withValue:forPlayer:` → update axis value

**`xemu/OpenEmu/Info.plist`**
- `OEGameCoreClass`: `XEMUGameCore`
- `OESystemIdentifiers`: `openemu.system.xbox`
- `OEGameCorePlayerCount`: 4
- `OERequiredFiles`: mcpx_1.0.bin (512 bytes), xbox_bios.bin (1MB, optional variants)
- `OEGameCoreHasGlitches`: true

---

## Phase 8: BIOS & HDD Management

### BIOS files (user-provided):
- `mcpx_1.0.bin` — MCPX Boot ROM (512 bytes) — required
- `xbox_bios.bin` — Flash ROM / BIOS (256KB or 1MB) — required (multiple variants supported)

### HDD image (auto-created):
On first launch, if `xbox_hdd.qcow2` doesn't exist in the support directory:
1. Create an 8GB sparse QCOW2 image using QEMU's block layer (`bdrv_create()`)
2. The sparse file is only a few KB on disk initially
3. Grows as the Xbox writes save data

### EEPROM (auto-generated):
If `eeprom.bin` doesn't exist:
1. Call `xemu_eeprom_generate()` from `eeprom_generation.c`
2. Generates a valid EEPROM with random serial number and default settings

---

## Phase 9: Save States (Future Enhancement)

Wire OpenEmu's save state API to QEMU's VM snapshot system. QEMU snapshots are stored inside the QCOW2 HDD image, so we'll need to either:
- Use the HDD image's internal snapshot mechanism (simpler but couples save states to HDD)
- Use `qemu_savevm_state()` with a file-backed `QEMUFile` (more compatible with OpenEmu's model)

This is deferred to after the core integration is working.

---

## File Inventory Summary

### New files to create (18 files):
| File | Purpose |
|---|---|
| `OpenEmu/SystemPlugins/Xbox/OEXboxSystemResponderClient.h` | Button enum + protocol |
| `OpenEmu/SystemPlugins/Xbox/OEXboxSystemController.h` | System controller header |
| `OpenEmu/SystemPlugins/Xbox/OEXboxSystemController.m` | Disc detection + serial |
| `OpenEmu/SystemPlugins/Xbox/OEXboxSystemResponder.h` | Responder header |
| `OpenEmu/SystemPlugins/Xbox/OEXboxSystemResponder.m` | HID event routing |
| `OpenEmu/SystemPlugins/Xbox/Xbox-Info.plist` | System metadata |
| `OpenEmu/SystemPlugins/Xbox/Controller-Mappings.plist` | Controller mappings |
| `OpenEmu/SystemPlugins/Xbox/Controller-Preferences.plist` | Preferences |
| `OpenEmu/SystemPlugins/Xbox/Keyboard-Mappings.plist` | Keyboard mappings |
| `xemu/OpenEmu/XEMUGameCore.h` | Core plugin header |
| `xemu/OpenEmu/XEMUGameCore.mm` | Core plugin implementation |
| `xemu/OpenEmu/XEMUHost.c` | Input bridge + host functions |
| `xemu/OpenEmu/xemu_openemu_stubs.c` | SDL/UI/HUD stubs |
| `xemu/OpenEmu/xemu_openemu_display.c` | Headless display backend |
| `xemu/OpenEmu/xemu_openemu_audio.c` | QEMU audio backend |
| `xemu/OpenEmu/Info.plist` | Plugin bundle metadata |
| `xemu/OpenEmu/build-openemu.sh` | Build orchestration |
| `xemu/OpenEmu/CMakeLists.txt` | Plugin bundle build |

### xemu source modifications (minimal, guarded by `#ifdef OPENEMU`):
| File | Change |
|---|---|
| `xemu/ui/xemu.c` | Guard main(), SDL init, event loop |
| `xemu/ui/xemu-input.c` | Skip SDL gamepad init, expose controller state |
| `xemu/hw/xbox/nv2a/pgraph/pgraph.c` | Accept external GL/VK context |
| `xemu/audio/meson.build` | Add openemu audio backend |
| `xemu/ui/meson.build` | Conditionally compile display backend |

---

## Implementation Order (fastest path to working prototype):
1. **Phase 1** — System Plugin (Xbox button definitions)
2. **Phase 2** — Build system (get xemu compiling as library)
3. **Phase 3** — Stubs (eliminate SDL dependencies)
4. **Phase 4** — Display (headless framebuffer capture)
5. **Phase 5** — Audio (QEMU audio backend)
6. **Phase 6** — Input (controller injection)
7. **Phase 7** — Game Core bridge (ties it all together)
8. **Phase 8** — BIOS/HDD management
9. **Phase 9** — Save states (future)

Milestone: After Phases 1-4 + 7, we should see the Xbox BIOS boot screen with video output. Adding Phase 6 makes it interactive. Phase 5 adds sound.

---

## Risks:
1. **OpenGL deprecation on macOS** — CGL 4.1 works today on ARM64 but is officially deprecated. MoltenVK/Vulkan path is more future-proof but adds build complexity. Start with whichever the NV2A renderer is easier to get working headless.
2. **QEMU threading model** — Big QEMU Lock (BQL) requires careful synchronization with OpenEmu's frame timing. Follow xemu's existing `xemu_main_loop_lock/unlock()` pattern.
3. **Meson build complexity** — QEMU generates dozens of headers at configure time. We build with Meson normally and collect the artifacts rather than trying to replicate the build in CMake.
4. **NV2A renderer context creation** — The renderer assumes SDL created the GL/VK context. We need to provide our own headless context and hook it in.
