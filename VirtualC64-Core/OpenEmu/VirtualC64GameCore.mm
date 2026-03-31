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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfloat-conversion"
#import "VirtualC64GameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEGameCore.h>
#pragma clang diagnostic pop

#import "../../OpenEmu/SystemPlugins/Commodore 64/OEC64SystemResponderClient.h"

#include "VirtualC64.h"
#include "C64Key.h"

using namespace vc64;

// Video constants from VirtualC64
// Full emulator texture dimensions
static const int VC64_TEX_WIDTH  = 520;
static const int VC64_TEX_HEIGHT = 312;

// Visible area within the full texture (crop coordinates)
// PAL: Columns 104-487 (384 px), Lines 16-287 (272 lines)
// NTSC: Columns 104-487 (384 px), Lines 16-249 (234 lines)
static const int VC64_VISIBLE_X      = 104;
static const int VC64_VISIBLE_Y_PAL  = 16;
static const int VC64_VISIBLE_Y_NTSC = 16;
static const int VC64_VISIBLE_WIDTH  = 384;
static const int VC64_VISIBLE_HEIGHT_PAL  = 272;
static const int VC64_VISIBLE_HEIGHT_NTSC = 234;

// Audio
static const double VC64_SAMPLE_RATE = 48000.0;
static const int VC64_SAMPLES_PER_FRAME_PAL  = 960;  // 48000 / 50
static const int VC64_SAMPLES_PER_FRAME_NTSC = 800;  // ~48000 / 60

