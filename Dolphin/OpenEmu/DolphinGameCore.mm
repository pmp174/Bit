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

#include <string>
#include <memory>
#include <thread>
#include <atomic>

#include "Common/WindowSystemInfo.h"
#include "Core/Core.h"
#include "Core/System.h"
#include "Core/State.h"
#include "Core/Boot/Boot.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/SYSCONFSettings.h"
#include "Core/ConfigManager.h"
#include "Core/HW/GCPad.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "Core/HW/ProcessorInterface.h"
#include "InputCommon/GCPadStatus.h"
#include "InputCommon/InputConfig.h"
#include "AudioCommon/AudioCommon.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoConfig.h"

#define SAMPLERATE 48000

#pragma mark -

@interface DolphinGameCore ()
{
    NSString *_romPath;
    int _videoWidth;
    int _videoHeight;
    BOOL _isInitialized;
    BOOL _loadFailed;
    BOOL _isWii;
    double _frameInterval;

    // GameCube pad state per player
    GCPadStatus _padStatus[4];
}
@end

__weak DolphinGameCore *_current;

@implementation DolphinGameCore

#pragma mark - Lifecycle

- (id)init
{
    if (self = [super init]) {
        _videoWidth = 640;
        _videoHeight = 480;
        _isInitialized = NO;
        _loadFailed = NO;
        _isWii = NO;
        _frameInterval = 60.0;

        // Initialize pad status (centered sticks, no buttons)
        for (int i = 0; i < 4; i++) {
            memset(&_padStatus[i], 0, sizeof(GCPadStatus));
            _padStatus[i].stickX = 0x80;
            _padStatus[i].stickY = 0x80;
            _padStatus[i].substickX = 0x80;
            _padStatus[i].substickY = 0x80;
            _padStatus[i].isConnected = true;
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

    NSLog(@"[Dolphin] Support path: %@", supportPath);
    NSLog(@"[Dolphin] Saves path: %@", savesPath);

    // Configure Dolphin's user directory paths
    auto& system = Core::System::GetInstance();

    // Set up SConfig paths
    SConfig& config = SConfig::GetInstance();
    config.m_strUserPath = std::string([supportPath stringByAppendingPathComponent:@"User/"].fileSystemRepresentation);

    // Configure graphics for OpenGL (OpenEmu provides an OpenGL context)
    Config::SetBase(Config::MAIN_GFX_BACKEND, std::string("OGL"));

    // Disable analytics and auto-updates
    Config::SetBase(Config::MAIN_ANALYTICS_ENABLED, false);

    // Configure audio
    Config::SetBase(Config::MAIN_AUDIO_BACKEND, std::string("OpenEmu"));

    NSLog(@"[Dolphin] Emulation setup complete");
}

- (void)startEmulation
{
    [super startEmulation];
}

- (void)stopEmulation
{
    if (_isInitialized) {
        auto& system = Core::System::GetInstance();
        Core::Stop(system);
        Core::Shutdown(system);
        _isInitialized = NO;
    }
    [super stopEmulation];
}

- (void)resetEmulation
{
    if (_isInitialized) {
        auto& system = Core::System::GetInstance();
        // Request a reset through the processor interface
        ProcessorInterface::ResetButton_Tap(system);
    }
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

            // Set up window system info for OpenGL rendering
            WindowSystemInfo wsi;
            wsi.type = WindowSystemType::MacOS;
            wsi.render_window = nullptr;
            wsi.render_surface = nullptr;
            wsi.render_surface_scale = 1.0f;

            // Initialize and boot Dolphin
            if (!Core::Init(system, std::move(boot), wsi)) {
                NSLog(@"[Dolphin] Core::Init failed");
                _loadFailed = YES;
                return;
            }

            _isInitialized = YES;
            NSLog(@"[Dolphin] Game booted successfully");
        } catch (const std::exception &e) {
            NSLog(@"[Dolphin] Error booting game: %s", e.what());
            _loadFailed = YES;
            return;
        } catch (...) {
            NSLog(@"[Dolphin] Unknown error booting game");
            _loadFailed = YES;
            return;
        }
    }

    // Dolphin runs its own CPU/GPU threads; we just need to process host events
    auto& system = Core::System::GetInstance();
    Core::HostDispatchJobs(system);

    // Present the rendered frame through OpenEmu's FBO
    [self.renderDelegate presentDoubleBufferedFBO];
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

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (_isInitialized) {
        @try {
            auto& system = Core::System::GetInstance();
            State::SaveAs(system, std::string([fileName fileSystemRepresentation]));
            block(YES, nil);
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
            auto& system = Core::System::GetInstance();
            State::LoadAs(system, std::string([fileName fileSystemRepresentation]));
            block(YES, nil);
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

#pragma mark - GameCube Input

- (oneway void)didMoveGCJoystickDirection:(OEGCButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    // Convert from [-1.0, 1.0] range to [0, 255] range (centered at 0x80)
    switch (button) {
        case OEGCAnalogUp:
            _padStatus[player].stickY = 0x80 + (u8)(value * 0x7F);
            break;
        case OEGCAnalogDown:
            _padStatus[player].stickY = 0x80 - (u8)(value * 0x7F);
            break;
        case OEGCAnalogLeft:
            _padStatus[player].stickX = 0x80 - (u8)(value * 0x7F);
            break;
        case OEGCAnalogRight:
            _padStatus[player].stickX = 0x80 + (u8)(value * 0x7F);
            break;
        case OEGCAnalogCUp:
            _padStatus[player].substickY = 0x80 + (u8)(value * 0x7F);
            break;
        case OEGCAnalogCDown:
            _padStatus[player].substickY = 0x80 - (u8)(value * 0x7F);
            break;
        case OEGCAnalogCLeft:
            _padStatus[player].substickX = 0x80 - (u8)(value * 0x7F);
            break;
        case OEGCAnalogCRight:
            _padStatus[player].substickX = 0x80 + (u8)(value * 0x7F);
            break;
        case OEGCButtonL:
            _padStatus[player].triggerLeft = (u8)(value * 0xFF);
            break;
        case OEGCButtonR:
            _padStatus[player].triggerRight = (u8)(value * 0xFF);
            break;
        default:
            break;
    }
}

- (oneway void)didPushGCButton:(OEGCButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    switch (button) {
        case OEGCButtonUp:    _padStatus[player].button |= PAD_BUTTON_UP; break;
        case OEGCButtonDown:  _padStatus[player].button |= PAD_BUTTON_DOWN; break;
        case OEGCButtonLeft:  _padStatus[player].button |= PAD_BUTTON_LEFT; break;
        case OEGCButtonRight: _padStatus[player].button |= PAD_BUTTON_RIGHT; break;
        case OEGCButtonA:     _padStatus[player].button |= PAD_BUTTON_A; break;
        case OEGCButtonB:     _padStatus[player].button |= PAD_BUTTON_B; break;
        case OEGCButtonX:     _padStatus[player].button |= PAD_BUTTON_X; break;
        case OEGCButtonY:     _padStatus[player].button |= PAD_BUTTON_Y; break;
        case OEGCButtonZ:     _padStatus[player].button |= PAD_TRIGGER_Z; break;
        case OEGCButtonL:     _padStatus[player].button |= PAD_TRIGGER_L; break;
        case OEGCButtonR:     _padStatus[player].button |= PAD_TRIGGER_R; break;
        case OEGCButtonStart: _padStatus[player].button |= PAD_BUTTON_START; break;
        default: break;
    }
}

- (oneway void)didReleaseGCButton:(OEGCButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    switch (button) {
        case OEGCButtonUp:    _padStatus[player].button &= ~PAD_BUTTON_UP; break;
        case OEGCButtonDown:  _padStatus[player].button &= ~PAD_BUTTON_DOWN; break;
        case OEGCButtonLeft:  _padStatus[player].button &= ~PAD_BUTTON_LEFT; break;
        case OEGCButtonRight: _padStatus[player].button &= ~PAD_BUTTON_RIGHT; break;
        case OEGCButtonA:     _padStatus[player].button &= ~PAD_BUTTON_A; break;
        case OEGCButtonB:     _padStatus[player].button &= ~PAD_BUTTON_B; break;
        case OEGCButtonX:     _padStatus[player].button &= ~PAD_BUTTON_X; break;
        case OEGCButtonY:     _padStatus[player].button &= ~PAD_BUTTON_Y; break;
        case OEGCButtonZ:     _padStatus[player].button &= ~PAD_TRIGGER_Z; break;
        case OEGCButtonL:     _padStatus[player].button &= ~PAD_TRIGGER_L; break;
        case OEGCButtonR:     _padStatus[player].button &= ~PAD_TRIGGER_R; break;
        case OEGCButtonStart: _padStatus[player].button &= ~PAD_BUTTON_START; break;
        default: break;
    }
}

#pragma mark - Wii Input

- (oneway void)didPushWiiButton:(OEWiiButton)button forPlayer:(NSUInteger)player
{
    // Wii input will be implemented after core boot validation
    // Maps OEWiiButton events to Dolphin's Wiimote emulation layer
}

- (oneway void)didReleaseWiiButton:(OEWiiButton)button forPlayer:(NSUInteger)player
{
    // Wii input will be implemented after core boot validation
}

- (oneway void)didMoveWiiJoystickDirection:(OEWiiButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    // Wii analog input will be implemented after core boot validation
}

@end
