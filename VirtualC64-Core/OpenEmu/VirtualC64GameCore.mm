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
static const int VC64_TEX_WIDTH  = 520;
static const int VC64_TEX_HEIGHT = 312;

// Audio
static const double VC64_SAMPLE_RATE = 48000.0;
static const int VC64_SAMPLES_PER_FRAME_PAL  = 960;  // 48000 / 50
static const int VC64_SAMPLES_PER_FRAME_NTSC = 800;  // ~48000 / 60

// macOS virtual keycode to C64Key mapping
// Uses Carbon kVK_* keycodes (same as NSEvent keyCode)
static const struct { unsigned short macKey; C64Key c64Key; } kKeyMap[] = {
    // Letters (ANSI layout keycodes)
    { 0x00, C64Key::A },       // kVK_ANSI_A
    { 0x0B, C64Key::B },       // kVK_ANSI_B
    { 0x08, C64Key::C },       // kVK_ANSI_C (mapped to C64 C key)
    { 0x02, C64Key::D },       // kVK_ANSI_D
    { 0x0E, C64Key::E },       // kVK_ANSI_E
    { 0x03, C64Key::F },       // kVK_ANSI_F
    { 0x05, C64Key::G },       // kVK_ANSI_G
    { 0x04, C64Key::H },       // kVK_ANSI_H
    { 0x22, C64Key::I },       // kVK_ANSI_I
    { 0x26, C64Key::J },       // kVK_ANSI_J
    { 0x28, C64Key::K },       // kVK_ANSI_K
    { 0x25, C64Key::L },       // kVK_ANSI_L
    { 0x2E, C64Key::M },       // kVK_ANSI_M
    { 0x2D, C64Key::N },       // kVK_ANSI_N
    { 0x1F, C64Key::O },       // kVK_ANSI_O
    { 0x23, C64Key::P },       // kVK_ANSI_P
    { 0x0C, C64Key::Q },       // kVK_ANSI_Q
    { 0x0F, C64Key::R },       // kVK_ANSI_R
    { 0x01, C64Key::S },       // kVK_ANSI_S
    { 0x11, C64Key::T },       // kVK_ANSI_T
    { 0x20, C64Key::U },       // kVK_ANSI_U
    { 0x09, C64Key::V },       // kVK_ANSI_V
    { 0x0D, C64Key::W },       // kVK_ANSI_W
    { 0x07, C64Key::X },       // kVK_ANSI_X
    { 0x10, C64Key::Y },       // kVK_ANSI_Y
    { 0x06, C64Key::Z },       // kVK_ANSI_Z

    // Digits
    { 0x12, C64Key::digit1 },  // kVK_ANSI_1
    { 0x13, C64Key::digit2 },  // kVK_ANSI_2
    { 0x14, C64Key::digit3 },  // kVK_ANSI_3
    { 0x15, C64Key::digit4 },  // kVK_ANSI_4
    { 0x17, C64Key::digit5 },  // kVK_ANSI_5
    { 0x16, C64Key::digit6 },  // kVK_ANSI_6
    { 0x1A, C64Key::digit7 },  // kVK_ANSI_7
    { 0x1C, C64Key::digit8 },  // kVK_ANSI_8
    { 0x19, C64Key::digit9 },  // kVK_ANSI_9
    { 0x1D, C64Key::digit0 },  // kVK_ANSI_0

    // Special keys
    { 0x24, C64Key::ret },         // kVK_Return
    { 0x31, C64Key::space },       // kVK_Space
    { 0x33, C64Key::del },         // kVK_Delete (backspace)
    { 0x35, C64Key::runStop },     // kVK_Escape -> Run/Stop
    { 0x30, C64Key::control },     // kVK_Tab -> Control
    { 0x38, C64Key::leftShift },   // kVK_Shift (left)
    { 0x3C, C64Key::rightShift },  // kVK_RightShift
    { 0x3A, C64Key::commodore },   // kVK_Option -> Commodore

    // Function keys
    { 0x7A, C64Key::F1F2 },       // kVK_F1
    { 0x78, C64Key::F1F2 },       // kVK_F2 (same physical key, shifted)
    { 0x63, C64Key::F3F4 },       // kVK_F3
    { 0x76, C64Key::F3F4 },       // kVK_F4
    { 0x60, C64Key::F5F6 },       // kVK_F5
    { 0x61, C64Key::F5F6 },       // kVK_F6
    { 0x62, C64Key::F7F8 },       // kVK_F7
    { 0x64, C64Key::F7F8 },       // kVK_F8

    // Cursor keys
    { 0x7E, C64Key::curUpDown },    // kVK_UpArrow
    { 0x7D, C64Key::curUpDown },    // kVK_DownArrow
    { 0x7B, C64Key::curLeftRight }, // kVK_LeftArrow
    { 0x7C, C64Key::curLeftRight }, // kVK_RightArrow

    // Symbols
    { 0x1B, C64Key::minus },      // kVK_ANSI_Minus
    { 0x18, C64Key::equal },      // kVK_ANSI_Equal -> =
    { 0x21, C64Key::leftArrow },  // kVK_ANSI_LeftBracket -> left arrow
    { 0x1E, C64Key::plus },       // kVK_ANSI_RightBracket -> +
    { 0x29, C64Key::semicolon },  // kVK_ANSI_Semicolon
    { 0x27, C64Key::colon },      // kVK_ANSI_Quote -> :
    { 0x2B, C64Key::comma },      // kVK_ANSI_Comma
    { 0x2F, C64Key::period },     // kVK_ANSI_Period
    { 0x2C, C64Key::slash },      // kVK_ANSI_Slash
    { 0x32, C64Key::leftArrow },  // kVK_ANSI_Grave -> left arrow (`)
    { 0x2A, C64Key::at },         // kVK_ANSI_Backslash -> @

    // Home
    { 0x73, C64Key::home },       // kVK_Home
    { 0x77, C64Key::home },       // kVK_End -> Home

    // Restore (NMI)
    { 0x69, C64Key::restore },    // kVK_F13 -> Restore
    { 0x71, C64Key::restore },    // kVK_F15 -> Restore
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

    // Display modes
    BOOL _showBorders;
    NSMutableArray<NSMutableDictionary<NSString *, id> *> *_availableDisplayModes;
}
@end