// USB HID usage code to C64Key mapping
// OEHIDEvent.keycode returns USB HID usage codes (kHIDUsage_Keyboard*),
// NOT macOS virtual keycodes (kVK_*).
static const struct { unsigned short hidUsage; C64Key c64Key; } kKeyMap[] = {
    // Letters (USB HID: A=0x04 through Z=0x1D)
    { 0x04, C64Key::A },       // kHIDUsage_KeyboardA
    { 0x05, C64Key::B },       // kHIDUsage_KeyboardB
    { 0x06, C64Key::C },       // kHIDUsage_KeyboardC
    { 0x07, C64Key::D },       // kHIDUsage_KeyboardD
    { 0x08, C64Key::E },       // kHIDUsage_KeyboardE
    { 0x09, C64Key::F },       // kHIDUsage_KeyboardF
    { 0x0A, C64Key::G },       // kHIDUsage_KeyboardG
    { 0x0B, C64Key::H },       // kHIDUsage_KeyboardH
    { 0x0C, C64Key::I },       // kHIDUsage_KeyboardI
    { 0x0D, C64Key::J },       // kHIDUsage_KeyboardJ
    { 0x0E, C64Key::K },       // kHIDUsage_KeyboardK
    { 0x0F, C64Key::L },       // kHIDUsage_KeyboardL
    { 0x10, C64Key::M },       // kHIDUsage_KeyboardM
    { 0x11, C64Key::N },       // kHIDUsage_KeyboardN
    { 0x12, C64Key::O },       // kHIDUsage_KeyboardO
    { 0x13, C64Key::P },       // kHIDUsage_KeyboardP
    { 0x14, C64Key::Q },       // kHIDUsage_KeyboardQ
    { 0x15, C64Key::R },       // kHIDUsage_KeyboardR
    { 0x16, C64Key::S },       // kHIDUsage_KeyboardS
    { 0x17, C64Key::T },       // kHIDUsage_KeyboardT
    { 0x18, C64Key::U },       // kHIDUsage_KeyboardU
    { 0x19, C64Key::V },       // kHIDUsage_KeyboardV
    { 0x1A, C64Key::W },       // kHIDUsage_KeyboardW
    { 0x1B, C64Key::X },       // kHIDUsage_KeyboardX
    { 0x1C, C64Key::Y },       // kHIDUsage_KeyboardY
    { 0x1D, C64Key::Z },       // kHIDUsage_KeyboardZ

    // Digits (USB HID: 1=0x1E through 9=0x26, 0=0x27)
    { 0x1E, C64Key::digit1 },  // kHIDUsage_Keyboard1
    { 0x1F, C64Key::digit2 },  // kHIDUsage_Keyboard2
    { 0x20, C64Key::digit3 },  // kHIDUsage_Keyboard3
    { 0x21, C64Key::digit4 },  // kHIDUsage_Keyboard4
    { 0x22, C64Key::digit5 },  // kHIDUsage_Keyboard5
    { 0x23, C64Key::digit6 },  // kHIDUsage_Keyboard6
    { 0x24, C64Key::digit7 },  // kHIDUsage_Keyboard7
    { 0x25, C64Key::digit8 },  // kHIDUsage_Keyboard8
    { 0x26, C64Key::digit9 },  // kHIDUsage_Keyboard9
    { 0x27, C64Key::digit0 },  // kHIDUsage_Keyboard0

    // Special keys
    { 0x28, C64Key::ret },         // kHIDUsage_KeyboardReturnOrEnter
    { 0x2C, C64Key::space },       // kHIDUsage_KeyboardSpacebar
    { 0x2A, C64Key::del },         // kHIDUsage_KeyboardDeleteOrBackspace
    { 0x29, C64Key::runStop },     // kHIDUsage_KeyboardEscape -> Run/Stop
    { 0x2B, C64Key::control },     // kHIDUsage_KeyboardTab -> Control
    { 0xE1, C64Key::leftShift },   // kHIDUsage_KeyboardLeftShift
    { 0xE5, C64Key::rightShift },  // kHIDUsage_KeyboardRightShift
    { 0xE2, C64Key::commodore },   // kHIDUsage_KeyboardLeftAlt -> Commodore
    { 0xE6, C64Key::commodore },   // kHIDUsage_KeyboardRightAlt -> Commodore

    // Function keys
    { 0x3A, C64Key::F1F2 },       // kHIDUsage_KeyboardF1
    { 0x3B, C64Key::F1F2 },       // kHIDUsage_KeyboardF2 (same C64 key, shifted)
    { 0x3C, C64Key::F3F4 },       // kHIDUsage_KeyboardF3
    { 0x3D, C64Key::F3F4 },       // kHIDUsage_KeyboardF4
    { 0x3E, C64Key::F5F6 },       // kHIDUsage_KeyboardF5
    { 0x3F, C64Key::F5F6 },       // kHIDUsage_KeyboardF6
    { 0x40, C64Key::F7F8 },       // kHIDUsage_KeyboardF7
    { 0x41, C64Key::F7F8 },       // kHIDUsage_KeyboardF8

    // Cursor keys
    { 0x52, C64Key::curUpDown },    // kHIDUsage_KeyboardUpArrow
    { 0x51, C64Key::curUpDown },    // kHIDUsage_KeyboardDownArrow
    { 0x50, C64Key::curLeftRight }, // kHIDUsage_KeyboardLeftArrow
    { 0x4F, C64Key::curLeftRight }, // kHIDUsage_KeyboardRightArrow

    // Symbols
    { 0x2D, C64Key::minus },      // kHIDUsage_KeyboardHyphen
    { 0x2E, C64Key::equal },      // kHIDUsage_KeyboardEqualSign -> =
    { 0x2F, C64Key::leftArrow },  // kHIDUsage_KeyboardOpenBracket -> left arrow
    { 0x30, C64Key::plus },       // kHIDUsage_KeyboardCloseBracket -> +
    { 0x33, C64Key::semicolon },  // kHIDUsage_KeyboardSemicolon
    { 0x34, C64Key::colon },      // kHIDUsage_KeyboardQuote -> :
    { 0x36, C64Key::comma },      // kHIDUsage_KeyboardComma
    { 0x37, C64Key::period },     // kHIDUsage_KeyboardPeriod
    { 0x38, C64Key::slash },      // kHIDUsage_KeyboardSlash
    { 0x35, C64Key::leftArrow },  // kHIDUsage_KeyboardGraveAccentAndTilde -> left arrow
    { 0x31, C64Key::at },         // kHIDUsage_KeyboardBackslash -> @

    // Home
    { 0x4A, C64Key::home },       // kHIDUsage_KeyboardHome
    { 0x4D, C64Key::home },       // kHIDUsage_KeyboardEnd -> Home

    // Restore (NMI)
    { 0x68, C64Key::restore },    // kHIDUsage_KeyboardF13 -> Restore
    { 0x6A, C64Key::restore },    // kHIDUsage_KeyboardF15 -> Restore
};

static const int kKeyMapSize = sizeof(kKeyMap) / sizeof(kKeyMap[0]);

// Emulator message callback (called from emulator thread)
static void emuCallback(const void *listener, Message msg)
{
    // We don't need to process messages for the OpenEmu bridge
    // The standalone app uses this for UI updates
}

#pragma mark -

@interface VirtualC64GameCore () <OEC64SystemResponderClient>
{
    VirtualC64 _emu;

    // Video
    uint32_t *_videoBuffer;
    BOOL _isPAL;

    // Audio conversion buffer (float -> int16)
    float *_audioFloatBuffer;
    int16_t *_audioIntBuffer;
    int _samplesPerFrame;

    // Input
    BOOL _joystickSwapped;

    // Autoload
    NSString *_pendingAutoType;
    int _autoTypeDelay;

