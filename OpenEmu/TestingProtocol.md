# Bit - Complete Testing Protocol

> **Version:** 1.0
> **Last Updated:** 2026-04-03
> **Purpose:** Systematic verification of all emulator cores and application features

---

## Table of Contents

1. [Test Environment Setup](#1-test-environment-setup)
2. [Core Testing Protocol](#2-core-testing-protocol)
3. [App Feature Testing Protocol](#3-app-feature-testing-protocol)
4. [Regression Checklist](#4-regression-checklist)

---

## 1. Test Environment Setup

### Prerequisites
- [ ] macOS running on Apple Silicon (ARM64)
- [ ] At least one gamepad connected (Xbox, PS4/PS5, Switch Pro, or 8BitDo)
- [ ] Keyboard available for keyboard-mapped systems
- [ ] At least 1 test ROM per system (use homebrew where possible)
- [ ] BIOS files installed for systems that require them (see Section 2)
- [ ] Internet connection available (for cloud sync, homebrew, and RetroAchievements tests)
- [ ] Test iCloud / Dropbox / Google Drive / WebDAV accounts (for cloud sync tests)

### Test ROM Library
Prepare a folder with at least one known-good ROM per supported system. Homebrew ROMs are recommended for legal compliance. Mark ROMs that are known to stress-test specific features (e.g., save states, audio, special chips).

---

## 2. Core Testing Protocol

For **every core**, run through this standard checklist. Mark each item Pass/Fail/N/A.

### Standard Core Test Checklist

| # | Test | Expected Result |
|---|------|-----------------|
| C-01 | **ROM Loading** | Game loads without crash or error dialog |
| C-02 | **Video Output** | Frame renders correctly, no black screen, no artifacts |
| C-03 | **Audio Output** | Sound plays, no crackling/popping, correct pitch |
| C-04 | **Controller Input** | All mapped buttons respond correctly |
| C-05 | **Keyboard Input** | All mapped keys respond correctly |
| C-06 | **Pause/Resume** | Emulation pauses and resumes cleanly |
| C-07 | **Save State (Create)** | Save state file created, screenshot thumbnail generated |
| C-08 | **Save State (Load)** | Game restores to exact saved point |
| C-09 | **Quick Save/Load** | Keyboard shortcut save/load works |
| C-10 | **Screenshot** | Screenshot captures current frame at native resolution |
| C-11 | **Shader Application** | At least one shader applies without visual corruption |
| C-12 | **Window Scaling** | 1x, 2x, 3x, 4x scaling works without artifacts |
| C-13 | **Fullscreen Toggle** | Enter/exit fullscreen works smoothly |
| C-14 | **Reset** | Game resets to initial state |
| C-15 | **Stop/Quit Game** | Returning to library works cleanly, no orphan processes |
| C-16 | **Performance** | Maintains target FPS (usually 60) without excessive CPU |
| C-17 | **Multiple ROMs** | Load a second ROM after quitting the first - no leftover state |

---

### 2.1 Atari Systems

#### Atari 2600 — Stella
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Test ROM suggestion: Homebrew (e.g., "Stay Frosty") | | |
| Special: Paddle controller emulation | | |
| Special: Difficulty switch toggles | | |

#### Atari 5200 — Atari800
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (5200.rom) | | |
| Test ROM suggestion: Homebrew Atari 5200 title | | |
| Special: Analog joystick emulation | | |
| Special: Keypad input | | |

#### Atari 7800 — ProSystem
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Optional** (7800 BIOS) | | |
| Test ROM suggestion: Homebrew 7800 title | | |
| Special: 2600 backward compatibility mode | | |

#### Atari 8-bit (400/800/XL/XE) — Atari800
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (atarixl.rom, atariosa.rom, atariosb.rom) | | |
| Special: Keyboard overlay input | | |

#### Atari Jaguar — VirtualJaguar
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: Complex controller (A/B/C + numpad) | | |
| Special: Known compatibility issues — note which ROMs fail | | |

#### Atari Lynx — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (lynxboot.img) | | |
| Special: Screen rotation (horizontal/vertical) | | |

---

### 2.2 Nintendo Systems

#### NES — Nestopia / FCEU
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Test ROM suggestion: Homebrew NES title | | |
| Special: Mapper support (test multiple mappers) | | |
| Special: Zapper emulation (if supported) | | |
| Special: FDS disk-swap (if FDS ROM used) | | |
| Core switch: Test both Nestopia and FCEU | | |

#### Famicom Disk System (FDS) — Nestopia
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (disksys.rom) | | |
| Special: Disk side-swap | | |

#### Super Nintendo (SNES) — SNES9x / BSNES
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** (some special chips may need files) | | |
| Test ROM suggestion: Homebrew SNES title | | |
| Special: SuperFX games (e.g., Star Fox) | | |
| Special: SA-1 games | | |
| Special: DSP games | | |
| Special: Mouse/Super Scope emulation | | |
| Core switch: Test both SNES9x and BSNES | | |

#### Nintendo 64 — Mupen64Plus
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Test ROM suggestion: Homebrew N64 title | | |
| Special: Analog stick sensitivity | | |
| Special: Rumble Pak emulation | | |
| Special: Controller Pak (memory card) saves | | |
| Special: Expansion Pak games | | |
| Special: 3D rendering accuracy | | |

#### Game Boy / Game Boy Color — Gambatte
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Optional** (dmg_boot.bin, cgb_boot.bin) | | |
| Test ROM suggestion: Homebrew GB/GBC title | | |
| Special: GB palette selection | | |
| Special: GBC color rendering | | |
| Special: Link cable emulation (if supported) | | |

#### Game Boy Advance — mGBA
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Optional** (gba_bios.bin) | | |
| Test ROM suggestion: Homebrew GBA title | | |
| Special: RTC games | | |
| Special: Solar sensor games | | |
| Special: Gyroscope games | | |

#### Nintendo DS — DeSmuME
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (bios7.bin, bios9.bin, firmware.bin) | | |
| Special: Dual screen layout | | |
| Special: Touch screen input (mouse emulation) | | |
| Special: Microphone emulation | | |
| Special: Screen swap | | |

#### GameCube — Dolphin
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Optional** (IPL.bin) | | |
| Special: Analog triggers (L/R pressure sensitivity) | | |
| Special: C-stick input | | |
| Special: Memory card management | | |
| Special: Widescreen rendering | | |
| Special: Performance on ARM64 (high-demand core) | | |

#### Wii — Dolphin
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: Wiimote emulation (pointer, motion) | | |
| Special: Nunchuk input | | |
| Special: Classic Controller input | | |
| Special: Wii NAND management | | |
| Special: Performance on ARM64 | | |

#### Virtual Boy — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: Red/black stereoscopic rendering | | |
| Special: Color palette options | | |

#### Pokemon mini — PokeMini
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Optional** (min_bios.min) | | |
| Special: Rumble emulation | | |
| Special: IR emulation | | |

---

### 2.3 Sega Systems

#### Sega Master System — Genesis Plus / CrabEmu
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Optional** (bios_E.sms, bios_U.sms, bios_J.sms) | | |
| Special: FM sound unit | | |
| Special: Pause button mapping | | |

#### Game Gear — Genesis Plus / CrabEmu
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: Small native resolution scaling | | |
| Special: Start button (on-screen or mapped) | | |

#### Genesis / Mega Drive — Genesis Plus / picodrive
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Test ROM suggestion: Homebrew Genesis title | | |
| Special: 6-button controller mode | | |
| Special: SVP chip games (Virtua Racing) | | |
| Special: Region switching (US/EU/JP) | | |
| Core switch: Test both Genesis Plus and picodrive | | |

#### Sega CD — Genesis Plus
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (bios_CD_E.bin, bios_CD_U.bin, bios_CD_J.bin) | | |
| Special: CD audio playback | | |
| Special: CUE/BIN loading | | |
| Special: ISO+MP3/OGG loading | | |
| Special: Internal backup RAM | | |

#### Sega 32X — Genesis Plus / picodrive
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (32X_G_BIOS.bin, 32X_M_BIOS.bin, 32X_S_BIOS.bin) | | |
| Special: SH2 processor emulation accuracy | | |

#### Sega Saturn — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (sega_101.bin or mpr-17933.bin) | | |
| Special: CD image support (CUE/BIN, CCD, MDS) | | |
| Special: Analog controller mode | | |
| Special: Performance on ARM64 (high-demand core) | | |
| Special: Internal backup memory | | |

#### Dreamcast — Flycast
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (dc_boot.bin, dc_flash.bin) | | |
| Special: VMU emulation | | |
| Special: GDI image loading | | |
| Special: CDI image loading | | |
| Special: Analog triggers | | |
| Special: VGA mode / widescreen | | |
| Special: Performance on ARM64 | | |

#### SG-1000 — Genesis Plus / CrabEmu
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |

---

### 2.4 Sony Systems

#### PlayStation — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (scph5500.bin, scph5501.bin, scph5502.bin) | | |
| Special: Analog controller (DualShock) mode | | |
| Special: Multi-disc games (disc swap) | | |
| Special: CUE/BIN loading | | |
| Special: Memory card management | | |
| Special: Vibration/rumble | | |

#### PlayStation 2
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** | | |
| Special: DVD image loading | | |
| Special: Widescreen rendering | | |
| Special: Performance on ARM64 (very high-demand) | | |
| Special: Pressure-sensitive buttons | | |

#### PSP — PPSSPP
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: Analog nub input | | |
| Special: ISO/CSO loading | | |
| Special: Widescreen rendering | | |
| Special: Texture scaling | | |
| Special: Frameskip settings | | |
| Special: Performance on ARM64 | | |

---

### 2.5 NEC Systems

#### PC Engine / TurboGrafx-16 — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: 6-button controller support | | |
| Special: SuperGrafx games (if supported) | | |

#### PC Engine CD — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (syscard3.pce) | | |
| Special: CD audio playback | | |
| Special: CUE/BIN loading | | |
| Special: Super System Card games | | |

#### PC-FX — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (pcfx.rom) | | |
| Special: FMV playback | | |

---

### 2.6 SNK Systems

#### Neo Geo Pocket / Color — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: Clicky joystick emulation | | |

---

### 2.7 Arcade Systems

#### Arcade (MAME) — MAME
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Varies by game** (neogeo.zip, etc.) | | |
| Special: ROM set version compatibility | | |
| Special: Coin insert / service buttons | | |
| Special: DIP switch configuration | | |
| Special: Multiple player inputs | | |

#### Naomi — Flycast
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (naomi.zip) | | |
| Special: Arcade-specific inputs | | |

#### Naomi 2 — Flycast
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** | | |
| Special: 3D rendering accuracy | | |

#### Atomiswave — Flycast
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (awbios.zip) | | |

---

### 2.8 Other Systems

#### 3DO — 4DO
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (panafz10.bin) | | |
| Special: CD image loading | | |

#### ColecoVision — JollyCV
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (colecovision.rom) | | |
| Special: Keypad input mapping | | |

#### Commodore 64 — Frodo / VirtualC64
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (kernal, basic, chargen) | | |
| Special: Keyboard input | | |
| Special: Joystick port selection | | |
| Special: Disk/tape loading | | |
| Core switch: Test both Frodo and VirtualC64 | | |

#### Intellivision — Bliss
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (exec.bin, grom.bin) | | |
| Special: Keypad overlay | | |
| Special: Disc controller emulation | | |

#### MSX — blueMSX
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (MSX system ROMs) | | |
| Special: Keyboard input | | |
| Special: Cartridge/disk switching | | |

#### Odyssey 2 — O2EM
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **Yes** (o2rom.bin) | | |
| Special: Keyboard overlay | | |

#### Supervision — Potator
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |

#### Vectrex — VecXGL
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** (built-in) | | |
| Special: Vector line rendering | | |
| Special: Overlay emulation | | |

#### VMU (Visual Memory Unit) — (built-in)
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: Tiny screen rendering | | |

#### WonderSwan / Color — Mednafen
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: Screen rotation (horizontal/vertical) | | |
| Special: WonderSwan Color mode | | |

#### Flash — Ruffle
| Test | Status | Notes |
|------|--------|-------|
| C-01 through C-17 | | |
| BIOS Required: **No** | | |
| Special: SWF file loading | | |
| Special: ActionScript compatibility | | |
| Special: Mouse input | | |
| Special: Keyboard input | | |

---

## 3. App Feature Testing Protocol

### 3.1 First Launch & Setup

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-001 | Fresh launch | Delete app preferences, launch app | Setup assistant appears | | |
| F-002 | Setup assistant flow | Complete setup wizard | Library window appears after completion | | |
| F-003 | Default core installation | Check Preferences > Cores | Default cores downloaded and available | | |
| F-004 | BIOS file check | Preferences > Cores & System Files | Missing BIOS files flagged clearly | | |

---

### 3.2 ROM Importing

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-010 | Drag-and-drop single ROM | Drag a ROM onto the library window | ROM imports, game appears in library | | |
| F-011 | Drag-and-drop multiple ROMs | Drag a folder of ROMs | All valid ROMs import with progress bar | | |
| F-012 | File > Import menu | Use File > Import Game... | File picker opens, selected ROM imports | | |
| F-013 | ZIP archive import | Import a .zip containing a ROM | Archive extracted, ROM imported | | |
| F-014 | RAR archive import | Import a .rar containing a ROM | Archive extracted, ROM imported | | |
| F-015 | 7z archive import | Import a .7z containing a ROM | Archive extracted, ROM imported | | |
| F-016 | Duplicate detection | Import the same ROM twice | Second import detected as duplicate, no duplication | | |
| F-017 | Invalid file handling | Import a non-ROM file (e.g., .txt) | File rejected gracefully with appropriate message | | |
| F-018 | CUE/BIN import | Import a disc-based game (CUE+BIN) | Both files handled, game appears correctly | | |
| F-019 | Multi-disc import | Import a multi-disc game | All discs associated with same game entry | | |
| F-020 | Scanner progress | Import many ROMs at once | Scanner bar shows progress and count | | |
| F-021 | Cancel import | Start large import, then cancel | Import stops cleanly, partial imports handled | | |
| F-022 | Metadata fetch | Import a well-known ROM | Game metadata (title, artwork, year) fetched from OpenVGDB | | |
| F-023 | ISO/CSO import (PSP) | Import a PSP ISO or CSO file | File imports and associates with PSP system | | |
| F-024 | GDI import (Dreamcast) | Import a Dreamcast GDI file | File imports correctly with all tracks | | |

---

### 3.3 Library — Grid View

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-030 | Grid display | Navigate to a system with games | Games shown as cover art grid | | |
| F-031 | Grid zoom slider | Adjust the grid size slider in toolbar | Grid items resize smoothly | | |
| F-032 | Cover art display | View game with known artwork | Cover art renders correctly | | |
| F-033 | Missing cover art | View game without artwork | Placeholder image shown | | |
| F-034 | Game title display | View game in grid | Title shown below cover art | | |
| F-035 | Double-click to launch | Double-click a game in grid | Game launches in emulation window | | |
| F-036 | Right-click context menu | Right-click a game in grid | Context menu with options (Play, Info, Delete, etc.) | | |
| F-037 | Inline rename | Slow-double-click game title | Title becomes editable | | |
| F-038 | Rating display | Rate a game, check grid | Star rating shown on game cell | | |
| F-039 | Selection indication | Click a game | Visual selection indicator shown | | |
| F-040 | Multi-select | Cmd+Click or Shift+Click games | Multiple games selected | | |
| F-041 | Drag to collection | Drag game from grid to sidebar collection | Game added to collection | | |

---

### 3.4 Library — List View

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|--------|-----------------|--------|-------|
| F-050 | List display | Switch to list view | Games shown in table with columns | | |
| F-051 | Column headers | Check table columns | Title, System, Rating, Last Played, etc. visible | | |
| F-052 | Column sorting | Click column header | List sorts by that column (toggle asc/desc) | | |
| F-053 | Column resizing | Drag column border | Column width changes | | |
| F-054 | Double-click to launch | Double-click a row | Game launches | | |
| F-055 | Right-click context menu | Right-click a row | Context menu appears | | |
| F-056 | Rating editing | Click rating stars in list | Rating updates inline | | |
| F-057 | Multi-select in list | Cmd/Shift+Click rows | Multiple rows selected | | |

---

### 3.5 Sidebar Navigation

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-060 | System categories | Check sidebar | Each installed system listed under "Consoles" | | |
| F-061 | Media section | Check sidebar | "Save States" and "Screenshots" listed under Media | | |
| F-062 | Collections section | Check sidebar | Default and custom collections shown | | |
| F-063 | All Games | Click "All Games" | All games across systems shown | | |
| F-064 | System filter | Click a specific system | Only games for that system shown | | |
| F-065 | Create collection | Right-click > New Collection | New collection created, rename enabled | | |
| F-066 | Create smart collection | Right-click > New Smart Collection | Smart collection with criteria editor | | |
| F-067 | Delete collection | Right-click collection > Delete | Collection removed (games preserved) | | |
| F-068 | Rename collection | Double-click collection name | Name becomes editable | | |
| F-069 | Empty system hidden | Check sidebar with no ROMs for a system | System not shown (or shown grayed) | | |

---

### 3.6 Search

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-070 | Search field | Click search field or Cmd+F | Search field activates | | |
| F-071 | Search by title | Type game name | Results filter in real time | | |
| F-072 | Clear search | Click X or press Escape | Full list restored | | |
| F-073 | Search across systems | Search while in "All Games" | Results from all systems shown | | |
| F-074 | Search within system | Search while in a specific system | Results limited to that system | | |

---

### 3.7 Game Launching & Emulation

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-080 | Game launch | Double-click a game | Game starts, video and audio output begin | | |
| F-081 | Controls bar | Move mouse during gameplay | Controls bar (HUD) appears | | |
| F-082 | Controls bar auto-hide | Stop moving mouse | Controls bar fades out | | |
| F-083 | Pause via HUD | Click pause in controls bar | Emulation pauses | | |
| F-084 | Resume via HUD | Click play in controls bar | Emulation resumes | | |
| F-085 | Volume control | Adjust volume in controls bar | Audio volume changes | | |
| F-086 | Save state via HUD | Click save in controls bar | Save state created | | |
| F-087 | Load state via HUD | Click load in controls bar | Previous save state loaded | | |
| F-088 | Screenshot via HUD | Click screenshot in controls bar | Screenshot captured and saved | | |
| F-089 | Fullscreen toggle | Press Cmd+F or click fullscreen | Window enters fullscreen | | |
| F-090 | Exit fullscreen | Press Cmd+F or Escape | Window returns to windowed mode | | |
| F-091 | Reset game | Use menu or HUD to reset | Game restarts from beginning | | |
| F-092 | Stop game | Use menu or HUD to stop | Returns to library view | | |
| F-093 | Background pause | Switch to another app (with preference on) | Emulation pauses automatically | | |
| F-094 | Background resume | Switch back to game window | Emulation resumes | | |
| F-095 | Core selection | Right-click game > Select core | Can choose between available cores | | |
| F-096 | Display modes | Check display mode menu | Available display modes listed for current core | | |
| F-097 | Integral scaling | Resize game window | Window snaps to integer multiples | | |

---

### 3.8 Save States

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-100 | Create save state | During gameplay, create save state | State saved with timestamp and screenshot | | |
| F-101 | Load save state | Load a previously created state | Game restores to exact point | | |
| F-102 | Quick save | Press quick save shortcut | State saved without dialog | | |
| F-103 | Quick load | Press quick load shortcut | Most recent quick save loaded | | |
| F-104 | Auto save on quit | Quit a game | Auto-save state created | | |
| F-105 | Resume from auto-save | Relaunch same game | Option to resume from auto-save | | |
| F-106 | Delete save state | In Media > Save States, delete a state | State removed from library and disk | | |
| F-107 | Save state thumbnail | View save state in Media section | Screenshot thumbnail displayed | | |
| F-108 | Save state metadata | View save state details | Timestamp, game name, core version shown | | |
| F-109 | Save state across sessions | Create state, quit app, relaunch, load state | State loads correctly | | |

---

### 3.9 Screenshots

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-110 | Capture screenshot | During gameplay, take screenshot | Screenshot saved to library | | |
| F-111 | Screenshot gallery | Navigate to Media > Screenshots | All screenshots displayed in grid | | |
| F-112 | Screenshot metadata | View screenshot details | Game name, timestamp, resolution shown | | |
| F-113 | Delete screenshot | Select and delete a screenshot | Removed from library and disk | | |
| F-114 | Open in Finder | Right-click screenshot > Show in Finder | Finder opens to file location | | |
| F-115 | Screenshot format | Check saved file | Correct format per preferences (PNG/TIFF) | | |

---

### 3.10 Shader System

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-120 | Shader menu access | During gameplay, access shader menu | List of available shaders shown | | |
| F-121 | Apply CRT shader | Select a CRT shader | Scanline/CRT effect renders correctly | | |
| F-122 | Apply LCD shader | Select an LCD shader | LCD grid effect renders | | |
| F-123 | Apply smooth shader | Select a smooth/xBR shader | Image smoothing applied | | |
| F-124 | Remove shader | Select "None" or default | Shader effect removed, raw output shown | | |
| F-125 | Shader parameters | Open shader parameter window | Adjustable parameters displayed | | |
| F-126 | Adjust parameter | Move a shader parameter slider | Visual effect updates in real time | | |
| F-127 | Save shader preset | Save current parameters as preset | Preset saved and appears in list | | |
| F-128 | Load shader preset | Select a saved preset | Parameters restored from preset | | |
| F-129 | Delete shader preset | Delete a custom preset | Preset removed from list | | |
| F-130 | Per-system shader | Set different shaders for different systems | Each system uses its own shader | | |
| F-131 | Shader performance | Apply complex shader | No significant FPS drop, renders smoothly | | |

---

### 3.11 Cheats

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-140 | Cheat menu access | During gameplay, open cheat menu | Cheat list/editor appears | | |
| F-141 | Add cheat code | Enter a known cheat code | Cheat added to list | | |
| F-142 | Enable cheat | Toggle cheat on | Cheat effect applies in game | | |
| F-143 | Disable cheat | Toggle cheat off | Cheat effect removed | | |
| F-144 | Cheat database | Check for built-in cheats for a known game | Pre-populated cheats available | | |
| F-145 | Multiple cheats | Enable multiple cheats simultaneously | All cheats active without conflict | | |

---

### 3.12 Preferences — General

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-150 | Open preferences | Cmd+, or menu | Preferences window opens | | |
| F-151 | General tab | Click General | General settings displayed | | |
| F-152 | Appearance setting | Toggle appearance options | App theme changes accordingly | | |
| F-153 | Check for updates | Click update check (if available) | Update check runs | | |

---

### 3.13 Preferences — Library

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-160 | Library tab | Click Library in preferences | Library settings shown | | |
| F-161 | Change library location | Change game library folder path | Library moves to new location | | |
| F-162 | Reset library | Use reset/rebuild option | Library database rebuilt | | |
| F-163 | Library organization | Check "Organize library" option | ROMs organized into system folders | | |

---

### 3.14 Preferences — Gameplay

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-170 | Gameplay tab | Click Gameplay in preferences | Gameplay settings shown | | |
| F-171 | Background pause toggle | Toggle background pause setting | Behavior matches during gameplay | | |
| F-172 | Screenshot format | Change screenshot format (PNG/TIFF) | New screenshots use selected format | | |
| F-173 | Volume setting | Adjust default volume | New games launch at set volume | | |

---

### 3.15 Preferences — Controls

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-180 | Controls tab | Click Controls in preferences | Controller setup shown | | |
| F-181 | System selection | Select a system from dropdown | Controller layout for that system displayed | | |
| F-182 | Keyboard mapping | Click a button, press a key | Key mapped to that button | | |
| F-183 | Gamepad mapping | Click a button, press gamepad button | Gamepad button mapped | | |
| F-184 | Analog stick mapping | Map analog stick axes | Stick responds correctly in game | | |
| F-185 | Reset to defaults | Click reset/default button | Mappings restored to defaults | | |
| F-186 | Multiple players | Switch to Player 2/3/4 tab | Separate mappings per player | | |
| F-187 | Controller auto-detect | Connect a new controller | Controller recognized and named | | |
| F-188 | Multiple controllers | Connect 2+ controllers | Each assignable to different players | | |
| F-189 | Controller disconnect | Disconnect controller during play | Graceful fallback, no crash | | |

---

### 3.16 Preferences — Cores & System Files

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-190 | Cores tab | Click Cores in preferences | Core list displayed | | |
| F-191 | Core version display | Check core entries | Version numbers shown | | |
| F-192 | BIOS file status | Check BIOS section | Missing files flagged, found files marked green | | |
| F-193 | BIOS file import | Drag BIOS file onto window | BIOS detected and placed correctly | | |
| F-194 | Core download | Download a missing core | Core downloads and installs | | |
| F-195 | Core update | Check for core updates | Updates available flagged | | |

---

### 3.17 Preferences — Accounts

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-200 | Accounts tab | Click Accounts in preferences | Account management shown | | |
| F-201 | ScreenScraper login | Enter ScreenScraper credentials | Login succeeds, metadata scraping enabled | | |
| F-202 | RetroAchievements login | Enter RA credentials (if supported) | Login succeeds | | |

---

### 3.18 Cloud Sync

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-210 | Cloud sync tab | Open cloud sync preferences | Provider selection shown | | |
| F-211 | iCloud enable | Enable iCloud sync | Save states begin syncing to iCloud | | |
| F-212 | Dropbox connect | Connect Dropbox account | OAuth flow completes, sync begins | | |
| F-213 | Google Drive connect | Connect Google Drive account | OAuth flow completes, sync begins | | |
| F-214 | WebDAV connect | Enter WebDAV server details | Connection established, sync begins | | |
| F-215 | Sync save states | Create save state, check cloud | Save state appears in cloud storage | | |
| F-216 | Sync from cloud | Delete local save, trigger sync | Save state restored from cloud | | |
| F-217 | Sync conflict | Modify state on two devices | Conflict resolved (newest wins or prompt) | | |
| F-218 | Sync status bar | Check library toolbar | Sync status indicator shows progress/completion | | |
| F-219 | Disconnect provider | Disconnect cloud provider | Sync stops, local files preserved | | |
| F-220 | Eviction settings | Set eviction days | Old cloud files evicted per policy | | |

---

### 3.19 Homebrew Browser

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-230 | Open homebrew | Click Homebrew in sidebar | Homebrew browser loads | | |
| F-231 | Game list loads | Wait for homebrew list | Games listed with descriptions | | |
| F-232 | Download homebrew | Click download on a game | Game downloads and imports to library | | |
| F-233 | Play homebrew | Launch downloaded homebrew game | Game runs in appropriate core | | |
| F-234 | Featured games | Check featured section | Featured/highlighted games displayed | | |

---

### 3.20 Flashpoint (Flash Games)

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-240 | Flashpoint browser | Access Flashpoint section | Flash game browser loads | | |
| F-241 | Search Flash game | Search for a known Flash game | Results appear | | |
| F-242 | Launch Flash game | Select and launch a Flash game | Game runs via Ruffle core | | |
| F-243 | Mouse input | Use mouse in Flash game | Cursor tracked and clicks registered | | |

---

### 3.21 Window Management

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-250 | Main window resize | Resize library window | Content reflows, no visual glitches | | |
| F-251 | Window state restore | Close and reopen app | Window position and size restored | | |
| F-252 | Multiple monitors | Move window between displays | Renders correctly on all displays | | |
| F-253 | Game window resize | Resize during gameplay | Game scales with integer multiples | | |
| F-254 | Split view | Enter macOS split view | App functions in split view | | |

---

### 3.22 Toolbar

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-260 | Grid/List toggle | Click view mode buttons | View switches between grid and list | | |
| F-261 | Grid slider | Adjust grid size slider | Grid items resize | | |
| F-262 | Search field | Click search or Cmd+F | Search field activates | | |
| F-263 | Add button | Click add/import button | Import dialog or dropdown appears | | |

---

### 3.23 Blank Slate Views

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-270 | Empty system | Click a system with no games | Blank slate with instructions shown | | |
| F-271 | Drag hint | Check blank slate message | "Drag and drop" instructions visible | | |
| F-272 | Homebrew link | Click homebrew link in blank slate | Opens homebrew section or downloads | | |

---

### 3.24 Touch Bar (MacBook Pro)

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-280 | Library Touch Bar | View library with Touch Bar MacBook | Relevant controls shown | | |
| F-281 | Gameplay Touch Bar | Launch game with Touch Bar MacBook | Game-specific controls shown | | |
| F-282 | Touch Bar responsiveness | Tap Touch Bar controls | Actions trigger correctly | | |

---

### 3.25 Keyboard Shortcuts

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-290 | Cmd+O | Press Cmd+O | Open/import ROM dialog | | |
| F-291 | Cmd+, | Press Cmd+, | Preferences window opens | | |
| F-292 | Cmd+F | Press Cmd+F | Search field activates | | |
| F-293 | Cmd+Q | Press Cmd+Q during gameplay | Game stops, app quits cleanly | | |
| F-294 | Escape | Press Escape during gameplay | Exits fullscreen or stops game | | |
| F-295 | Space | Press Space during gameplay | Toggles pause (if configured) | | |

---

### 3.26 Error Handling & Edge Cases

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-300 | Missing ROM file | Move ROM file, try to launch | Clear error message, no crash | | |
| F-301 | Corrupt ROM | Import a corrupted file | Handled gracefully with error message | | |
| F-302 | Missing BIOS | Launch game needing BIOS without it | Error message listing needed BIOS file | | |
| F-303 | Core crash recovery | If core crashes mid-game | Error dialog, return to library, no app crash | | |
| F-304 | Disk full | Fill disk, try save state | Error message, no data corruption | | |
| F-305 | Database corruption | Corrupt Core Data store | Recovery or rebuild option presented | | |
| F-306 | Concurrent launches | Try launching two games at once | Second launch queued or rejected gracefully | | |
| F-307 | Rapid game switching | Launch/stop games rapidly | No orphan processes, no memory leaks | | |

---

### 3.27 Performance & Stability

| # | Test | Steps | Expected Result | Status | Notes |
|---|------|-------|-----------------|--------|-------|
| F-310 | Memory usage (library) | Monitor Activity Monitor while browsing | Memory stays reasonable (<500MB idle) | | |
| F-311 | Memory usage (gameplay) | Monitor during extended gameplay | No memory leaks over time | | |
| F-312 | CPU usage (idle) | Monitor CPU with app open, no game | Minimal CPU usage | | |
| F-313 | CPU usage (gameplay) | Monitor CPU during gameplay | Appropriate for the core being run | | |
| F-314 | Large library | Import 500+ games | Library remains responsive | | |
| F-315 | Long gameplay session | Play for 30+ minutes | No degradation, stable FPS | | |
| F-316 | XPC stability | Monitor helper process during play | XPC process stays alive, no disconnects | | |

---

## 4. Regression Checklist

Run this quick checklist before each release to catch common regressions.

| # | Quick Check | Status |
|---|-------------|--------|
| R-01 | App launches without crash | |
| R-02 | Library loads and displays games | |
| R-03 | At least one game per major system family launches (NES, SNES, Genesis, GB, PSX) | |
| R-04 | Save state create/load works | |
| R-05 | Screenshot capture works | |
| R-06 | Shader application works | |
| R-07 | Controller input works (keyboard + gamepad) | |
| R-08 | Preferences open and display correctly | |
| R-09 | ROM import works (single file, archive) | |
| R-10 | Grid and list views both display correctly | |
| R-11 | Search filters games correctly | |
| R-12 | Fullscreen enter/exit works | |
| R-13 | Game quit returns to library cleanly | |
| R-14 | Cloud sync connects (if configured) | |
| R-15 | No orphan helper processes after quitting games | |

---

## Test Result Summary Template

| Category | Total Tests | Passed | Failed | N/A | Notes |
|----------|------------|--------|--------|-----|-------|
| Atari Cores | | | | | |
| Nintendo Cores | | | | | |
| Sega Cores | | | | | |
| Sony Cores | | | | | |
| NEC Cores | | | | | |
| SNK Cores | | | | | |
| Arcade Cores | | | | | |
| Other Cores | | | | | |
| ROM Importing | | | | | |
| Library Views | | | | | |
| Sidebar/Nav | | | | | |
| Game Emulation | | | | | |
| Save States | | | | | |
| Screenshots | | | | | |
| Shaders | | | | | |
| Cheats | | | | | |
| Preferences | | | | | |
| Cloud Sync | | | | | |
| Homebrew/Flash | | | | | |
| Window/UI | | | | | |
| Error Handling | | | | | |
| Performance | | | | | |
| **TOTAL** | | | | | |

---

*Generated for Bit (OpenEmu ARM64 Metal4 fork) — April 2026*
