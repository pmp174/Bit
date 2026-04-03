// Copyright (c) 2025, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import <Cocoa/Cocoa.h>
#import "DolphinGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEGameCore.h>
#import <OpenEmuBase/OEGameCoreDisplayModes.h>

// Peripheral device dictionary keys (matching OEGameCorePeripheralDevices.h)
#define OEPeripheralPortNameKey @"OEPeripheralPortNameKey"
#define OEPeripheralPortIdentifierKey @"OEPeripheralPortIdentifierKey"
#define OEPeripheralPortDevicesKey @"OEPeripheralPortDevicesKey"
#define OEPeripheralPortExpansionsKey @"OEPeripheralPortExpansionsKey"
#define OEPeripheralDeviceNameKey @"OEPeripheralDeviceNameKey"
#define OEPeripheralDeviceIdentifierKey @"OEPeripheralDeviceIdentifierKey"
#define OEPeripheralDeviceSelectedKey @"OEPeripheralDeviceSelectedKey"

#include <string>
#include <memory>
#include <thread>
#include <atomic>
#include <mutex>
#include <vector>

#include <OpenGL/gl3.h>

#include "Common/WindowSystemInfo.h"
#include "Core/Core.h"
#include "Core/BootManager.h"
#include "Core/System.h"
#include "Core/State.h"
#include "Core/Boot/Boot.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/SYSCONFSettings.h"
#include "Core/ConfigManager.h"
#include "Core/HW/SI/SI_Device.h"
#include "Core/HW/EXI/EXI.h"
#include "Core/HW/EXI/EXI_Device.h"
#include "Core/HW/GCPad.h"
#include "Core/HW/GCPadEmu.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "Core/HW/ProcessorInterface.h"
#include "InputCommon/GCPadStatus.h"
#include "InputCommon/InputConfig.h"
#include "AudioCommon/AudioCommon.h"
#include "AudioCommon/OpenEmuStream.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoConfig.h"
#include "UICommon/UICommon.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerEmu/ControlGroup/ControlGroup.h"
#include "InputCommon/ControllerEmu/ControlGroup/Attachments.h"
#include "InputCommon/ControllerEmu/StickGate.h"
#include "Core/HW/WiimoteEmu/Extension/Nunchuk.h"
#include "Core/Config/WiimoteSettings.h"

#define SAMPLERATE 48000

#pragma mark -

// Double-buffered frame data: Dolphin's GPU thread writes into the "back" buffer,
// then atomically swaps it with the "front" buffer. OpenEmu's render thread reads
// from the front buffer without blocking the GPU thread.
struct FrameBuffer {
    std::vector<u8> data;
    u32 width = 0;
    u32 height = 0;
};
static std::mutex s_framebuf_mutex;
static FrameBuffer s_framebuf_back;     // Written by Dolphin's GPU thread
static FrameBuffer s_framebuf_front;    // Read by OpenEmu's render thread
static std::atomic<bool> s_framebuf_new{false}; // Signal that a new frame is available

// GC pad state. Written by OpenEmu's input callbacks (didPushGCButton, etc.),
// read by the InputOverrideFunction lambda we install on each GCPad.
static GCPadStatus s_pad_status[4];
static std::mutex s_pad_mutex;

// Wii Remote + Nunchuk state for input override
struct WiiState {
    u16 buttons = 0;       // Wiimote button bitmask
    u8 nunchukButtons = 0; // Nunchuk button bitmask
    double nunchukX = 0.0; // Nunchuk stick X (-1..1)
    double nunchukY = 0.0; // Nunchuk stick Y (-1..1)
    double irX = 0.0;      // IR pointer X (-1..1)
    double irY = 0.0;      // IR pointer Y (-1..1)
};
static WiiState s_wii_status[4];
static std::mutex s_wii_mutex;

// Creates an InputOverrideFunction that reads from s_pad_status[playerIndex]
// and maps it to the control names used by Dolphin's GCPad emulation.
// This intercepts GetInput() at the ControlGroup level and feeds our values
// for every control — buttons, sticks, triggers, and d-pad.
static std::atomic<bool> s_gc_override_logged{false};

static ControllerEmu::InputOverrideFunction MakeGCPadOverride(int playerIndex)
{
    return [playerIndex](const std::string_view group_name,
                         const std::string_view control_name,
                         ControlState /*orig_state*/) -> std::optional<ControlState> {
        if (!s_gc_override_logged.exchange(true)) {
            NSLog(@"[Dolphin] GCPad override called for player %d, group=%s, control=%s",
                  playerIndex,
                  std::string(group_name).c_str(),
                  std::string(control_name).c_str());
        }
        std::lock_guard<std::mutex> lock(s_pad_mutex);
        const GCPadStatus& pad = s_pad_status[playerIndex];

        if (group_name == GCPad::BUTTONS_GROUP) {
            if (control_name == GCPad::A_BUTTON)      return (pad.button & PAD_BUTTON_A) ? 1.0 : 0.0;
            if (control_name == GCPad::B_BUTTON)      return (pad.button & PAD_BUTTON_B) ? 1.0 : 0.0;
            if (control_name == GCPad::X_BUTTON)      return (pad.button & PAD_BUTTON_X) ? 1.0 : 0.0;
            if (control_name == GCPad::Y_BUTTON)      return (pad.button & PAD_BUTTON_Y) ? 1.0 : 0.0;
            if (control_name == GCPad::Z_BUTTON)      return (pad.button & PAD_TRIGGER_Z) ? 1.0 : 0.0;
            if (control_name == GCPad::START_BUTTON)   return (pad.button & PAD_BUTTON_START) ? 1.0 : 0.0;
        }

        if (group_name == GCPad::DPAD_GROUP) {
            if (control_name == "Up")    return (pad.button & PAD_BUTTON_UP) ? 1.0 : 0.0;
            if (control_name == "Down")  return (pad.button & PAD_BUTTON_DOWN) ? 1.0 : 0.0;
            if (control_name == "Left")  return (pad.button & PAD_BUTTON_LEFT) ? 1.0 : 0.0;
            if (control_name == "Right") return (pad.button & PAD_BUTTON_RIGHT) ? 1.0 : 0.0;
        }

        if (group_name == GCPad::MAIN_STICK_GROUP) {
            if (control_name == ControllerEmu::ReshapableInput::X_INPUT_OVERRIDE)
                return (static_cast<double>(pad.stickX) - 128.0) / 128.0;
            if (control_name == ControllerEmu::ReshapableInput::Y_INPUT_OVERRIDE)
                return (static_cast<double>(pad.stickY) - 128.0) / 128.0;
        }

        if (group_name == GCPad::C_STICK_GROUP) {
            if (control_name == ControllerEmu::ReshapableInput::X_INPUT_OVERRIDE)
                return (static_cast<double>(pad.substickX) - 128.0) / 128.0;
            if (control_name == ControllerEmu::ReshapableInput::Y_INPUT_OVERRIDE)
                return (static_cast<double>(pad.substickY) - 128.0) / 128.0;
        }

        if (group_name == GCPad::TRIGGERS_GROUP) {
            if (control_name == GCPad::L_DIGITAL)  return (pad.button & PAD_TRIGGER_L) ? 1.0 : 0.0;
            if (control_name == GCPad::R_DIGITAL)  return (pad.button & PAD_TRIGGER_R) ? 1.0 : 0.0;
            if (control_name == GCPad::L_ANALOG)   return static_cast<double>(pad.triggerLeft) / 255.0;
            if (control_name == GCPad::R_ANALOG)   return static_cast<double>(pad.triggerRight) / 255.0;
        }

        return std::nullopt;
    };
}