    // Display modes
    BOOL _showBorders;
    BOOL _warpMode;
    BOOL _sid8580;
    NSMutableArray<NSMutableDictionary<NSString *, id> *> *_availableDisplayModes;

    // Frame counter for diagnostics
    int _frameCount;
}
@end

@implementation VirtualC64GameCore

#pragma mark - Lifecycle

- (id)init
{
    NSLog(@"[VirtualC64] init: entering");
    if (self = [super init]) {
        _videoBuffer = (uint32_t *)calloc(VC64_VISIBLE_WIDTH * VC64_VISIBLE_HEIGHT_PAL, sizeof(uint32_t));
        _isPAL = YES;
        _showBorders = NO;
        _joystickSwapped = NO;
        _warpMode = NO;
        _sid8580 = NO;
        _pendingAutoType = nil;
        _autoTypeDelay = 0;
        _samplesPerFrame = VC64_SAMPLES_PER_FRAME_PAL;

        // Allocate audio buffers (stereo interleaved)
        _audioFloatBuffer = (float *)calloc(_samplesPerFrame * 2, sizeof(float));
        _audioIntBuffer = (int16_t *)calloc(_samplesPerFrame * 2, sizeof(int16_t));
        NSLog(@"[VirtualC64] init: VirtualC64 object constructed successfully");
    }
    return self;
}

- (void)dealloc
{
    // Ensure emulator thread is stopped (may already be halted by stopEmulation)
    try {
        _emu.halt();
    } catch (...) {
        // Swallow exceptions during cleanup
    }

    free(_videoBuffer);
    free(_audioFloatBuffer);
    free(_audioIntBuffer);
    // _emu destructor runs automatically (C++ member), calling halt() + delete emu
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    NSLog(@"[VirtualC64] loadFileAtPath: %@", path);

    // =========================================================================
    // Phase 1: Configure the emulator BEFORE launching the thread
    // (Matches the reference Headless.cpp initialization order)
    // =========================================================================

    // Install open-source ROMs (MEGA65 OpenROMs) so we don't require BIOS files
    // This is just a memcpy into emulator memory — safe before launch()
    NSLog(@"[VirtualC64] loadFileAtPath: installing OpenROMs (pre-launch)...");
    try {
        _emu.c64.installOpenRoms();
        NSLog(@"[VirtualC64] loadFileAtPath: OpenROMs installed OK");
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Warning: Could not install OpenROMs: %s", e.what());
    } catch (...) {
        NSLog(@"[VirtualC64] Warning: Could not install OpenROMs (unknown error)");
    }

    // Verify ROMs are ready before we launch
    NSLog(@"[VirtualC64] loadFileAtPath: checking isReady...");
    try {
        _emu.isReady();
        NSLog(@"[VirtualC64] loadFileAtPath: isReady returned OK - ROMs are present");
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] loadFileAtPath: isReady FAILED: %s", e.what());
    } catch (...) {
        NSLog(@"[VirtualC64] loadFileAtPath: isReady FAILED (unknown error)");
    }

    // Configure as PAL by default (queues commands, processed after launch)
    NSLog(@"[VirtualC64] loadFileAtPath: setting PAL config...");
    try {
        _emu.set(ConfigScheme::PAL);
    } catch (...) {
        NSLog(@"[VirtualC64] Warning: Could not set PAL config scheme");
    }

    // Set audio sample rate
    try {
        _emu.set(Opt::HOST_SAMPLE_RATE, (i64)VC64_SAMPLE_RATE);
    } catch (...) {
        NSLog(@"[VirtualC64] Warning: Could not set sample rate");
    }

    // Set host refresh rate
    try {
        _emu.set(Opt::HOST_REFRESH_RATE, _isPAL ? 50 : 60);
    } catch (...) {
        NSLog(@"[VirtualC64] Warning: Could not set refresh rate");
    }
    NSLog(@"[VirtualC64] loadFileAtPath: configuration complete");

    // Determine file type and load media (before launch — uses suspend/resume internally)
    NSString *ext = path.pathExtension.lowercaseString;
    std::filesystem::path fsPath(path.fileSystemRepresentation);
    NSLog(@"[VirtualC64] loadFileAtPath: loading file with extension '%@'", ext);

    try {
        if ([ext isEqualToString:@"crt"]) {
            // Cartridge — no autoload needed, cartridges auto-start
            _emu.expansionPort.attachCartridge(fsPath, false);
        } else if ([ext isEqualToString:@"d64"] ||
                   [ext isEqualToString:@"g64"] ||
                   [ext isEqualToString:@"d71"] ||
                   [ext isEqualToString:@"d81"]) {
            // Disk image — insert into drive 8 and autoload
            _emu.drive8.insert(fsPath, false);
            _pendingAutoType = @"LOAD\"*\",8,1\nRUN\n";
        } else if ([ext isEqualToString:@"tap"]) {
            // Tape image — insert and autoload
            _emu.datasette.insertTape(fsPath);
            _pendingAutoType = @"LOAD\n";
        } else if ([ext isEqualToString:@"t64"] ||
                   [ext isEqualToString:@"prg"] ||
                   [ext isEqualToString:@"p00"]) {
            // Program file — flash into memory and run
            _emu.c64.flash(fsPath);
            _pendingAutoType = @"RUN\n";
        } else {
            // Try generic flash for unknown types
            _emu.c64.flash(fsPath);
            _pendingAutoType = @"RUN\n";
        }
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Error loading file: %s", e.what());
        if (error) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load C64 file: %s", e.what()]
            }];
        }
        return NO;
    } catch (...) {
        NSLog(@"[VirtualC64] Unknown error loading file");
        if (error) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to load C64 file"
            }];
        }
        return NO;
    }

    // =========================================================================
    // Phase 2: Launch the emulator thread
    // ROMs are installed and config is set — thread will process queued commands
    // =========================================================================
    NSLog(@"[VirtualC64] loadFileAtPath: launching emulator thread...");
    try {
        _emu.launch((__bridge const void *)self, emuCallback);
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] FATAL: launch() failed: %s", e.what());
        if (error) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"VirtualC64 launch failed: %s", e.what()]
            }];
        }
        return NO;
    } catch (...) {
        NSLog(@"[VirtualC64] FATAL: launch() failed with unknown error");
        if (error) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"VirtualC64 launch failed"
            }];
        }
        return NO;
    }
    NSLog(@"[VirtualC64] loadFileAtPath: emulator thread launched OK");

    NSLog(@"[VirtualC64] loadFileAtPath: file loaded successfully");
    return YES;
}

