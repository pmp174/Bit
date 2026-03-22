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

// Rename macOS Carbon's RGBColor to avoid clash with Flycast's RGBColor
#define RGBColor __macOS_RGBColor
#import <Cocoa/Cocoa.h>
#undef RGBColor

#import "FlycastGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEGameCore.h>

#include "emulator.h"
#include "types.h"
#include "cfg/option.h"
#include "stdclass.h"
#include "hw/maple/maple_cfg.h"
#include "hw/maple/maple_devs.h"
#include "hw/pvr/Renderer_if.h"
#include "input/gamepad.h"
#include "input/gamepad_device.h"
#include "audio/audiostream.h"
#include "ui/gui.h"
#include "rend/gles/gles.h"
#include "hw/mem/addrspace.h"
#include "oslib/oslib.h"
#include "wsi/osx.h"

#include <OpenGL/gl3.h>
#include <sys/stat.h>

#define SAMPLERATE 44100
#define SIZESOUNDBUFFER (44100 / 60 * 4)

#pragma mark - OpenEmu Audio Backend

// Custom AudioBackend that writes samples to OpenEmu's ring buffer
class OpenEmuAudioBackend : public AudioBackend
{
public:
    OpenEmuAudioBackend() : AudioBackend("openemu", "OpenEmu") {}

    bool init() override { return true; }

    u32 push(const void *data, u32 frames, bool wait) override
    {
        if (_current) {
            [[_current audioBufferAtIndex:0] write:(const uint8_t *)data
                                         maxLength:frames * 4]; // stereo s16 = 4 bytes per frame
        }
        return frames;
    }

    void term() override {}
};

static OpenEmuAudioBackend openEmuAudioBackend;

#pragma mark - OpenEmu Gamepad Device

// Minimal GamepadDevice to register with Flycast's input system
class OpenEmuGamepad : public GamepadDevice
{
public:
    OpenEmuGamepad(int port) : GamepadDevice(port, "OpenEmu", false) {
        _name = "OpenEmu Controller";
        _unique_id = "openemu_pad_" + std::to_string(port);
        input_mapper = std::make_shared<IdentityInputMapping>();
    }

    bool is_virtual_gamepad() override { return true; }
};

static std::shared_ptr<OpenEmuGamepad> openEmuGamepads[4];

#pragma mark -

@interface FlycastGameCore () <OEDCSystemResponderClient>
{
    NSString *_romPath;
    int _videoWidth;
    int _videoHeight;
    BOOL _isInitialized;
    double _frameInterval;
}
@end

__weak FlycastGameCore *_current;

@implementation FlycastGameCore

#pragma mark - Lifecycle

- (id)init
{
    if (self = [super init]) {
        _videoWidth = 640;
        _videoHeight = 480;
        _isInitialized = NO;
        _frameInterval = 59.94;
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
    return YES;
}

- (void)setupEmulation
{
    // Set up directories
    NSString *supportPath = [self supportDirectoryPath];
    NSString *savesPath = [self batterySavesDirectoryPath];
    NSString *biosPath = [self biosDirectoryPath];

    // Create necessary directories
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"data"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:savesPath
  withIntermediateDirectories:YES attributes:nil error:nil];

    // Configure Flycast paths
    set_user_config_dir(supportPath.fileSystemRepresentation);
    set_user_data_dir(savesPath.fileSystemRepresentation);
    add_system_data_dir(supportPath.fileSystemRepresentation);
    add_system_data_dir(biosPath.fileSystemRepresentation);

    // Configure options before init
    config::RendererType = RenderType::OpenGL;
    config::AudioBackend.set("openemu");
    config::DynarecEnabled = true;

    // Reserve the Dreamcast virtual address space and install fault handlers
    // (normally done by flycast_init, which we bypass in OpenEmu)
    if (!addrspace::reserve()) {
        NSLog(@"[Flycast] Failed to reserve address space");
    }
    os_InstallFaultHandler();

    // Initialize the emulator
    emu.init();
}

- (void)startEmulation
{
    [super startEmulation];
}

- (void)stopEmulation
{
    if (_isInitialized) {
        emu.stop();
        emu.unloadGame();
        rend_term_renderer();
        theGLContext.term();
        _isInitialized = NO;
    }
    os_UninstallFaultHandler();
    emu.term();  // internally calls addrspace::release() as its last step
    [super stopEmulation];
}

- (void)resetEmulation
{
    if (_isInitialized) {
        emu.requestReset();
    }
}

#pragma mark - Frame Execution