// Creates an InputOverrideFunction for Wiimote buttons, D-Pad, and IR.
// Wii input still uses the override system because there is no equivalent
// "external status" hook for the Wiimote HLE layer.
static ControllerEmu::InputOverrideFunction MakeWiimoteOverride(int playerIndex)
{
    return [playerIndex](const std::string_view group_name,
                         const std::string_view control_name,
                         ControlState /*orig_state*/) -> std::optional<ControlState> {
        std::lock_guard<std::mutex> lock(s_wii_mutex);
        const WiiState& wii = s_wii_status[playerIndex];

        if (group_name == WiimoteEmu::Wiimote::BUTTONS_GROUP) {
            if (control_name == WiimoteEmu::Wiimote::A_BUTTON)     return (wii.buttons & WiimoteEmu::Wiimote::BUTTON_A) ? 1.0 : 0.0;
            if (control_name == WiimoteEmu::Wiimote::B_BUTTON)     return (wii.buttons & WiimoteEmu::Wiimote::BUTTON_B) ? 1.0 : 0.0;
            if (control_name == WiimoteEmu::Wiimote::ONE_BUTTON)   return (wii.buttons & WiimoteEmu::Wiimote::BUTTON_ONE) ? 1.0 : 0.0;
            if (control_name == WiimoteEmu::Wiimote::TWO_BUTTON)   return (wii.buttons & WiimoteEmu::Wiimote::BUTTON_TWO) ? 1.0 : 0.0;
            if (control_name == WiimoteEmu::Wiimote::PLUS_BUTTON)  return (wii.buttons & WiimoteEmu::Wiimote::BUTTON_PLUS) ? 1.0 : 0.0;
            if (control_name == WiimoteEmu::Wiimote::MINUS_BUTTON) return (wii.buttons & WiimoteEmu::Wiimote::BUTTON_MINUS) ? 1.0 : 0.0;
            if (control_name == WiimoteEmu::Wiimote::HOME_BUTTON)  return (wii.buttons & WiimoteEmu::Wiimote::BUTTON_HOME) ? 1.0 : 0.0;
        }

        if (group_name == WiimoteEmu::Wiimote::DPAD_GROUP) {
            if (control_name == "Up")    return (wii.buttons & WiimoteEmu::Wiimote::PAD_UP) ? 1.0 : 0.0;
            if (control_name == "Down")  return (wii.buttons & WiimoteEmu::Wiimote::PAD_DOWN) ? 1.0 : 0.0;
            if (control_name == "Left")  return (wii.buttons & WiimoteEmu::Wiimote::PAD_LEFT) ? 1.0 : 0.0;
            if (control_name == "Right") return (wii.buttons & WiimoteEmu::Wiimote::PAD_RIGHT) ? 1.0 : 0.0;
        }

        if (group_name == WiimoteEmu::Wiimote::IR_GROUP) {
            if (control_name == ControllerEmu::ReshapableInput::X_INPUT_OVERRIDE)
                return wii.irX;
            if (control_name == ControllerEmu::ReshapableInput::Y_INPUT_OVERRIDE)
                return wii.irY;
        }

        return std::nullopt;
    };
}

// Creates an InputOverrideFunction for the Nunchuk extension (stick + C/Z buttons).
static ControllerEmu::InputOverrideFunction MakeNunchukOverride(int playerIndex)
{
    return [playerIndex](const std::string_view group_name,
                         const std::string_view control_name,
                         ControlState /*orig_state*/) -> std::optional<ControlState> {
        std::lock_guard<std::mutex> lock(s_wii_mutex);
        const WiiState& wii = s_wii_status[playerIndex];

        if (group_name == WiimoteEmu::Nunchuk::BUTTONS_GROUP) {
            if (control_name == WiimoteEmu::Nunchuk::C_BUTTON) return (wii.nunchukButtons & WiimoteEmu::Nunchuk::BUTTON_C) ? 1.0 : 0.0;
            if (control_name == WiimoteEmu::Nunchuk::Z_BUTTON) return (wii.nunchukButtons & WiimoteEmu::Nunchuk::BUTTON_Z) ? 1.0 : 0.0;
        }

        if (group_name == WiimoteEmu::Nunchuk::STICK_GROUP) {
            if (control_name == ControllerEmu::ReshapableInput::X_INPUT_OVERRIDE)
                return wii.nunchukX;
            if (control_name == ControllerEmu::ReshapableInput::Y_INPUT_OVERRIDE)
                return wii.nunchukY;
        }

        return std::nullopt;
    };
}

@interface DolphinGameCore ()
{
    NSString *_romPath;
    int _videoWidth;
    int _videoHeight;
    BOOL _isInitialized;
    BOOL _loadFailed;
    BOOL _isWii;
    double _frameInterval;

    // OpenGL state for rendering captured frames into the FBO
    GLuint _glTexture;
    GLuint _glProgram;
    GLuint _glVAO;
    BOOL _glSetup;

    // Display mode state
    NSMutableArray<NSDictionary<NSString *, id> *> *_availableDisplayModes;
}
@end

#pragma mark - Dolphin Host Interface Stubs

#include "Core/Host.h"

std::vector<std::string> Host_GetPreferredLocales() { return {}; }
bool Host_UIBlocksControllerState() { return false; }
bool Host_RendererHasFocus() { return true; }
bool Host_RendererHasFullFocus() { return true; }
bool Host_RendererIsFullscreen() { return false; }
bool Host_TASInputHasFocus() { return false; }
void Host_Message(HostMessageID) {}
void Host_PPCSymbolsChanged() {}
void Host_PPCBreakpointsChanged() {}
void Host_RequestRenderWindowSize(int, int) {}
void Host_UpdateDisasmDialog() {}
void Host_JitCacheInvalidation() {}
void Host_JitProfileDataWiped() {}
void Host_UpdateTitle(const std::string&) {}
void Host_YieldToUI() {}
void Host_TitleChanged() {}
void Host_UpdateDiscordClientID(const std::string&) {}
bool Host_UpdateDiscordPresenceRaw(const std::string&, const std::string&,
                                   const std::string&, const std::string&,
                                   const std::string&, const std::string&,
                                   const int64_t, const int64_t,
                                   const int, const int) { return false; }
std::unique_ptr<GBAHostInterface> Host_CreateGBAHost(std::weak_ptr<HW::GBA::Core>) { return nullptr; }

__weak DolphinGameCore *_current;

@implementation DolphinGameCore

#pragma mark - Lifecycle

- (id)init
{
    if (self = [super init]) {
        _videoWidth = 1280;
        _videoHeight = 960;
        _isInitialized = NO;
        _loadFailed = NO;
        _isWii = NO;
        _frameInterval = 60.0;
        _glTexture = 0;
        _glProgram = 0;
        _glVAO = 0;
        _glSetup = NO;

        // Initialize global pad status (centered sticks, no buttons)
        for (int i = 0; i < 4; i++) {
            memset(&s_pad_status[i], 0, sizeof(GCPadStatus));
            s_pad_status[i].stickX = 0x80;
            s_pad_status[i].stickY = 0x80;
            s_pad_status[i].substickX = 0x80;
            s_pad_status[i].substickY = 0x80;
            s_pad_status[i].isConnected = true;
            s_wii_status[i] = WiiState{};
        }
    }
    _current = self;
    return self;
}