- (void)setupEmulation
{
    NSLog(@"[VirtualC64] setupEmulation");
    _samplesPerFrame = _isPAL ? VC64_SAMPLES_PER_FRAME_PAL : VC64_SAMPLES_PER_FRAME_NTSC;
}

- (void)startEmulation
{
    NSLog(@"[VirtualC64] startEmulation: entering");
    [super startEmulation];

    // Power on and run the emulator
    NSLog(@"[VirtualC64] startEmulation: calling powerOn...");
    try {
        _emu.powerOn();
        NSLog(@"[VirtualC64] startEmulation: powerOn OK (powered=%d, running=%d)",
              _emu.isPoweredOn(), _emu.isRunning());
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Error in powerOn: %s", e.what());
    } catch (...) {
        NSLog(@"[VirtualC64] Unknown error in powerOn");
    }

    NSLog(@"[VirtualC64] startEmulation: calling run...");
    try {
        _emu.run();
        NSLog(@"[VirtualC64] startEmulation: run OK (powered=%d, running=%d)",
              _emu.isPoweredOn(), _emu.isRunning());
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Error in run: %s", e.what());
    } catch (...) {
        NSLog(@"[VirtualC64] Unknown error in run");
    }

    NSLog(@"[VirtualC64] startEmulation: calling wakeUp...");
    try {
        _emu.wakeUp();
        NSLog(@"[VirtualC64] startEmulation: wakeUp OK");
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Error in wakeUp: %s", e.what());
    } catch (...) {
        NSLog(@"[VirtualC64] Unknown error in wakeUp");
    }

    // Set up delay for auto-typing (wait for C64 to boot to BASIC prompt)
    if (_pendingAutoType) {
        _autoTypeDelay = 150;
    }
    NSLog(@"[VirtualC64] startEmulation: complete (powered=%d, running=%d)",
          _emu.isPoweredOn(), _emu.isRunning());
}

- (void)stopEmulation
{
    NSLog(@"[VirtualC64] stopEmulation: entering (running=%d, powered=%d)",
          _emu.isRunning(), _emu.isPoweredOn());

    // Halt the emulator thread synchronously — queue HALT, wake the thread
    // so it processes the command promptly, then join the thread.
    try {
        _emu.wakeUp();  // Wake thread so it processes commands quickly
        _emu.halt();    // Queues HALT + joins thread
    } catch (...) {
        NSLog(@"[VirtualC64] Error halting emulation");
    }

    NSLog(@"[VirtualC64] stopEmulation: emulator thread halted");
    [super stopEmulation];
}

- (void)resetEmulation
{
    try {
        _emu.hardReset();
    } catch (...) {
        NSLog(@"[VirtualC64] Error resetting emulation");
    }
}

#pragma mark - Frame Execution

