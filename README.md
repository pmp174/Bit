# Bit (An Openmenu ARM64 port for apple silicon based on work made by bazley82)

## About this Port
This version of OpenEmu has been specifically patched to run natively on Apple Silicon and includes several build fixes for modern macOS/Xcode environments.

### Key Modifications:
- **Full ARM64 Suite:** Successfully ported and verified all **25 emulation cores** (Nestopia, BSNES, Mupen64Plus, Snes9x, DeSmuME, Genesis Plus GX, etc.) for native Apple Silicon compatibility.
- **Modern Build Standards:** Updated all projects to `MACOSX_DEPLOYMENT_TARGET = 11.0` and resolved hundreds of narrowing conversion and linkage errors.
- **C64 Support:** Integrated Commodore 64 system support directly into the app bundle.
- **Permission Fixes:** Resolved the persistent "Input Monitoring" permission loop that affects many users on modern macOS versions.
- **Flattened Architecture:** Converted all submodules into regular directories to create a standalone, portable repository.
- **Custom Design:** Features a new, high-resolution "Liquid Glass" application icon, optimized for macOS Tahoe.
  
![Bit App Icon](https://github.com/pmp174/Bit/blob/f5b22ee213a71f376752432778dbdf528d74de27/Bit%20SnapShots/Bit%20App%20Icon-iOS-Default-256x256%401x.png)

- Dark & Light Modes

![Bit Screenshot](https://github.com/pmp174/Bit/blob/3039d1725e041a0ea313b1fcc4dcf9c12268099c/Bit%20SnapShots/DarkLightMode.png)


- She Comes In Colors

![Bit Colors](https://github.com/pmp174/Bit/blob/e2af42584a27c03e2ecfc6ea19b71a47c66c73bc/Bit%20SnapShots/Colors.png)

![Bit Dark](https://github.com/pmp174/Bit/blob/e2af42584a27c03e2ecfc6ea19b71a47c66c73bc/Bit%20SnapShots/ColorsDark.png)

> [!IMPORTANT]
> **Transparency Disclaimer:** This repository is an experimental port of OpenEmu, created and maintained entirely through **AI-assisted coding** (using "Vibe Coding" techniques). The project was initiated by a user with no formal coding experience to test the capabilities of advanced AI agents (specifically Antigravity & Claud) in porting complex legacy software to run natively on Apple Silicon. This is based on work made in the original openemu repository, work made by bazley82, and work made by pystIC. 

## Quick Start
You can download the pre-compiled native app from the **[Releases](https://github.com/pmp174/Bit/releases)** section.

---

Currently, OpenEmu can load the following game engines as plugins:
* Atari 2600 ([Stella](https://github.com/stella-emu/stella))
* Atari 5200 ([Atari800](https://github.com/atari800/atari800)) 
* Atari 7800 ([ProSystem](https://gitlab.com/jgemu/prosystem)) 
* Atari Lynx ([Mednafen](https://mednafen.github.io)) 
* ColecoVision ([JollyCV](https://github.com/OpenEmu/JollyCV-Core)) 
* Famicom Disk System ([Nestopia](https://gitlab.com/jgemu/nestopia)) 
* Game Boy / Game Boy Color ([Gambatte](https://gitlab.com/jgemu/gambatte)) 
* Game Boy Advance ([mGBA](https://github.com/mgba-emu/mgba)) 
* Game Gear ([Genesis Plus](https://github.com/ekeeke/Genesis-Plus-GX))
* Intellivision ([Bliss](https://github.com/jeremiah-sypult/BlissEmu)) 
* Nintendo (NES) / Famicom ([Nestopia](https://gitlab.com/jgemu/nestopia), [FCEU](https://github.com/TASEmulators/fceux)) 
* Nintendo 64 ([Mupen64Plus](https://github.com/mupen64plus)) 
* Nintendo DS ([DeSmuME](https://github.com/TASEmulators/desmume)) 
* Odyssey² / Videopac+ ([O2EM](https://sourceforge.net/projects/o2em/))
* Sega 32X ([picodrive](https://github.com/notaz/picodrive)) 
* Sega CD / Mega CD ([Genesis Plus](https://github.com/ekeeke/Genesis-Plus-GX))  
* Sega Genesis / Mega Drive ([Genesis Plus](https://github.com/ekeeke/Genesis-Plus-GX)) 
* Sega Master System ([Genesis Plus](https://github.com/ekeeke/Genesis-Plus-GX)) 
* Sega Saturn ([Mednafen](https://mednafen.github.io)) 
* Sony PlayStation ([Mednafen](https://mednafen.github.io)) 
* Super Nintendo (SNES) ([BSNES](https://github.com/bsnes-emu/bsnes), [Snes9x](https://github.com/snes9xgit/snes9x)) 
* Vectrex ([VecXGL](https://github.com/james7780/VecXGL)) 
* 3DO ([4DO](https://github.com/fourdo/fourdo)) 
* Pokémon Mini ([PokeMini](https://github.com/pokerazor/pokemini)) 
* WonderSwan ([Mednafen](https://mednafen.github.io)) 
* Commodore 64 ([VirtualC64](https://github.com/dirkwhoffmann/virtualc64))

Currently not available but in the pipeline

* PPSSP
* Gamecube

## Known Issues
Some of these cores are unavailable due to compile issues. Will be ironing that out soon. 

## Minimum Requirements
- macOS 26
- Apple Silicon

## Icon Asset Credits
Original Space Invader vector was made by
Author: Austin Andrews Creazilla
Source: github.com/Templarian/MaterialDesign
Icon set: material design pack
Licence: Apache License 2.0. Free for editorial, educational, commercial, and/or personal projects. Attribution is required in case of redistribution. More info.