- (void)dealloc
{
    _current = nil;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _romPath = [path copy];

    // Detect if this is a Wii game by checking file extension and disc header
    NSString *ext = [path.pathExtension lowercaseString];
    if ([ext isEqualToString:@"wbfs"] || [ext isEqualToString:@"wad"]) {
        _isWii = YES;
    } else if ([ext isEqualToString:@"iso"] || [ext isEqualToString:@"gcz"] ||
               [ext isEqualToString:@"rvz"] || [ext isEqualToString:@"ciso"] ||
               [ext isEqualToString:@"nkit.iso"] || [ext isEqualToString:@"nkit.gcz"]) {
        // Check disc header magic at offset 0x18 for Wii magic (0x5D1C9EA3)
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (fh) {
            [fh seekToFileOffset:0x18];
            NSData *magic = [fh readDataOfLength:4];
            if (magic.length == 4) {
                const uint8_t *bytes = (const uint8_t *)magic.bytes;
                if (bytes[0] == 0x5D && bytes[1] == 0x1C && bytes[2] == 0x9E && bytes[3] == 0xA3) {
                    _isWii = YES;
                }
            }
            [fh closeFile];
        }
    }

    NSLog(@"[Dolphin] Loaded path: %@ (Wii: %@)", _romPath, _isWii ? @"YES" : @"NO");
    return YES;
}

- (void)setupEmulation
{
    NSString *supportPath = [self supportDirectoryPath];
    NSString *savesPath = [self batterySavesDirectoryPath];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:supportPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"User"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"User/Config"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"User/GC"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"User/Wii"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"User/Cache"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"User/Dump"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"User/StateSaves"]
  withIntermediateDirectories:YES attributes:nil error:nil];

    // Copy GameCube BIOS files from OpenEmu's BIOS directory to Dolphin's User paths.
    // Each IPL variant maps to one or more region directories. NTSC variants go to
    // both USA and JAP since the same BIOS works for both regions. DSP ROMs go to GC root.
    NSString *biosPath = [self biosDirectoryPath];
    NSString *userDir = [supportPath stringByAppendingPathComponent:@"User"];

    // IPL BIOS mappings: source filename -> array of destination paths under User/GC/
    NSDictionary<NSString *, NSArray<NSString *> *> *iplMappings = @{
        @"gc-ntsc-10.bin": @[@"USA/IPL.bin", @"JAP/IPL.bin"],
        @"gc-ntsc-11.bin": @[@"USA/IPL.bin", @"JAP/IPL.bin"],
        @"gc-ntsc-12.bin": @[@"USA/IPL.bin", @"JAP/IPL.bin"],
        @"gc-pal-10.bin":  @[@"EUR/IPL.bin"],
        @"gc-pal-11.bin":  @[@"EUR/IPL.bin"],
        @"gc-pal-12.bin":  @[@"EUR/IPL.bin"],
    };

    BOOL hasIPL = NO;
    for (NSString *biosName in iplMappings) {
        NSString *src = [biosPath stringByAppendingPathComponent:biosName];
        if ([fm fileExistsAtPath:src]) {
            hasIPL = YES;
            for (NSString *relPath in iplMappings[biosName]) {
                NSString *dst = [NSString stringWithFormat:@"%@/GC/%@", userDir, relPath];
                [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
              withIntermediateDirectories:YES attributes:nil error:nil];
                // Always overwrite so the latest imported version wins
                [fm removeItemAtPath:dst error:nil];
                [fm copyItemAtPath:src toPath:dst error:nil];
                NSLog(@"[Dolphin] Copied %@ to %@", biosName, dst);
            }
        }
    }

    // DSP ROMs for Low-Level Emulation
    for (NSString *dspFile in @[@"dsp_coef.bin", @"dsp_rom.bin"]) {
        NSString *src = [biosPath stringByAppendingPathComponent:dspFile];
        if ([fm fileExistsAtPath:src]) {
            NSString *dst = [NSString stringWithFormat:@"%@/GC/%@", userDir, dspFile];
            [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:nil];
            if (![fm fileExistsAtPath:dst]) {
                [fm copyItemAtPath:src toPath:dst error:nil];
                NSLog(@"[Dolphin] Copied %@ to %@", dspFile, dst);
            }
        }
    }

    NSLog(@"[Dolphin] Support path: %@", supportPath);
    NSLog(@"[Dolphin] Saves path: %@", savesPath);

    // Set Dolphin's user directory BEFORE calling UICommon::Init()
    UICommon::SetUserDirectory(std::string([supportPath stringByAppendingPathComponent:@"User/"].fileSystemRepresentation));

    // Disable SDL3's joystick/gamepad hardware backends via environment variables.
    // SDL3 checks these before SDL_Init(). When UICommon::InitControllers() creates
    // the SDL backend, SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD) is called.
    // On macOS, SDL3's MFI backend uses GameController.framework which creates a
    // GCHIDEventSystemClient / IOHIDEventSystemConnection. When the helper process
    // exits, WindowServer tears down that connection, which disrupts HID event
    // routing for OTHER helper processes (causing controller corruption in other
    // emulator cores). We don't need any SDL hardware detection since we use
    // InputOverrideFunction to feed input from OpenEmu's own controller system.
    setenv("SDL_JOYSTICK_MFI", "0", 1);      // Disable GameController.framework
    setenv("SDL_JOYSTICK_IOKIT", "0", 1);     // Disable IOKit joystick backend
    setenv("SDL_JOYSTICK_HIDAPI", "0", 1);    // Disable HIDAPI joystick backend

    // Initialize Dolphin's subsystems (Config layers, SConfig, logging, etc.)
    // This MUST be called before any Config::Set*() calls.
    UICommon::Init();

    // Use SetCurrent() (CurrentRun layer) instead of SetBase() for all settings.
    // The CurrentRun layer has the highest priority in Dolphin's config system,
    // so these values cannot be overridden by game-specific INI files or stale
    // Dolphin.ini settings. Additionally, the CurrentRun layer is never saved
    // to disk, which prevents config corruption across launches.

    // Use the Metal backend for GPU-accelerated rendering. Running in headless mode
    // (WindowSystemType::Headless, no CAMetalLayer), the Presenter reads back each
    // frame via a staging texture and delivers RGBA8 pixel data through a callback.
    Config::SetCurrent(Config::MAIN_GFX_BACKEND, std::string("Metal"));

    // Render at 2x native resolution (1280x960 for GC, ~1280x1056 for Wii)
    Config::SetCurrent(Config::GFX_EFB_SCALE, 2);

    // Disable VSync — OpenEmu drives frame timing externally via executeFrame
    Config::SetCurrent(Config::GFX_VSYNC, false);

    // Disable analytics and auto-updates
    Config::SetCurrent(Config::MAIN_ANALYTICS_ENABLED, false);

    // Use the OpenEmu audio backend — keeps the mixer active at 48 kHz so we can
    // pull mixed samples in executeFrame and write them to OpenEmu's ring buffer.
    Config::SetCurrent(Config::MAIN_AUDIO_BACKEND, std::string(BACKEND_OPENEMU));

    // Keep Dolphin's speed limiter at native speed. Dolphin's CPU thread handles
    // its own frame pacing via CoreTiming::Throttle(), and OpenEmu's executeFrame
    // just picks up whatever the latest rendered frame is.
    Config::SetCurrent(Config::MAIN_EMULATION_SPEED, 1.0f);

    // Increase audio latency to reduce crackling/popping. The default (20ms) is too
    // tight for the OpenEmu ring buffer architecture where audio and video are driven
    // by separate cadences. A larger buffer absorbs timing jitter between Dolphin's
    // audio thread and the AVAudioEngine consumer.
    Config::SetCurrent(Config::MAIN_AUDIO_LATENCY, 64);

    // Enable GPU sync for more stable frame pacing
    Config::SetCurrent(Config::MAIN_SYNC_GPU, true);

    // Show the GameCube boot screen when a BIOS (IPL) file is present
    Config::SetCurrent(Config::MAIN_SKIP_IPL, !hasIPL);

    // Configure emulated controllers so Dolphin actually polls them.
    // Without this, fresh installs default to SIDEVICE_NONE / WiimoteSource::None,
    // which means Dolphin never reads the emulated pads and our input overrides
    // have no effect.
    for (int i = 0; i < 4; i++) {
        Config::SetCurrent(Config::GetInfoForSIDevice(i),
                           SerialInterface::SIDEVICE_GC_CONTROLLER);
    }
    if (_isWii) {
        for (int i = 0; i < 4; i++) {
            Config::SetCurrent(Config::GetInfoForWiimoteSource(i), WiimoteSource::Emulated);
        }
    }

    NSLog(@"[Dolphin] Emulation setup complete (controllers configured for %@)",
          _isWii ? @"Wii" : @"GameCube");
}