- (void)executeFrame
{
    @try {
        _frameCount++;

        // Recovery: if the emulator isn't running after initial startup, try to kick-start it
        if (_frameCount == 50 && !_emu.isRunning()) {
            NSLog(@"[VirtualC64] executeFrame: emulator not running at frame 50! "
                  @"Attempting recovery (powered=%d)", _emu.isPoweredOn());
            try {
                if (!_emu.isPoweredOn()) {
                    _emu.powerOn();
                    NSLog(@"[VirtualC64] Recovery: powerOn queued");
                }
                _emu.run();
                _emu.wakeUp();
                NSLog(@"[VirtualC64] Recovery: run + wakeUp sent");
            } catch (std::exception &e) {
                NSLog(@"[VirtualC64] Recovery failed: %s", e.what());
            } catch (...) {
                NSLog(@"[VirtualC64] Recovery failed (unknown)");
            }
        }

        // Handle deferred auto-type after C64 has booted
        if (_pendingAutoType && _autoTypeDelay > 0) {
            _autoTypeDelay--;
            if (_autoTypeDelay == 0) {
                try {
                    _emu.keyboard.autoType(std::string(_pendingAutoType.UTF8String));
                } catch (...) {
                    NSLog(@"[VirtualC64] Warning: Could not auto-type load command");
                }
                _pendingAutoType = nil;
            }
        }

        // Signal the emulator thread to compute the next frame
        try {
            _emu.wakeUp();
        } catch (...) {
            // Emulator thread may have encountered a fatal error
        }

        // Copy video data from the emulator's texture (with lock for thread safety)
        // We crop the visible area from the full 520x312 texture so that
        // bufferSize and screenRect can both use origin (0,0), which is
        // required by the Metal FilterChain blit copy pipeline.
        try {
            _emu.videoPort.lockTexture();
            const u32 *texture = _emu.videoPort.getTexture();

            if (_frameCount <= 10 || _frameCount % 300 == 0) {
                u32 px0 = texture ? texture[0] : 0;
                u32 pxCenter = texture ? texture[150 * VC64_TEX_WIDTH + 260] : 0;
                NSLog(@"[VirtualC64] executeFrame #%d: running=%d powered=%d "
                      @"px[0]=0x%08X pxCenter=0x%08X texPtr=%p",
                      _frameCount, _emu.isRunning(), _emu.isPoweredOn(),
                      px0, pxCenter, texture);
            }

            if (texture) {
                int visibleY = _isPAL ? VC64_VISIBLE_Y_PAL : VC64_VISIBLE_Y_NTSC;
                int visibleH = _isPAL ? VC64_VISIBLE_HEIGHT_PAL : VC64_VISIBLE_HEIGHT_NTSC;

                // Copy row by row from the visible region of the full texture
                for (int row = 0; row < visibleH; row++) {
                    const u32 *srcRow = texture + (visibleY + row) * VC64_TEX_WIDTH + VC64_VISIBLE_X;
                    u32 *dstRow = _videoBuffer + row * VC64_VISIBLE_WIDTH;
                    memcpy(dstRow, srcRow, VC64_VISIBLE_WIDTH * sizeof(u32));
                }
            }
            _emu.videoPort.unlockTexture();
        } catch (...) {
            try { _emu.videoPort.unlockTexture(); } catch (...) {}
        }

        // Copy audio data
        try {
            isize samplesRead = _emu.audioPort.copyInterleaved(_audioFloatBuffer, _samplesPerFrame);

            if (samplesRead > 0) {
                // Convert float [-1.0, 1.0] to int16
                for (isize i = 0; i < samplesRead * 2; i++) {
                    float sample = _audioFloatBuffer[i];
                    if (sample > 1.0f) sample = 1.0f;
                    if (sample < -1.0f) sample = -1.0f;
                    _audioIntBuffer[i] = (int16_t)(sample * 32767.0f);
                }

                [[self audioBufferAtIndex:0] write:_audioIntBuffer
                                         maxLength:samplesRead * 2 * sizeof(int16_t)];
            }
        } catch (...) {
            // Audio may not be available
        }
    } @catch (NSException *exception) {
        NSLog(@"[VirtualC64] executeFrame exception: %@", exception);
    }
}

#pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    return _videoBuffer;
}

- (OEIntSize)bufferSize
{
    // We pre-crop the visible area in executeFrame, so our buffer is the
    // visible area only (not the full 520x312 emulator texture).
    if (_isPAL) {
        return OEIntSizeMake(VC64_VISIBLE_WIDTH, VC64_VISIBLE_HEIGHT_PAL);
    } else {
        return OEIntSizeMake(VC64_VISIBLE_WIDTH, VC64_VISIBLE_HEIGHT_NTSC);
    }
}