@implementation VirtualC64GameCore

#pragma mark - Lifecycle

- (id)init
{
    if (self = [super init]) {
        _videoBuffer = (uint32_t *)calloc(VC64_TEX_WIDTH * VC64_TEX_HEIGHT, sizeof(uint32_t));
        _isPAL = YES;
        _showBorders = NO;
        _joystickSwapped = NO;
        _samplesPerFrame = VC64_SAMPLES_PER_FRAME_PAL;

        // Allocate audio buffers (stereo interleaved)
        _audioFloatBuffer = (float *)calloc(_samplesPerFrame * 2, sizeof(float));
        _audioIntBuffer = (int16_t *)calloc(_samplesPerFrame * 2, sizeof(int16_t));
    }
    return self;
}

- (void)dealloc
{
    if (_emu.isRunning()) {
        _emu.pause();
    }
    if (_emu.isPoweredOn()) {
        _emu.powerOff();
    }
    _emu.halt();

    free(_videoBuffer);
    free(_audioFloatBuffer);
    free(_audioIntBuffer);
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    // Launch the emulator thread
    _emu.launch((__bridge const void *)self, emuCallback);

    // Install open-source ROMs (MEGA65 OpenROMs) so we don't require BIOS files
    try {
        _emu.c64.installOpenRoms();
    } catch (...) {
        NSLog(@"[VirtualC64] Warning: Could not install OpenROMs");
    }

    // Configure as PAL by default
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

    // Determine file type and load
    NSString *ext = path.pathExtension.lowercaseString;
    std::filesystem::path fsPath(path.fileSystemRepresentation);

    try {
        if ([ext isEqualToString:@"crt"]) {
            // Cartridge
            _emu.expansionPort.attachCartridge(fsPath, false);
        } else if ([ext isEqualToString:@"d64"] ||
                   [ext isEqualToString:@"g64"] ||
                   [ext isEqualToString:@"d71"] ||
                   [ext isEqualToString:@"d81"]) {
            // Disk image — insert into drive 8
            _emu.drive8.insert(fsPath, false);
        } else if ([ext isEqualToString:@"tap"]) {
            // Tape image
            _emu.datasette.insertTape(fsPath);
        } else if ([ext isEqualToString:@"t64"] ||
                   [ext isEqualToString:@"prg"] ||
                   [ext isEqualToString:@"p00"]) {
            // Program file — flash into memory
            _emu.c64.flash(fsPath);
        } else {
            // Try generic flash for unknown types
            _emu.c64.flash(fsPath);
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

    return YES;
}

- (void)setupEmulation
{
    _samplesPerFrame = _isPAL ? VC64_SAMPLES_PER_FRAME_PAL : VC64_SAMPLES_PER_FRAME_NTSC;
}

- (void)startEmulation
{
    [super startEmulation];

    try {
        _emu.run();
    } catch (std::exception &e) {
        NSLog(@"[VirtualC64] Error starting emulation: %s", e.what());
    } catch (...) {
        NSLog(@"[VirtualC64] Unknown error starting emulation");
    }
}

- (void)stopEmulation
{
    try {
        if (_emu.isRunning()) {
            _emu.pause();
        }
        if (_emu.isPoweredOn()) {
            _emu.powerOff();
        }
    } catch (...) {
        NSLog(@"[VirtualC64] Error stopping emulation");
    }

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
    // Signal vsync to the emulator thread — this tells it to compute the next frame
    _emu.wakeUp();

    // Copy video data from the emulator's texture
    _emu.videoPort.lockTexture();
    const u32 *texture = _emu.videoPort.getTexture();
    if (texture) {
        memcpy(_videoBuffer, texture, VC64_TEX_WIDTH * VC64_TEX_HEIGHT * sizeof(uint32_t));
    }
    _emu.videoPort.unlockTexture();

    // Copy audio data
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
}

#pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    return _videoBuffer;
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(VC64_TEX_WIDTH, VC64_TEX_HEIGHT);
}

- (OEIntRect)screenRect
{
    // VirtualC64 texture layout (520x312):
    //   Columns 0-103:   HBLANK (black, not visible)
    //   Columns 104-135: Left border (32 px)
    //   Columns 136-455: Canvas (320 px)
    //   Columns 456-487: Right border (32 px)
    //   Columns 488+:    Right HBLANK
    //   Lines 0-15:      VBLANK (not visible)
    //   Lines 16-287:    Visible area (PAL, 272 lines)
    //   Lines 16-249:    Visible area (NTSC, 234 lines)

    // Default: show full visible area with borders (standard C64 display)
    if (_isPAL) {
        return OEIntRectMake(104, 16, 384, 272);
    } else {
        return OEIntRectMake(104, 16, 384, 234);
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
    return OEPixelFormat_BGRA;
}

- (uint32_t)pixelType
{
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
        if (kKeyMap[i].macKey == keyCode) {
            _emu.keyboard.press(kKeyMap[i].c64Key);
            return;
        }
    }
}

- (oneway void)keyUp:(NSUInteger)keyCode
{
    for (int i = 0; i < kKeyMapSize; i++) {
        if (kKeyMap[i].macKey == keyCode) {
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

- (BOOL)insertFileAtURL:(NSURL *)file completionHandler:(void (^)(BOOL, NSError *))block
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
            return NO;
        }

        if (block) block(YES, nil);
        return YES;
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
        return NO;
    } catch (...) {
        if (block) {
            NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                                 code:OEGameCoreCouldNotLoadROMError
                                             userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to insert file"
            }];
            block(NO, error);
        }
        return NO;
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

        // Border options
        [_availableDisplayModes addObject:[@{
            OEGameCoreDisplayModeNameKey: @"Show Borders",
            OEGameCoreDisplayModeStateKey: @(_showBorders),
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
    } else if ([displayMode isEqualToString:@"Show Borders"]) {
        _showBorders = !_showBorders;
    }

    // Reset display modes cache to reflect state changes
    _availableDisplayModes = nil;
}

@end