- (void)startEmulation
{
    [super startEmulation];
}

- (void)stopEmulation
{
    // Clear callbacks before shutdown to prevent writes to freed memory
    ClearPresenterFrameCaptureCallback();
    OpenEmuStream::ClearAudioCallback();

    if (_isInitialized) {
        // Clear input overrides before stopping the core
        if (_isWii) {
            auto* wiiConfig = Wiimote::GetConfig();
            for (int i = 0; i < 4; i++) {
                auto* wiimote = static_cast<WiimoteEmu::Wiimote*>(wiiConfig->GetController(i));
                wiimote->ClearInputOverrideFunction();
                auto& attachments = static_cast<ControllerEmu::Attachments*>(
                    wiimote->GetWiimoteGroup(WiimoteEmu::WiimoteGroup::Attachments))
                    ->GetAttachmentList();
                attachments[WiimoteEmu::ExtensionNumber::NUNCHUK]->ClearInputOverrideFunction();
            }
        } else {
            auto* padConfig = Pad::GetConfig();
            for (int i = 0; i < 4; i++) {
                padConfig->GetController(i)->ClearInputOverrideFunction();
            }
        }

        auto& system = Core::System::GetInstance();
        Core::Stop(system);
        Core::Shutdown(system);
        _isInitialized = NO;
    }

    // Clean up GL resources
    if (_glTexture) { glDeleteTextures(1, &_glTexture); _glTexture = 0; }
    if (_glProgram) { glDeleteProgram(_glProgram); _glProgram = 0; }
    if (_glVAO) { glDeleteVertexArrays(1, &_glVAO); _glVAO = 0; }
    _glSetup = NO;

    UICommon::ShutdownControllers();
    UICommon::Shutdown();

    // Clean up SDL environment overrides
    unsetenv("SDL_JOYSTICK_MFI");
    unsetenv("SDL_JOYSTICK_IOKIT");
    unsetenv("SDL_JOYSTICK_HIDAPI");

    [super stopEmulation];
}

- (void)setPauseEmulation:(BOOL)pauseEmulation
{
    [super setPauseEmulation:pauseEmulation];

    if (_isInitialized && Core::IsRunning(Core::System::GetInstance())) {
        if (pauseEmulation) {
            Core::SetState(Core::System::GetInstance(), Core::State::Paused);
        } else {
            Core::SetState(Core::System::GetInstance(), Core::State::Running);
        }
    }
}

- (void)resetEmulation
{
    if (_isInitialized) {
        auto& system = Core::System::GetInstance();
        // Request a reset through the processor interface
        system.GetProcessorInterface().ResetButton_Tap();
    }
}

#pragma mark - GL Setup for Frame Rendering

static GLuint CompileShader(GLenum type, const char* source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    return shader;
}

- (void)setupGL
{
    if (_glSetup) return;

    // Vertex shader: fullscreen triangle using gl_VertexID
    const char* vertSrc =
        "#version 150\n"
        "out vec2 vTexCoord;\n"
        "void main() {\n"
        "    vec2 pos = vec2(gl_VertexID & 1, (gl_VertexID & 2) >> 1);\n"
        "    gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0);\n"
        "    vTexCoord = vec2(pos.x, 1.0 - pos.y);\n"
        "}\n";

    // Fragment shader: sample the texture
    const char* fragSrc =
        "#version 150\n"
        "in vec2 vTexCoord;\n"
        "out vec4 fragColor;\n"
        "uniform sampler2D tex;\n"
        "void main() {\n"
        "    fragColor = texture(tex, vTexCoord);\n"
        "}\n";

    GLuint vs = CompileShader(GL_VERTEX_SHADER, vertSrc);
    GLuint fs = CompileShader(GL_FRAGMENT_SHADER, fragSrc);

    _glProgram = glCreateProgram();
    glAttachShader(_glProgram, vs);
    glAttachShader(_glProgram, fs);
    glLinkProgram(_glProgram);
    glDeleteShader(vs);
    glDeleteShader(fs);

    glUseProgram(_glProgram);
    glUniform1i(glGetUniformLocation(_glProgram, "tex"), 0);

    // Create texture for frame upload
    glGenTextures(1, &_glTexture);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _glTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    // Create VAO (required for GL Core Profile, but no vertex attributes needed)
    glGenVertexArrays(1, &_glVAO);

    _glSetup = YES;
    NSLog(@"[Dolphin] OpenGL rendering setup complete");
}

#pragma mark - Frame Execution