- (OEIntRect)screenRect
{
    // Our video buffer already contains only the cropped visible area,
    // so screenRect starts at origin (0,0). This is required because
    // the Metal FilterChain creates a renderTexture sized to screenRect
    // dimensions and then tries to blit from sourceRect origin — a
    // non-zero origin would exceed the texture bounds.
    if (_isPAL) {
        return OEIntRectMake(0, 0, VC64_VISIBLE_WIDTH, VC64_VISIBLE_HEIGHT_PAL);
    } else {
        return OEIntRectMake(0, 0, VC64_VISIBLE_WIDTH, VC64_VISIBLE_HEIGHT_NTSC);
    }
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(4, 3);
}

- (NSTimeInterval)frameInterval
{
    return _isPAL ? 50.0 : 59.826;
}

- (uint32_t)pixelFormat
{
    // VirtualC64 stores pixels as u32 with ABGR layout: 0xAABBGGRR
    // On little-endian, memory bytes are: R, G, B, A
    // This matches OEPixelFormat_RGBA + OEPixelType_UNSIGNED_INT_8_8_8_8_REV
    // which MTLGameRenderer maps to .abgr8Unorm
    return OEPixelFormat_RGBA;
}

- (uint32_t)pixelType
{
    // VirtualC64 pixel u32 layout: R in bits 0-7, G in bits 8-15, B in bits 16-23, A in bits 24-31
    // This is the REV (reversed) byte order for GL_UNSIGNED_INT_8_8_8_8
    return OEPixelType_UNSIGNED_INT_8_8_8_8_REV;
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return VC64_SAMPLE_RATE;
}

- (NSUInteger)channelCount
{
    return 2;  // Stereo
}

- (NSUInteger)audioBitDepth
{
    return 16;
}

#pragma mark - Input: Joystick

- (oneway void)didPushC64Button:(OEC64Button)button forPlayer:(NSUInteger)player
{
    // Determine which port to use (respecting swap)
    BOOL usePort1 = (player == 1);
    if (_joystickSwapped) usePort1 = !usePort1;

    GamePadAction action;
    switch (button) {
        case OEC64JoystickUp:    action = GamePadAction::PULL_UP; break;
        case OEC64JoystickDown:  action = GamePadAction::PULL_DOWN; break;
        case OEC64JoystickLeft:  action = GamePadAction::PULL_LEFT; break;
        case OEC64JoystickRight: action = GamePadAction::PULL_RIGHT; break;
        case OEC64ButtonFire:    action = GamePadAction::PRESS_FIRE; break;
        case OEC64ButtonJump:    action = GamePadAction::PRESS_FIRE; break; // Map jump to fire
        default: return;
    }

    if (usePort1) {
        _emu.controlPort1.joystick.trigger(action);
    } else {
        _emu.controlPort2.joystick.trigger(action);
    }
}

- (oneway void)didReleaseC64Button:(OEC64Button)button forPlayer:(NSUInteger)player
{
    BOOL usePort1 = (player == 1);
    if (_joystickSwapped) usePort1 = !usePort1;

    GamePadAction action;
    switch (button) {
        case OEC64JoystickUp:    action = GamePadAction::RELEASE_Y; break;
        case OEC64JoystickDown:  action = GamePadAction::RELEASE_Y; break;
        case OEC64JoystickLeft:  action = GamePadAction::RELEASE_X; break;
        case OEC64JoystickRight: action = GamePadAction::RELEASE_X; break;
        case OEC64ButtonFire:    action = GamePadAction::RELEASE_FIRE; break;
        case OEC64ButtonJump:    action = GamePadAction::RELEASE_FIRE; break;
        default: return;
    }

    if (usePort1) {
        _emu.controlPort1.joystick.trigger(action);
    } else {
        _emu.controlPort2.joystick.trigger(action);
    }
}

- (oneway void)swapJoysticks
{
    _joystickSwapped = !_joystickSwapped;
}

#pragma mark - Input: Keyboard

- (oneway void)keyDown:(NSUInteger)keyCode
{
    for (int i = 0; i < kKeyMapSize; i++) {
        if (kKeyMap[i].hidUsage == keyCode) {
            _emu.keyboard.press(kKeyMap[i].c64Key);
            return;
        }
    }
}

- (oneway void)keyUp:(NSUInteger)keyCode
{
    for (int i = 0; i < kKeyMapSize; i++) {
        if (kKeyMap[i].hidUsage == keyCode) {
            _emu.keyboard.release(kKeyMap[i].c64Key);
            return;
        }
    }
}

#pragma mark - Input: Mouse

- (oneway void)mouseMovedAtPoint:(OEIntPoint)point
{
    _emu.controlPort1.mouse.setXY((double)point.x, (double)point.y);
}