- (void)executeFrame
{
    if (!_isInitialized) {
        // Load and start the game on first frame
        try {
            // Initialize the GL graphics context (registers with Flycast's renderer system)
            // OpenEmu's GL context is already current at this point
            theGLContext.init();

            emu.loadGame(_romPath.fileSystemRepresentation);

            // Override settings that loadGame() may have reset from saved config
            config::ThreadedRendering.override(false);  // OpenEmu drives the frame loop

            // Initialize the OpenGL renderer (creates shaders, FBOs, etc.)
            rend_init_renderer();

            emu.start();
            gui_setState(GuiState::Closed);
            _isInitialized = YES;
        } catch (const std::exception &e) {
            NSLog(@"[Flycast] Error loading game: %s", e.what());
            return;
        } catch (...) {
            NSLog(@"[Flycast] Unknown error loading game");
            return;
        }
    }

    // Run one frame and render via OpenGL into OpenEmu's FBO
    [self.renderDelegate presentDoubleBufferedFBO];
    emu.render();
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

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (_isInitialized) {
        @try {
            dc_savestate(0);

            // Copy the save state file from Flycast's data dir to OpenEmu's path
            std::string srcPath = hostfs::getSavestatePath(0, false);
            NSString *src = [NSString stringWithUTF8String:srcPath.c_str()];
            NSError *err = nil;
            [[NSFileManager defaultManager] removeItemAtPath:fileName error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:src toPath:fileName error:&err];

            if (err) {
                block(NO, err);
            } else {
                block(YES, nil);
            }
        } @catch (NSException *e) {
            NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                                 code:OEGameCoreCouldNotSaveStateError
                                             userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"Failed to save state"}];
            block(NO, error);
        }
    } else {
        block(NO, nil);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (_isInitialized) {
        @try {
            // Copy OpenEmu's save state to Flycast's expected location
            std::string dstPath = hostfs::getSavestatePath(0, true);
            NSString *dst = [NSString stringWithUTF8String:dstPath.c_str()];
            NSError *err = nil;
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:fileName toPath:dst error:&err];

            if (!err) {
                dc_loadstate(0);
            }

            block(err == nil, err);
        } @catch (NSException *e) {
            NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                                 code:OEGameCoreCouldNotLoadStateError
                                             userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"Failed to load state"}];
            block(NO, error);
        }
    } else {
        block(NO, nil);
    }
}

#pragma mark - Input

- (oneway void)didMoveDCJoystickDirection:(OEDCButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    switch (button) {
        case OEDCAnalogUp:
            joyy[player] = value * -32768;
            break;
        case OEDCAnalogDown:
            joyy[player] = value * 32767;
            break;
        case OEDCAnalogLeft:
            joyx[player] = value * -32768;
            break;
        case OEDCAnalogRight:
            joyx[player] = value * 32767;
            break;
        case OEDCAnalogL:
            lt[player] = (u16)(value * 65535);
            break;
        case OEDCAnalogR:
            rt[player] = (u16)(value * 65535);
            break;
        default:
            break;
    }
}

- (oneway void)didPushDCButton:(OEDCButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    switch (button) {
        case OEDCButtonUp:
            kcode[player] &= ~DC_DPAD_UP;
            break;
        case OEDCButtonDown:
            kcode[player] &= ~DC_DPAD_DOWN;
            break;
        case OEDCButtonLeft:
            kcode[player] &= ~DC_DPAD_LEFT;
            break;
        case OEDCButtonRight:
            kcode[player] &= ~DC_DPAD_RIGHT;
            break;
        case OEDCButtonA:
            kcode[player] &= ~DC_BTN_A;
            break;
        case OEDCButtonB:
            kcode[player] &= ~DC_BTN_B;
            break;
        case OEDCButtonX:
            kcode[player] &= ~DC_BTN_X;
            break;
        case OEDCButtonY:
            kcode[player] &= ~DC_BTN_Y;
            break;
        case OEDCButtonStart:
            kcode[player] &= ~DC_BTN_START;
            break;
        default:
            break;
    }
}

- (oneway void)didReleaseDCButton:(OEDCButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    switch (button) {
        case OEDCButtonUp:
            kcode[player] |= DC_DPAD_UP;
            break;
        case OEDCButtonDown:
            kcode[player] |= DC_DPAD_DOWN;
            break;
        case OEDCButtonLeft:
            kcode[player] |= DC_DPAD_LEFT;
            break;
        case OEDCButtonRight:
            kcode[player] |= DC_DPAD_RIGHT;
            break;
        case OEDCButtonA:
            kcode[player] |= DC_BTN_A;
            break;
        case OEDCButtonB:
            kcode[player] |= DC_BTN_B;
            break;
        case OEDCButtonX:
            kcode[player] |= DC_BTN_X;
            break;
        case OEDCButtonY:
            kcode[player] |= DC_BTN_Y;
            break;
        case OEDCButtonStart:
            kcode[player] |= DC_BTN_START;
            break;
        default:
            break;
    }
}

@end