- (void)executeFrame
{
    if (_loadFailed) return;

    if (!_isInitialized) {
        try {
            NSLog(@"[Dolphin] Booting ROM: %@", _romPath);

            auto& system = Core::System::GetInstance();

            // Create boot parameters from the game file
            auto boot = BootParameters::GenerateFromFile(
                std::string([_romPath fileSystemRepresentation]));

            if (!boot) {
                NSLog(@"[Dolphin] Failed to create boot parameters");
                _loadFailed = YES;
                return;
            }

            // Set up window system info — headless (Metal without a CAMetalLayer)
            WindowSystemInfo wsi;
            wsi.type = WindowSystemType::Headless;
            wsi.render_window = nullptr;
            wsi.render_surface = nullptr;
            wsi.render_surface_scale = 1.0f;

            // Initialize controller interface before starting emulation.
            // EmuThread asserts g_controller_interface.IsInit() at startup.
            UICommon::InitControllers(wsi);
            NSLog(@"[Dolphin] InitControllers complete, IsInit=%d", g_controller_interface.IsInit());

            // Register input overrides BEFORE booting the core.
            // BootManager::BootCore() spawns the EmuThread which immediately
            // begins polling controllers. The override function must be set
            // before boot so GCPadEmu::GetInput() sees it during its
            // connection check (m_input_override_function must be truthy).
            if (_isWii) {
                auto* wiiConfig = Wiimote::GetConfig();
                for (int i = 0; i < 4; i++) {
                    auto* wiimote = static_cast<WiimoteEmu::Wiimote*>(wiiConfig->GetController(i));
                    wiimote->SetInputOverrideFunction(MakeWiimoteOverride(i));

                    auto& attachments = static_cast<ControllerEmu::Attachments*>(
                        wiimote->GetWiimoteGroup(WiimoteEmu::WiimoteGroup::Attachments))
                        ->GetAttachmentList();
                    attachments[WiimoteEmu::ExtensionNumber::NUNCHUK]
                        ->SetInputOverrideFunction(MakeNunchukOverride(i));
                }
                NSLog(@"[Dolphin] Registered Wiimote+Nunchuk input overrides for 4 players");
            } else {
                auto* padConfig = Pad::GetConfig();
                for (int i = 0; i < 4; i++) {
                    padConfig->GetController(i)->SetInputOverrideFunction(MakeGCPadOverride(i));
                }
                NSLog(@"[Dolphin] Registered GCPad input overrides for 4 players");
            }

            // Register the frame capture callback BEFORE booting.
            // The Presenter calls this from Dolphin's GPU thread whenever a
            // frame is ready in headless mode, reading back RGBA8 pixel data
            // from the XFB texture via a staging texture.
            SetPresenterFrameCaptureCallback([](const u8* data, u32 width, u32 height, u32 stride) {
                // Write into back buffer (no lock needed for the write itself)
                size_t size = static_cast<size_t>(stride) * height;
                if (s_framebuf_back.data.size() != size)
                    s_framebuf_back.data.resize(size);
                memcpy(s_framebuf_back.data.data(), data, size);
                s_framebuf_back.width = width;
                s_framebuf_back.height = height;

                // Swap back→front under lock (swap is O(1), just pointer exchange)
                {
                    std::lock_guard<std::mutex> lock(s_framebuf_mutex);
                    std::swap(s_framebuf_back, s_framebuf_front);
                }
                s_framebuf_new.store(true, std::memory_order_release);
            });

            // Register audio callback — the OpenEmuStream's background thread
            // continuously mixes audio and delivers it here.
            __weak DolphinGameCore *weakSelf = self;
            OpenEmuStream::SetAudioCallback([weakSelf](const s16* samples, u32 byteCount) {
                DolphinGameCore *strongSelf = weakSelf;
                if (strongSelf) {
                    [[strongSelf audioBufferAtIndex:0] write:(const void*)samples
                                                   maxLength:byteCount];
                }
            });

            // Log SI device configuration to verify controllers are set up
            for (int i = 0; i < 4; i++) {
                auto siDevice = Config::Get(Config::GetInfoForSIDevice(i));
                NSLog(@"[Dolphin] SI Device %d = %d (want %d=GC_CONTROLLER)",
                      i, static_cast<int>(siDevice),
                      static_cast<int>(SerialInterface::SIDEVICE_GC_CONTROLLER));
            }

            // Boot through BootManager which handles SYSCONF, config layers,
            // system initialization, and then calls Core::Init() internally.
            if (!BootManager::BootCore(system, std::move(boot), wsi)) {
                NSLog(@"[Dolphin] BootManager::BootCore failed");
                ClearPresenterFrameCaptureCallback();
                OpenEmuStream::ClearAudioCallback();
                _loadFailed = YES;
                return;
            }

            _isInitialized = YES;

            NSLog(@"[Dolphin] Game booted successfully (%@)", _isWii ? @"Wii" : @"GameCube");
        } catch (const std::exception &e) {
            NSLog(@"[Dolphin] Error booting game: %s", e.what());
            ClearPresenterFrameCaptureCallback();
            OpenEmuStream::ClearAudioCallback();
            _loadFailed = YES;
            return;
        } catch (...) {
            NSLog(@"[Dolphin] Unknown error booting game");
            ClearPresenterFrameCaptureCallback();
            OpenEmuStream::ClearAudioCallback();
            _loadFailed = YES;
            return;
        }
    }

    // Dolphin runs its own CPU/GPU threads; we just need to process host events.
    // Audio is delivered asynchronously via the OpenEmuStream callback.
    auto& system = Core::System::GetInstance();
    Core::HostDispatchJobs(system);

    // Set up GL rendering resources on first frame (must be on OpenEmu's GL thread)
    [self setupGL];

    // Present the rendered frame through OpenEmu's FBO
    [self.renderDelegate presentDoubleBufferedFBO];

    // Upload the latest captured frame from Dolphin's Metal backend to the GL texture.
    // We swap the front buffer into a local copy under lock (O(1) pointer swap),
    // then do the expensive GL upload outside the lock so the GPU callback isn't blocked.
    if (s_framebuf_new.load(std::memory_order_acquire)) {
        s_framebuf_new.store(false, std::memory_order_relaxed);

        FrameBuffer localFrame;
        {
            std::lock_guard<std::mutex> lock(s_framebuf_mutex);
            std::swap(localFrame, s_framebuf_front);
        }

        if (localFrame.width > 0 && localFrame.height > 0) {
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, _glTexture);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)localFrame.width);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8,
                         (GLsizei)localFrame.width, (GLsizei)localFrame.height,
                         0, GL_RGBA, GL_UNSIGNED_BYTE, localFrame.data.data());
        }
    }

    // Draw the texture as a fullscreen quad into OpenEmu's FBO
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glViewport(0, 0, _videoWidth, _videoHeight);

    glUseProgram(_glProgram);
    glBindVertexArray(_glVAO);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

#pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingOpenGL3Video;
}

- (BOOL)needsDoubleBufferedFBO
{
    return YES;
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(_videoWidth, _videoHeight);
}

- (OEIntSize)aspectSize
{
    if (_isWii) {
        return OEIntSizeMake(16, 9);
    }
    return OEIntSizeMake(4, 3);
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval;
}

#pragma mark - Audio

- (NSUInteger)channelCount
{
    return 2;
}

- (double)audioSampleRate
{
    return SAMPLERATE;
}

#pragma mark - Display Modes