- (oneway void)leftMouseDownAtPoint:(OEIntPoint)point
{
    _emu.controlPort1.mouse.setXY((double)point.x, (double)point.y);
    _emu.controlPort1.mouse.trigger(GamePadAction::PRESS_LEFT);
}

- (oneway void)leftMouseUp
{
    _emu.controlPort1.mouse.trigger(GamePadAction::RELEASE_LEFT);
}

- (oneway void)rightMouseDownAtPoint:(OEIntPoint)point
{
    _emu.controlPort1.mouse.setXY((double)point.x, (double)point.y);
    _emu.controlPort1.mouse.trigger(GamePadAction::PRESS_RIGHT);
}

- (oneway void)rightMouseUp
{
    _emu.controlPort1.mouse.trigger(GamePadAction::RELEASE_RIGHT);
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    try {
        std::filesystem::path path(fileName.fileSystemRepresentation);
        _emu.c64.saveSnapshot(path, Compressor::GZIP);
        block(YES, nil);
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Error saving state: %s", e.what());
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreCouldNotSaveStateError
                                         userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to save state: %s", e.what()]
        }];
        block(NO, error);
    } catch (...) {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreCouldNotSaveStateError
                                         userInfo:@{
            NSLocalizedDescriptionKey: @"Failed to save state"
        }];
        block(NO, error);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    try {
        std::filesystem::path path(fileName.fileSystemRepresentation);
        _emu.c64.loadSnapshot(path);
        block(YES, nil);
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Error loading state: %s", e.what());
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreCouldNotLoadStateError
                                         userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load state: %s", e.what()]
        }];
        block(NO, error);
    } catch (...) {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreCouldNotLoadStateError
                                         userInfo:@{
            NSLocalizedDescriptionKey: @"Failed to load state"
        }];
        block(NO, error);
    }
}

- (NSData *)serializeStateWithError:(NSError **)outError
{
    try {
        auto snapshot = _emu.c64.takeSnapshot(Compressor::GZIP);
        if (!snapshot) {
            if (outError) {
                *outError = [NSError errorWithDomain:OEGameCoreErrorDomain
                                                code:OEGameCoreCouldNotSaveStateError
                                            userInfo:@{
                    NSLocalizedDescriptionKey: @"Failed to create snapshot"
                }];
            }
            return nil;
        }

        // Serialize snapshot to a temporary file and read it back as NSData
        // VirtualC64 snapshots can be saved via the C64API
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"vc64_snap_%@.v6s", [[NSUUID UUID] UUIDString]]];
        std::filesystem::path path(tempPath.fileSystemRepresentation);
        _emu.c64.saveSnapshot(path, Compressor::GZIP);

        NSData *data = [NSData dataWithContentsOfFile:tempPath];
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        return data;
    } catch (std::exception &e) {
        if (outError) {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain
                                            code:OEGameCoreCouldNotSaveStateError
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to serialize state: %s", e.what()]
            }];
        }
        return nil;
    } catch (...) {
        if (outError) {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain
                                            code:OEGameCoreCouldNotSaveStateError
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to serialize state"
            }];
        }
        return nil;
    }
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    try {
        // Write NSData to temporary file, then load snapshot
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"vc64_snap_%@.v6s", [[NSUUID UUID] UUIDString]]];
        [state writeToFile:tempPath atomically:YES];

        std::filesystem::path path(tempPath.fileSystemRepresentation);
        _emu.c64.loadSnapshot(path);

        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        return YES;
    } catch (std::exception &e) {
        if (outError) {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain
                                            code:OEGameCoreCouldNotLoadStateError
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to deserialize state: %s", e.what()]
            }];
        }
        return NO;
    } catch (...) {
        if (outError) {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain
                                            code:OEGameCoreCouldNotLoadStateError
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to deserialize state"
            }];
        }
        return NO;
    }
}

#pragma mark - File Insertion (Disk Swap)