- (NSArray <NSDictionary <NSString *, id> *> *)displayModes
{
    if (_availableDisplayModes.count == 0) {
        _availableDisplayModes = (NSMutableArray *)CFBridgingRelease(
            CFPropertyListCreateDeepCopy(kCFAllocatorDefault, (CFArrayRef)@[
                OEDisplayMode_Label(@"Sensor Bar Position"),
                OEDisplayMode_OptionDefault(@"Top", @"sensorBarPosition"),
                OEDisplayMode_Option(@"Bottom", @"sensorBarPosition"),
                OEDisplayMode_SeparatorItem(),
                OEDisplayMode_Label(@"Wii Remote"),
                OEDisplayMode_OptionToggleable(@"Use Real Wii Remote", @"realWiimote"),
                OEDisplayMode_OptionToggleable(@"Use Real Balance Board", @"realBalanceBoard"),
            ], kCFPropertyListMutableContainers));
    }

    return [_availableDisplayModes copy];
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
    NSArray *displayModes = [self displayModes];

    // Find the selected mode in our display modes array
    __block NSString *prefKey = nil;
    __block BOOL isToggleable = NO;
    __block BOOL currentState = NO;

    // Search for the mode, including within submenus
    void (^searchModes)(NSArray *) = ^(NSArray *modes) {
        for (NSMutableDictionary *mode in modes) {
            if ([mode[OEGameCoreDisplayModeGroupNameKey] length] > 0) {
                // Submenu — search its children
                NSMutableArray *items = mode[OEGameCoreDisplayModeGroupItemsKey];
                for (NSMutableDictionary *subMode in items) {
                    if ([subMode[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode]) {
                        prefKey = subMode[OEGameCoreDisplayModePrefKeyNameKey];
                        isToggleable = [subMode[OEGameCoreDisplayModeAllowsToggleKey] boolValue];
                        currentState = [subMode[OEGameCoreDisplayModeStateKey] boolValue];
                        return;
                    }
                }
            } else if ([mode[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode]) {
                prefKey = mode[OEGameCoreDisplayModePrefKeyNameKey];
                isToggleable = [mode[OEGameCoreDisplayModeAllowsToggleKey] boolValue];
                currentState = [mode[OEGameCoreDisplayModeStateKey] boolValue];
                return;
            }
        }
    };
    searchModes(_availableDisplayModes);

    if (!prefKey) return;

    // Update state in the display modes array
    if (isToggleable) {
        // Toggle the state of this specific option
        for (NSMutableDictionary *mode in _availableDisplayModes) {
            if ([mode[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode]) {
                mode[OEGameCoreDisplayModeStateKey] = @(!currentState);
                break;
            }
        }
    } else {
        // Mutually-exclusive: enable this option, disable others with same prefKey
        for (NSMutableDictionary *mode in _availableDisplayModes) {
            if ([mode[OEGameCoreDisplayModeGroupNameKey] length] > 0) {
                NSMutableArray *items = mode[OEGameCoreDisplayModeGroupItemsKey];
                for (NSMutableDictionary *subMode in items) {
                    if ([subMode[OEGameCoreDisplayModePrefKeyNameKey] isEqualToString:prefKey]) {
                        subMode[OEGameCoreDisplayModeStateKey] =
                            @([subMode[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode]);
                    }
                }
            } else if ([mode[OEGameCoreDisplayModePrefKeyNameKey] isEqualToString:prefKey]) {
                mode[OEGameCoreDisplayModeStateKey] =
                    @([mode[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode]);
            }
        }
    }

    // Apply the setting change (use SetCurrent to avoid persisting to Dolphin.ini)
    if ([prefKey isEqualToString:@"sensorBarPosition"]) {
        if ([displayMode isEqualToString:@"Bottom"]) {
            Config::SetCurrent(Config::SYSCONF_SENSOR_BAR_POSITION, static_cast<u32>(0x01));
        } else {
            // Top (default)
            Config::SetCurrent(Config::SYSCONF_SENSOR_BAR_POSITION, static_cast<u32>(0x00));
        }
        NSLog(@"[Dolphin] Sensor bar position set to: %@", displayMode);
    }

    if ([prefKey isEqualToString:@"realWiimote"]) {
        BOOL enabled = !currentState; // toggled state
        // Set all 4 Wiimote slots to Real or Emulated
        for (int i = 0; i < 4; i++) {
            Config::SetCurrent(Config::GetInfoForWiimoteSource(i),
                               enabled ? WiimoteSource::Real : WiimoteSource::Emulated);
        }

        if (enabled && _isInitialized) {
            // Trigger a scan for connected Wiimotes
            WiimoteReal::Refresh();
        }
        NSLog(@"[Dolphin] Real Wii Remote: %@", enabled ? @"enabled" : @"disabled");
    }

    if ([prefKey isEqualToString:@"realBalanceBoard"]) {
        BOOL enabled = !currentState; // toggled state
        Config::SetCurrent(Config::WIIMOTE_BB_SOURCE,
                           enabled ? WiimoteSource::Real : WiimoteSource::None);

        if (enabled && _isInitialized) {
            WiimoteReal::Refresh();
        }
        NSLog(@"[Dolphin] Real Balance Board: %@", enabled ? @"enabled" : @"disabled");
    }
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (!_isInitialized) {
        block(NO, nil);
        return;
    }

    auto& system = Core::System::GetInstance();
    if (!Core::IsRunning(system)) {
        block(NO, nil);
        return;
    }

    // State::SaveAs is asynchronous — it schedules the state capture on the
    // CPU thread, then compresses and writes the file on a worker thread.
    // We post a sentinel job after the save to wait for it to complete.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    State::SaveAs(system, std::string([fileName fileSystemRepresentation]));

    // Post a sentinel job to the CPU thread — when it runs, the save-state
    // job that was posted before it has completed its CPU-thread work.
    Core::RunOnCPUThread(system, [sem] {
        dispatch_semaphore_signal(sem);
    });

    long result = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (result != 0) {
        block(NO, [NSError errorWithDomain:@"org.openemu.dolphin" code:-1
                                  userInfo:@{NSLocalizedDescriptionKey: @"Save state timed out"}]);
    } else {
        block(YES, nil);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (!_isInitialized) {
        block(NO, nil);
        return;
    }

    auto& system = Core::System::GetInstance();
    if (!Core::IsRunning(system)) {
        block(NO, nil);
        return;
    }

    // State::LoadAs is asynchronous — it schedules the load on the CPU thread.
    // We post a sentinel job after the load to wait for it to complete.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    State::LoadAs(system, std::string([fileName fileSystemRepresentation]));

    Core::RunOnCPUThread(system, [sem] {
        dispatch_semaphore_signal(sem);
    });

    long result = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (result != 0) {
        block(NO, [NSError errorWithDomain:@"org.openemu.dolphin" code:-1
                                  userInfo:@{NSLocalizedDescriptionKey: @"Load state timed out"}]);
    } else {
        block(YES, nil);
    }
}

#pragma mark - GameCube Input

- (oneway void)didMoveGCJoystickDirection:(OEGCButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    std::lock_guard<std::mutex> lock(s_pad_mutex);

    // Convert from [-1.0, 1.0] range to [0, 255] range (centered at 0x80)
    switch (button) {
        case OEGCAnalogUp:
            s_pad_status[player].stickY = 0x80 + (u8)(value * 0x7F);
            break;
        case OEGCAnalogDown:
            s_pad_status[player].stickY = 0x80 - (u8)(value * 0x7F);
            break;
        case OEGCAnalogLeft:
            s_pad_status[player].stickX = 0x80 - (u8)(value * 0x7F);
            break;
        case OEGCAnalogRight:
            s_pad_status[player].stickX = 0x80 + (u8)(value * 0x7F);
            break;
        case OEGCAnalogCUp:
            s_pad_status[player].substickY = 0x80 + (u8)(value * 0x7F);
            break;
        case OEGCAnalogCDown:
            s_pad_status[player].substickY = 0x80 - (u8)(value * 0x7F);
            break;
        case OEGCAnalogCLeft:
            s_pad_status[player].substickX = 0x80 - (u8)(value * 0x7F);
            break;
        case OEGCAnalogCRight:
            s_pad_status[player].substickX = 0x80 + (u8)(value * 0x7F);
            break;
        case OEGCButtonL:
            s_pad_status[player].triggerLeft = (u8)(value * 0xFF);
            break;
        case OEGCButtonR:
            s_pad_status[player].triggerRight = (u8)(value * 0xFF);
            break;
        default:
            break;
    }
}

- (oneway void)didPushGCButton:(OEGCButton)button forPlayer:(NSUInteger)player
{
    NSLog(@"[Dolphin] didPushGCButton: button=%lu player=%lu", (unsigned long)button, (unsigned long)player);
    player -= 1;
    if (player > 3) return;

    std::lock_guard<std::mutex> lock(s_pad_mutex);

    switch (button) {
        case OEGCButtonUp:    s_pad_status[player].button |= PAD_BUTTON_UP; break;
        case OEGCButtonDown:  s_pad_status[player].button |= PAD_BUTTON_DOWN; break;
        case OEGCButtonLeft:  s_pad_status[player].button |= PAD_BUTTON_LEFT; break;
        case OEGCButtonRight: s_pad_status[player].button |= PAD_BUTTON_RIGHT; break;
        case OEGCButtonA:     s_pad_status[player].button |= PAD_BUTTON_A; break;
        case OEGCButtonB:     s_pad_status[player].button |= PAD_BUTTON_B; break;
        case OEGCButtonX:     s_pad_status[player].button |= PAD_BUTTON_X; break;
        case OEGCButtonY:     s_pad_status[player].button |= PAD_BUTTON_Y; break;
        case OEGCButtonZ:     s_pad_status[player].button |= PAD_TRIGGER_Z; break;
        case OEGCButtonL:     s_pad_status[player].button |= PAD_TRIGGER_L; break;
        case OEGCButtonR:     s_pad_status[player].button |= PAD_TRIGGER_R; break;
        case OEGCButtonStart: s_pad_status[player].button |= PAD_BUTTON_START; break;
        default: break;
    }
}

- (oneway void)didReleaseGCButton:(OEGCButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    std::lock_guard<std::mutex> lock(s_pad_mutex);

    switch (button) {
        case OEGCButtonUp:    s_pad_status[player].button &= ~PAD_BUTTON_UP; break;
        case OEGCButtonDown:  s_pad_status[player].button &= ~PAD_BUTTON_DOWN; break;
        case OEGCButtonLeft:  s_pad_status[player].button &= ~PAD_BUTTON_LEFT; break;
        case OEGCButtonRight: s_pad_status[player].button &= ~PAD_BUTTON_RIGHT; break;
        case OEGCButtonA:     s_pad_status[player].button &= ~PAD_BUTTON_A; break;
        case OEGCButtonB:     s_pad_status[player].button &= ~PAD_BUTTON_B; break;
        case OEGCButtonX:     s_pad_status[player].button &= ~PAD_BUTTON_X; break;
        case OEGCButtonY:     s_pad_status[player].button &= ~PAD_BUTTON_Y; break;
        case OEGCButtonZ:     s_pad_status[player].button &= ~PAD_TRIGGER_Z; break;
        case OEGCButtonL:     s_pad_status[player].button &= ~PAD_TRIGGER_L; break;
        case OEGCButtonR:     s_pad_status[player].button &= ~PAD_TRIGGER_R; break;
        case OEGCButtonStart: s_pad_status[player].button &= ~PAD_BUTTON_START; break;
        default: break;
    }
}

#pragma mark - Peripheral Devices

- (NSArray<NSDictionary<NSString *, id> *> *)peripheralDevices
{
    NSMutableArray *ports = [NSMutableArray array];

    // SI Controller Ports (0-3)
    NSDictionary *siDeviceNames = @{
        @(SerialInterface::SIDEVICE_GC_CONTROLLER): @"Standard Controller",
        @(SerialInterface::SIDEVICE_DANCEMAT):      @"Dance Mat",
        @(SerialInterface::SIDEVICE_GC_TARUKONGA):  @"DK Bongos",
        @(SerialInterface::SIDEVICE_GC_KEYBOARD):   @"Keyboard",
        @(SerialInterface::SIDEVICE_GC_STEERING):   @"Steering Wheel",
        @(SerialInterface::SIDEVICE_GC_GBA):        @"GBA",
        @(SerialInterface::SIDEVICE_NONE):          @"None",
    };

    for (int i = 0; i < 4; i++) {
        auto current = Config::Get(Config::GetInfoForSIDevice(i));
        NSMutableArray *devices = [NSMutableArray array];
        for (NSNumber *type in siDeviceNames) {
            [devices addObject:@{
                OEPeripheralDeviceNameKey: siDeviceNames[type],
                OEPeripheralDeviceIdentifierKey: [NSString stringWithFormat:@"gc.si.%d", type.intValue],
                OEPeripheralDeviceSelectedKey: @(type.intValue == (int)current),
            }];
        }

        [ports addObject:@{
            OEPeripheralPortNameKey: [NSString stringWithFormat:@"Controller Port %d", i + 1],
            OEPeripheralPortIdentifierKey: [NSString stringWithFormat:@"si.%d", i],
            OEPeripheralPortDevicesKey: devices,
        }];
    }

    // EXI Slots (Memory Card A and B)
    NSDictionary *exiDeviceNames = @{
        @((int)ExpansionInterface::EXIDeviceType::MemoryCardFolder): @"GCI Folder",
        @((int)ExpansionInterface::EXIDeviceType::MemoryCard):       @"Memory Card",
        @((int)ExpansionInterface::EXIDeviceType::None):             @"None",
    };

    NSArray *exiSlotNames = @[@"Slot A", @"Slot B"];
    ExpansionInterface::Slot exiSlots[] = {
        ExpansionInterface::Slot::A,
        ExpansionInterface::Slot::B,
    };

    for (int slot = 0; slot < 2; slot++) {
        auto current = Config::Get(Config::GetInfoForEXIDevice(exiSlots[slot]));
        NSMutableArray *devices = [NSMutableArray array];
        for (NSNumber *type in exiDeviceNames) {
            [devices addObject:@{
                OEPeripheralDeviceNameKey: exiDeviceNames[type],
                OEPeripheralDeviceIdentifierKey: [NSString stringWithFormat:@"gc.exi.%d", type.intValue],
                OEPeripheralDeviceSelectedKey: @(type.intValue == (int)current),
            }];
        }

        [ports addObject:@{
            OEPeripheralPortNameKey: exiSlotNames[slot],
            OEPeripheralPortIdentifierKey: [NSString stringWithFormat:@"exi.%d", slot],
            OEPeripheralPortDevicesKey: devices,
        }];
    }

    // SP2 (Serial Port 2 — Microphone)
    auto currentSP2 = Config::Get(Config::GetInfoForEXIDevice(ExpansionInterface::Slot::SP2));
    [ports addObject:@{
        OEPeripheralPortNameKey: @"Serial Port 2",
        OEPeripheralPortIdentifierKey: @"exi.sp2",
        OEPeripheralPortDevicesKey: @[
            @{
                OEPeripheralDeviceNameKey: @"Microphone",
                OEPeripheralDeviceIdentifierKey: @"gc.exi.mic",
                OEPeripheralDeviceSelectedKey: @(currentSP2 == ExpansionInterface::EXIDeviceType::Microphone),
            },
            @{
                OEPeripheralDeviceNameKey: @"None",
                OEPeripheralDeviceIdentifierKey: @"gc.exi.none",
                OEPeripheralDeviceSelectedKey: @(currentSP2 != ExpansionInterface::EXIDeviceType::Microphone),
            },
        ],
    }];

    return ports;
}

- (void)changePeripheralForPort:(NSString *)portIdentifier toDevice:(NSString *)deviceIdentifier
{
    if ([portIdentifier isEqualToString:@"__reset__"]) {
        // Reset to defaults: 4 GC controllers, GCI folders in A & B, no mic
        for (int i = 0; i < 4; i++) {
            Config::SetCurrent(Config::GetInfoForSIDevice(i),
                               SerialInterface::SIDEVICE_GC_CONTROLLER);
        }
        Config::SetCurrent(Config::GetInfoForEXIDevice(ExpansionInterface::Slot::A),
                           ExpansionInterface::EXIDeviceType::MemoryCardFolder);
        Config::SetCurrent(Config::GetInfoForEXIDevice(ExpansionInterface::Slot::B),
                           ExpansionInterface::EXIDeviceType::None);
        Config::SetCurrent(Config::GetInfoForEXIDevice(ExpansionInterface::Slot::SP2),
                           ExpansionInterface::EXIDeviceType::None);
        return;
    }

    if ([portIdentifier hasPrefix:@"si."]) {
        int channel = [[portIdentifier substringFromIndex:3] intValue];
        int deviceType = [[deviceIdentifier componentsSeparatedByString:@"."].lastObject intValue];
        Config::SetCurrent(Config::GetInfoForSIDevice(channel),
                           static_cast<SerialInterface::SIDevices>(deviceType));
    }
    else if ([portIdentifier isEqualToString:@"exi.sp2"]) {
        if ([deviceIdentifier isEqualToString:@"gc.exi.mic"]) {
            Config::SetCurrent(Config::GetInfoForEXIDevice(ExpansionInterface::Slot::SP2),
                               ExpansionInterface::EXIDeviceType::Microphone);
        } else {
            Config::SetCurrent(Config::GetInfoForEXIDevice(ExpansionInterface::Slot::SP2),
                               ExpansionInterface::EXIDeviceType::None);
        }
    }
    else if ([portIdentifier hasPrefix:@"exi."]) {
        int slot = [[portIdentifier substringFromIndex:4] intValue];
        int deviceType = [[deviceIdentifier componentsSeparatedByString:@"."].lastObject intValue];
        ExpansionInterface::Slot exiSlot = (slot == 0) ? ExpansionInterface::Slot::A : ExpansionInterface::Slot::B;
        Config::SetCurrent(Config::GetInfoForEXIDevice(exiSlot),
                           static_cast<ExpansionInterface::EXIDeviceType>(deviceType));
    }
}

#pragma mark - Wii Input

- (oneway void)didPushWiiButton:(OEWiiButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    std::lock_guard<std::mutex> lock(s_wii_mutex);

    switch (button) {
        // Wiimote D-Pad
        case OEWiiButtonUp:    s_wii_status[player].buttons |= WiimoteEmu::Wiimote::PAD_UP; break;
        case OEWiiButtonDown:  s_wii_status[player].buttons |= WiimoteEmu::Wiimote::PAD_DOWN; break;
        case OEWiiButtonLeft:  s_wii_status[player].buttons |= WiimoteEmu::Wiimote::PAD_LEFT; break;
        case OEWiiButtonRight: s_wii_status[player].buttons |= WiimoteEmu::Wiimote::PAD_RIGHT; break;
        // Wiimote Buttons
        case OEWiiButtonA:     s_wii_status[player].buttons |= WiimoteEmu::Wiimote::BUTTON_A; break;
        case OEWiiButtonB:     s_wii_status[player].buttons |= WiimoteEmu::Wiimote::BUTTON_B; break;
        case OEWiiButton1:     s_wii_status[player].buttons |= WiimoteEmu::Wiimote::BUTTON_ONE; break;
        case OEWiiButton2:     s_wii_status[player].buttons |= WiimoteEmu::Wiimote::BUTTON_TWO; break;
        case OEWiiButtonPlus:  s_wii_status[player].buttons |= WiimoteEmu::Wiimote::BUTTON_PLUS; break;
        case OEWiiButtonMinus: s_wii_status[player].buttons |= WiimoteEmu::Wiimote::BUTTON_MINUS; break;
        case OEWiiButtonHome:  s_wii_status[player].buttons |= WiimoteEmu::Wiimote::BUTTON_HOME; break;
        // Nunchuk Buttons
        case OEWiiNunchukButtonC: s_wii_status[player].nunchukButtons |= WiimoteEmu::Nunchuk::BUTTON_C; break;
        case OEWiiNunchukButtonZ: s_wii_status[player].nunchukButtons |= WiimoteEmu::Nunchuk::BUTTON_Z; break;
        default: break;
    }
}

- (oneway void)didReleaseWiiButton:(OEWiiButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    std::lock_guard<std::mutex> lock(s_wii_mutex);

    switch (button) {
        // Wiimote D-Pad
        case OEWiiButtonUp:    s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::PAD_UP; break;
        case OEWiiButtonDown:  s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::PAD_DOWN; break;
        case OEWiiButtonLeft:  s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::PAD_LEFT; break;
        case OEWiiButtonRight: s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::PAD_RIGHT; break;
        // Wiimote Buttons
        case OEWiiButtonA:     s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::BUTTON_A; break;
        case OEWiiButtonB:     s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::BUTTON_B; break;
        case OEWiiButton1:     s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::BUTTON_ONE; break;
        case OEWiiButton2:     s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::BUTTON_TWO; break;
        case OEWiiButtonPlus:  s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::BUTTON_PLUS; break;
        case OEWiiButtonMinus: s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::BUTTON_MINUS; break;
        case OEWiiButtonHome:  s_wii_status[player].buttons &= ~WiimoteEmu::Wiimote::BUTTON_HOME; break;
        // Nunchuk Buttons
        case OEWiiNunchukButtonC: s_wii_status[player].nunchukButtons &= ~WiimoteEmu::Nunchuk::BUTTON_C; break;
        case OEWiiNunchukButtonZ: s_wii_status[player].nunchukButtons &= ~WiimoteEmu::Nunchuk::BUTTON_Z; break;
        default: break;
    }
}

- (oneway void)didMoveWiiJoystickDirection:(OEWiiButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    std::lock_guard<std::mutex> lock(s_wii_mutex);

    switch (button) {
        // Nunchuk Analog Stick
        case OEWiiNunchukAnalogUp:    s_wii_status[player].nunchukY =  value; break;
        case OEWiiNunchukAnalogDown:  s_wii_status[player].nunchukY = -value; break;
        case OEWiiNunchukAnalogLeft:  s_wii_status[player].nunchukX = -value; break;
        case OEWiiNunchukAnalogRight: s_wii_status[player].nunchukX =  value; break;
        // IR Pointer
        case OEWiiIRUp:    s_wii_status[player].irY =  value; break;
        case OEWiiIRDown:  s_wii_status[player].irY = -value; break;
        case OEWiiIRLeft:  s_wii_status[player].irX = -value; break;
        case OEWiiIRRight: s_wii_status[player].irX =  value; break;
        default: break;
    }
}

@end