- (void)insertFileAtURL:(NSURL *)file completionHandler:(void (^)(BOOL, NSError *))block
{
    NSString *ext = file.pathExtension.lowercaseString;
    std::filesystem::path path(file.fileSystemRepresentation);

    try {
        if ([ext isEqualToString:@"d64"] ||
            [ext isEqualToString:@"g64"] ||
            [ext isEqualToString:@"d71"] ||
            [ext isEqualToString:@"d81"]) {
            _emu.drive8.ejectDisk();
            _emu.drive8.insert(path, false);
        } else if ([ext isEqualToString:@"crt"]) {
            _emu.expansionPort.detachCartridge();
            _emu.expansionPort.attachCartridge(path, true);
        } else if ([ext isEqualToString:@"tap"]) {
            _emu.datasette.ejectTape();
            _emu.datasette.insertTape(path);
        } else if ([ext isEqualToString:@"prg"] ||
                   [ext isEqualToString:@"p00"] ||
                   [ext isEqualToString:@"t64"]) {
            _emu.c64.flash(path);
        } else {
            if (block) {
                NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                                     code:OEGameCoreCouldNotLoadROMError
                                                 userInfo:@{
                    NSLocalizedDescriptionKey: @"Unsupported file type"
                }];
                block(NO, error);
            }
            return;
        }

        if (block) block(YES, nil);
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Error inserting file: %s", e.what());
        if (block) {
            NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                                 code:OEGameCoreCouldNotLoadROMError
                                             userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to insert file: %s", e.what()]
            }];
            block(NO, error);
        }
    } catch (...) {
        if (block) {
            NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                                 code:OEGameCoreCouldNotLoadROMError
                                             userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to insert file"
            }];
            block(NO, error);
        }
    }
}

#pragma mark - Display Modes

- (NSArray<NSDictionary<NSString *, id> *> *)displayModes
{
    if (!_availableDisplayModes) {
        _availableDisplayModes = [NSMutableArray array];

        // Model selection
        [_availableDisplayModes addObject:[@{
            OEGameCoreDisplayModeGroupNameKey: @"Model",
            OEGameCoreDisplayModeGroupItemsKey: @[
                @{OEGameCoreDisplayModeNameKey: @"PAL",
                  OEGameCoreDisplayModeStateKey: @(_isPAL)},
                @{OEGameCoreDisplayModeNameKey: @"NTSC",
                  OEGameCoreDisplayModeStateKey: @(!_isPAL)},
            ]
        } mutableCopy]];

        // SID model selection
        [_availableDisplayModes addObject:[@{
            OEGameCoreDisplayModeGroupNameKey: @"SID Model",
            OEGameCoreDisplayModeGroupItemsKey: @[
                @{OEGameCoreDisplayModeNameKey: @"MOS 6581",
                  OEGameCoreDisplayModeStateKey: @(!_sid8580)},
                @{OEGameCoreDisplayModeNameKey: @"MOS 8580",
                  OEGameCoreDisplayModeStateKey: @(_sid8580)},
            ]
        } mutableCopy]];

        // Separator
        [_availableDisplayModes addObject:[@{
            OEGameCoreDisplayModeSeparatorItemKey: @"",
        } mutableCopy]];

        // Border options
        [_availableDisplayModes addObject:[@{
            OEGameCoreDisplayModeNameKey: @"Show Borders",
            OEGameCoreDisplayModeStateKey: @(_showBorders),
        } mutableCopy]];

        // Warp mode
        [_availableDisplayModes addObject:[@{
            OEGameCoreDisplayModeNameKey: @"Warp Mode",
            OEGameCoreDisplayModeStateKey: @(_warpMode),
        } mutableCopy]];
    }

    return _availableDisplayModes;
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
    if ([displayMode isEqualToString:@"PAL"] && !_isPAL) {
        _isPAL = YES;
        _samplesPerFrame = VC64_SAMPLES_PER_FRAME_PAL;
        try {
            _emu.set(ConfigScheme::PAL);
            _emu.set(Opt::HOST_REFRESH_RATE, 50);
        } catch (...) {}
    } else if ([displayMode isEqualToString:@"NTSC"] && _isPAL) {
        _isPAL = NO;
        _samplesPerFrame = VC64_SAMPLES_PER_FRAME_NTSC;
        try {
            _emu.set(ConfigScheme::NTSC);
            _emu.set(Opt::HOST_REFRESH_RATE, 60);
        } catch (...) {}
    } else if ([displayMode isEqualToString:@"MOS 6581"] && _sid8580) {
        _sid8580 = NO;
        try {
            _emu.set(Opt::SID_REV, (i64)0); // SIDRevision::MOS_6581
        } catch (...) {}
    } else if ([displayMode isEqualToString:@"MOS 8580"] && !_sid8580) {
        _sid8580 = YES;
        try {
            _emu.set(Opt::SID_REV, (i64)1); // SIDRevision::MOS_8580
        } catch (...) {}
    } else if ([displayMode isEqualToString:@"Show Borders"]) {
        _showBorders = !_showBorders;
    } else if ([displayMode isEqualToString:@"Warp Mode"]) {
        _warpMode = !_warpMode;
        try {
            if (_warpMode) {
                _emu.warpOn();
            } else {
                _emu.warpOff();
            }
        } catch (...) {}
    }

    // Reset display modes cache to reflect state changes
    _availableDisplayModes = nil;
}

@end
