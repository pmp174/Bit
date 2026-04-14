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
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import "PCSX2GameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEGameCore.h>

// PCSX2 headers
#include "common/Pcsx2Defs.h"
#include "common/Console.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/Path.h"
#include "common/SettingsInterface.h"
#include "common/MemorySettingsInterface.h"
#include "common/StringUtil.h"
#include "common/Threading.h"

#include "pcsx2/VMManager.h"
#include "pcsx2/GS/GS.h"
#include "pcsx2/Host.h"
#include "pcsx2/Config.h"
#include "pcsx2/SIO/Pad/Pad.h"
#include "pcsx2/SIO/Pad/PadTypes.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/CDVD/CDVD.h"
#include "pcsx2/R5900.h"
#include "pcsx2/ps2/BiosTools.h"

#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>

// Default PS2 output resolution (NTSC)
#define PS2_WIDTH  640
#define PS2_HEIGHT 448
#define PS2_SAMPLERATE 48000
#define PS2_BPP    4  // BGRA8 = 4 bytes per pixel

__unsafe_unretained PCSX2GameCore *_current = nil;

#pragma mark - OpenEmu Bridge Globals

// These globals are accessed by PCSX2Host.mm and GSDeviceMTL modifications
namespace OpenEmuBridge {
    id<MTLDevice> g_metalDevice = nil;
    id<MTLTexture> g_outputTexture = nil;
    id<OERenderDelegate> g_renderDelegate = nil;
    OERingBuffer *g_audioBuffer = nil;

    // Audio write callback (bridges C++ drain thread to ObjC OERingBuffer)
    typedef void (*AudioWriteFunc)(const int16_t* samples, uint32_t num_frames);
    AudioWriteFunc g_audioWriteFunc = nullptr;

    // Button state for up to 2 controllers
    std::atomic<uint32_t> g_buttonState[2] = {};
    std::atomic<float> g_leftAnalogX[2] = {};
    std::atomic<float> g_leftAnalogY[2] = {};
    std::atomic<float> g_rightAnalogX[2] = {};
    std::atomic<float> g_rightAnalogY[2] = {};

    // Frame synchronization
    std::mutex g_frameMutex;
    std::condition_variable g_frameCV;
    std::atomic<bool> g_frameReady{false};
    std::atomic<bool> g_shutdownRequested{false};

    // Settings
    MemorySettingsInterface *g_settingsInterface = nullptr;
    std::mutex g_settingsMutex;

    // BIOS directory path
    std::string g_biosPath;
    std::string g_supportPath;
    std::string g_savesPath;

    // CPU-side video buffer for bitmap rendering readback
    uint32_t g_videoBuffer[PS2_WIDTH * PS2_HEIGHT] = {};
}

// Audio write callback: converts and writes audio samples to OpenEmu's ring buffer
static void oeAudioWriteCallback(const int16_t* samples, uint32_t num_frames) {
    if (OpenEmuBridge::g_audioBuffer) {
        NSUInteger bytes = num_frames * 2 * sizeof(int16_t);  // 2 channels, 2 bytes per sample
        [OpenEmuBridge::g_audioBuffer write:samples maxLength:bytes];
    }
}

// File-based logging for diagnostics (NSLog doesn't appear in unified log for helper process)
static void PCSX2Log(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void PCSX2Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *logPath = @"/tmp/pcsx2_openemu.log";
    NSString *timestamped = [NSString stringWithFormat:@"[%@] %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
                                       dateStyle:NSDateFormatterNoStyle
                                       timeStyle:NSDateFormatterMediumStyle], msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [fh seekToEndOfFile];
    [fh writeData:[timestamped dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#pragma mark - PCSX2GameCore Implementation

@implementation PCSX2GameCore {
    NSString *_romPath;
    BOOL _isInitialized;
    std::thread _emuThread;
    std::atomic<bool> _emuThreadExited;
}

- (id)init {
    if (self = [super init]) {
        _current = self;
        _isInitialized = NO;
    }
    return self;
}

- (void)dealloc {
    if (_current == self) {
        _current = nil;
    }
    if (OpenEmuBridge::g_settingsInterface) {
        delete OpenEmuBridge::g_settingsInterface;
        OpenEmuBridge::g_settingsInterface = nullptr;
    }
}

#pragma mark - Lifecycle

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error {
    // PCSX2 doesn't support CUE files directly - resolve to the BIN/IMG file
    if ([[path pathExtension] caseInsensitiveCompare:@"cue"] == NSOrderedSame) {
        NSString *resolved = [self resolveBinPathFromCue:path];
        if (resolved) {
            PCSX2Log(@"[PCSX2] Resolved CUE -> BIN: %@", resolved);
            _romPath = resolved;
        } else {
            PCSX2Log(@"[PCSX2] Could not resolve BIN from CUE, using CUE path directly");
            _romPath = [path copy];
        }
    } else {
        _romPath = [path copy];
    }
    return YES;
}

- (NSString *)resolveBinPathFromCue:(NSString *)cuePath {
    NSString *cueContents = [NSString stringWithContentsOfFile:cuePath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
    if (!cueContents) return nil;

    // Parse FILE "filename" BINARY line
    NSArray *lines = [cueContents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"FILE "]) {
            // Extract filename between quotes
            NSRange firstQuote = [trimmed rangeOfString:@"\""];
            if (firstQuote.location != NSNotFound) {
                NSRange rest = NSMakeRange(firstQuote.location + 1,
                                          trimmed.length - firstQuote.location - 1);
                NSRange secondQuote = [trimmed rangeOfString:@"\"" options:0 range:rest];
                if (secondQuote.location != NSNotFound) {
                    NSString *binFilename = [trimmed substringWithRange:
                        NSMakeRange(firstQuote.location + 1,
                                   secondQuote.location - firstQuote.location - 1)];
                    NSString *cueDir = [cuePath stringByDeletingLastPathComponent];
                    NSString *binPath = [cueDir stringByAppendingPathComponent:binFilename];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:binPath]) {
                        return binPath;
                    }
                }
            }
        }
    }
    return nil;
}

- (void)setupEmulation {
    // Create settings interface
    OpenEmuBridge::g_settingsInterface = new MemorySettingsInterface();
    auto &si = *OpenEmuBridge::g_settingsInterface;

    // Set up directory paths
    NSString *supportPath = [self supportDirectoryPath];
    NSString *savesPath = [self batterySavesDirectoryPath];
    NSString *biosPath = [self biosDirectoryPath];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:supportPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];

    OpenEmuBridge::g_biosPath = [biosPath fileSystemRepresentation];
    OpenEmuBridge::g_supportPath = [supportPath fileSystemRepresentation];
    OpenEmuBridge::g_savesPath = [savesPath fileSystemRepresentation];

    // Create subdirectories PCSX2 expects
    NSString *memcardsPath = [supportPath stringByAppendingPathComponent:@"memcards"];
    NSString *savestatesPath = [supportPath stringByAppendingPathComponent:@"sstates"];
    NSString *cachePath = [supportPath stringByAppendingPathComponent:@"cache"];
    NSString *cheatsPath = [supportPath stringByAppendingPathComponent:@"cheats"];
    NSString *patchesPath = [supportPath stringByAppendingPathComponent:@"patches"];
    NSString *texturePath = [supportPath stringByAppendingPathComponent:@"textures"];

    for (NSString *dir in @[memcardsPath, savestatesPath, cachePath, cheatsPath, patchesPath, texturePath]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Populate all default settings first, then override with our values
    VMManager::SetDefaultSettings(si, true, true, true, true, true);

    // Configure folders (overrides defaults with absolute paths)
    si.SetStringValue("Folders", "Bios", OpenEmuBridge::g_biosPath.c_str());
    si.SetStringValue("Folders", "Savestates", [savestatesPath fileSystemRepresentation]);
    si.SetStringValue("Folders", "MemoryCards", [memcardsPath fileSystemRepresentation]);
    si.SetStringValue("Folders", "Cache", [cachePath fileSystemRepresentation]);
    si.SetStringValue("Folders", "Cheats", [cheatsPath fileSystemRepresentation]);
    si.SetStringValue("Folders", "Patches", [patchesPath fileSystemRepresentation]);
    si.SetStringValue("Folders", "Textures", [texturePath fileSystemRepresentation]);

    // CPU settings - ARM64 recompilers: EE, IOP, VU0, VU1 all enabled
    si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", true);
    si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU0", true);
    si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU1", true);
    si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableIOP", true);

    // Speedhacks - enable MTVU (multi-threaded VU1) for better performance
    si.SetBoolValue("EmuCore/Speedhacks", "vuThread", true);

    // GS / Renderer settings - Metal
    si.SetIntValue("EmuCore/GS", "Renderer", 0); // Auto (Metal on macOS)
    si.SetIntValue("EmuCore/GS", "upscale_multiplier", 1); // Native resolution
    si.SetBoolValue("EmuCore/GS", "disable_shader_cache", false);

    // SPU2 audio - Cubeb backend routes through our OpenEmuAudioStream to OERingBuffer

    // General settings
    si.SetBoolValue("EmuCore", "EnableFastBoot", false);  // Show PS2 BIOS boot screen
    si.SetBoolValue("EmuCore", "EnableCheats", false);
    si.SetBoolValue("EmuCore", "EnableWideScreenPatches", false);

    // Memory card configuration
    si.SetBoolValue("MemoryCards", "Slot1_Enable", true);
    si.SetStringValue("MemoryCards", "Slot1_Filename", "Mcd001.ps2");
    si.SetBoolValue("MemoryCards", "Slot2_Enable", true);
    si.SetStringValue("MemoryCards", "Slot2_Filename", "Mcd002.ps2");

    // Controller configuration - DualShock 2 on port 1
    si.SetStringValue("Pad1", "Type", "DualShock2");
    si.SetStringValue("Pad2", "Type", "DualShock2");

    // Set the base settings layer
    {
        std::unique_lock<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
        Host::Internal::SetBaseSettingsLayer(OpenEmuBridge::g_settingsInterface);
    }

    // Set DataRoot for any relative path resolution
    EmuFolders::DataRoot = OpenEmuBridge::g_supportPath;
    EmuFolders::AppRoot = OpenEmuBridge::g_supportPath;

    // Set Resources path to our plugin bundle's Resources directory
    // This is where the compiled Metal shader library (Metal23.metallib) lives
    NSBundle *coreBundle = [NSBundle bundleForClass:[self class]];
    NSString *resourcesPath = [coreBundle resourcePath];
    if (resourcesPath) {
        EmuFolders::Resources = [resourcesPath fileSystemRepresentation];
    } else {
        // Fallback: construct path from bundle path
        EmuFolders::Resources = [[coreBundle bundlePath] stringByAppendingPathComponent:@"Contents/Resources"].fileSystemRepresentation;
    }

    // Load startup settings - this populates EmuFolders::Bios and other folder paths
    // from the settings interface, and creates directories
    VMManager::Internal::LoadStartupSettings();

    PCSX2Log(@"[PCSX2] After LoadStartupSettings - EmuFolders::Bios = %s", EmuFolders::Bios.c_str());
    PCSX2Log(@"[PCSX2] EmuFolders::Resources = %s", EmuFolders::Resources.c_str());
}

- (void)startEmulation {
    [super startEmulation];

    OpenEmuBridge::g_shutdownRequested = false;
    OpenEmuBridge::g_frameReady = false;
    _emuThreadExited = false;

    // Set up audio bridge: store ring buffer reference and install the write callback
    OpenEmuBridge::g_audioBuffer = [self audioBufferAtIndex:0];
    OpenEmuBridge::g_audioWriteFunc = oeAudioWriteCallback;

    // Create Metal device for PCSX2's internal GPU rendering.
    // We use bitmap rendering (2DVideo) for display, but PCSX2 still needs Metal
    // internally. At EndPresent, the GPU frame is read back to g_videoBuffer.
    OpenEmuBridge::g_metalDevice = MTLCreateSystemDefaultDevice();
    if (OpenEmuBridge::g_metalDevice) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:PS2_WIDTH height:PS2_HEIGHT mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        desc.storageMode = MTLStorageModeShared;  // CPU-readable on Apple Silicon
        OpenEmuBridge::g_outputTexture = [OpenEmuBridge::g_metalDevice newTextureWithDescriptor:desc];
        PCSX2Log(@"[PCSX2] Created Metal device: %@", OpenEmuBridge::g_metalDevice);
        PCSX2Log(@"[PCSX2] Created Shared output texture: %@ (%dx%d)",
                 OpenEmuBridge::g_outputTexture, PS2_WIDTH, PS2_HEIGHT);
    } else {
        PCSX2Log(@"[PCSX2] WARNING: Failed to create Metal device!");
    }

    // Log diagnostic info
    PCSX2Log(@"[PCSX2] ROM path: %@", _romPath);
    PCSX2Log(@"[PCSX2] BIOS path: %s", OpenEmuBridge::g_biosPath.c_str());
    PCSX2Log(@"[PCSX2] Support path: %s", OpenEmuBridge::g_supportPath.c_str());

    // Check BIOS directory contents
    NSString *biosDir = [NSString stringWithUTF8String:OpenEmuBridge::g_biosPath.c_str()];
    NSArray *biosFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:biosDir error:nil];
    PCSX2Log(@"[PCSX2] BIOS directory contents: %@", biosFiles);

    // Spawn emulation thread
    _emuThread = std::thread([self]() {
        Threading::SetNameOfCurrentThread("PCSX2 EmuThread");

        PCSX2Log(@"[PCSX2] Emulation thread started");

        // Initialize CPU thread
        if (!VMManager::Internal::CPUThreadInitialize()) {
            PCSX2Log(@"[PCSX2] CPUThreadInitialize failed");
            return;
        }
        PCSX2Log(@"[PCSX2] CPUThreadInitialize succeeded");

        // Set up boot parameters
        VMBootParameters bootParams;
        bootParams.filename = [_romPath fileSystemRepresentation];
        // Don't set fast_boot here - let VMManager use EmuConfig.EnableFastBoot from settings

        // Initialize VM
        Error error;
        PCSX2Log(@"[PCSX2] Calling VMManager::Initialize with file: %s", bootParams.filename.c_str());
        VMBootResult result = VMManager::Initialize(bootParams, &error);
        if (result != VMBootResult::StartupSuccess) {
            PCSX2Log(@"[PCSX2] VMManager::Initialize failed: %s", error.GetDescription().c_str());
            VMManager::Internal::CPUThreadShutdown();
            return;
        }

        PCSX2Log(@"[PCSX2] VMManager::Initialize succeeded!");
        _isInitialized = YES;

        // Log which CPU implementation is active
        extern R5900cpu intCpu;
        extern R5900cpu recCpu;
        if (Cpu == &recCpu) {
            PCSX2Log(@"[PCSX2] EE CPU: ARM64 Recompiler ACTIVE");
        } else if (Cpu == &intCpu) {
            PCSX2Log(@"[PCSX2] EE CPU: Interpreter (recompiler NOT active)");
        } else {
            PCSX2Log(@"[PCSX2] EE CPU: Unknown implementation (%p)", Cpu);
        }
        PCSX2Log(@"[PCSX2] EnableEE setting: %s",
                 EmuConfig.Cpu.Recompiler.EnableEE ? "true" : "false");

        // Start running
        VMManager::SetState(VMState::Running);
        PCSX2Log(@"[PCSX2] VM state set to Running, entering main loop");

        // Main emulation loop — mirrors the Qt frontend's state machine.
        // PCSX2 internally transitions between Running/Paused/Resetting states
        // (e.g., at VSync boundaries). We must handle all of them.
        bool loopRunning = true;
        while (loopRunning && !OpenEmuBridge::g_shutdownRequested) {
            switch (VMManager::GetState()) {
                case VMState::Running:
                    VMManager::Execute();
                    break;

                case VMState::Paused:
                    // OpenEmu doesn't support pause — resume immediately
                    VMManager::SetState(VMState::Running);
                    break;

                case VMState::Resetting:
                    VMManager::Reset();
                    break;

                case VMState::Stopping:
                case VMState::Shutdown:
                    loopRunning = false;
                    break;

                default:
                    // Initializing or unknown — yield briefly
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    break;
            }
        }

        PCSX2Log(@"[PCSX2] Emulation loop exited (state=%d)", (int)VMManager::GetState());

        // Save NVM EARLY — before VMManager::Shutdown() which may hang
        // waiting for the GS thread (MTGS::WaitForClose).
        // cdvdSaveNVRAM() writes BIOS settings (date/language/etc) to disk.
        PCSX2Log(@"[PCSX2] Saving NVM early before shutdown...");
        cdvdSaveNVRAM();

        std::string nvmPath = Path::ReplaceExtension(BiosPath, "nvm");
        PCSX2Log(@"[PCSX2] NVM saved to: %s (exists: %s)",
                 nvmPath.c_str(),
                 FileSystem::FileExists(nvmPath.c_str()) ? "YES" : "NO");

        // Ensure state is Stopping before calling Shutdown
        if (VMManager::GetState() == VMState::Running) {
            VMManager::SetState(VMState::Stopping);
        }

        // Full cleanup — this may hang on MTGS::WaitForClose() if the
        // GS thread is stuck in a Metal operation, but NVM is already saved.
        PCSX2Log(@"[PCSX2] Calling VMManager::Shutdown...");
        VMManager::Shutdown(false);
        PCSX2Log(@"[PCSX2] VMManager::Shutdown complete");

        VMManager::Internal::CPUThreadShutdown();
        PCSX2Log(@"[PCSX2] CPU thread shutdown complete");
        _emuThreadExited = true;
    });
}

- (void)stopEmulation {
    PCSX2Log(@"[PCSX2] stopEmulation called");

    // Signal shutdown
    OpenEmuBridge::g_shutdownRequested = true;

    // Force the CPU to exit JIT execution ASAP.
    // recSafeExitExecution() is safe to call from any thread — it just
    // sets eeRecExitRequested=true and nextEventCycle=0 (both are one-way flags).
    // This bypasses the PumpMessagesOnCPUThread path and directly triggers
    // the JIT exit at the next block boundary.
    if (Cpu) {
        Cpu->ExitExecution();
    }

    // Disconnect audio callback to prevent writes during teardown
    OpenEmuBridge::g_audioWriteFunc = nullptr;

    // Wake up any waiting threads (frame sync CV)
    {
        std::lock_guard<std::mutex> lock(OpenEmuBridge::g_frameMutex);
        OpenEmuBridge::g_frameCV.notify_all();
    }

    // Wait for emulation thread to finish with timeout
    if (_emuThread.joinable()) {
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (!_emuThreadExited && std::chrono::steady_clock::now() < deadline) {
            // Keep waking frame sync in case GS thread is waiting
            {
                std::lock_guard<std::mutex> lock(OpenEmuBridge::g_frameMutex);
                OpenEmuBridge::g_frameCV.notify_all();
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }

        if (_emuThreadExited) {
            PCSX2Log(@"[PCSX2] Emulation thread exited cleanly, joining");
            _emuThread.join();
        } else {
            PCSX2Log(@"[PCSX2] Emulation thread did not exit in time, detaching");
            _emuThread.detach();
        }
    }

    _isInitialized = NO;

    // Clean up bridge state
    OpenEmuBridge::g_metalDevice = nil;
    OpenEmuBridge::g_outputTexture = nil;
    OpenEmuBridge::g_renderDelegate = nil;
    OpenEmuBridge::g_audioBuffer = nil;

    [super stopEmulation];
    PCSX2Log(@"[PCSX2] stopEmulation complete");
}

- (void)resetEmulation {
    if (VMManager::HasValidVM()) {
        VMManager::Reset();
    }
}

#pragma mark - Frame Execution

- (void)executeFrame {
    if (!_isInitialized) {
        return;
    }

    // Wait for the GS thread to produce a frame (readback to g_videoBuffer).
    // The GS thread signals g_frameReady after copying pixels in EndPresent.
    std::unique_lock<std::mutex> lock(OpenEmuBridge::g_frameMutex);
    OpenEmuBridge::g_frameCV.wait_for(lock, std::chrono::milliseconds(50), []{
        return OpenEmuBridge::g_frameReady.load() || OpenEmuBridge::g_shutdownRequested.load();
    });
    OpenEmuBridge::g_frameReady = false;
}

#pragma mark - Video (Bitmap readback from Metal)

- (OEGameCoreRendering)gameCoreRendering {
    return OEGameCoreRendering2DVideo;
}

- (const void *)getVideoBufferWithHint:(void *)hint {
    return OpenEmuBridge::g_videoBuffer;
}

- (OEIntSize)bufferSize {
    return OEIntSizeMake(PS2_WIDTH, PS2_HEIGHT);
}

- (OEIntSize)aspectSize {
    return OEIntSizeMake(4, 3);
}

- (OEIntRect)screenRect {
    return OEIntRectMake(0, 0, PS2_WIDTH, PS2_HEIGHT);
}

- (uint32_t)pixelFormat {
    return OEPixelFormat_BGRA; // Matches MTLPixelFormatBGRA8Unorm
}

- (uint32_t)pixelType {
    return OEPixelType_UNSIGNED_INT_8_8_8_8_REV;
}

- (NSInteger)bytesPerRow {
    return PS2_WIDTH * 4;
}

- (NSTimeInterval)frameInterval {
    return 59.94; // NTSC
}

#pragma mark - Audio

- (NSUInteger)channelCount {
    return 2;
}

- (double)audioSampleRate {
    return PS2_SAMPLERATE;
}

- (NSUInteger)audioBufferSizeForBuffer:(NSUInteger)buffer {
    // Larger buffer absorbs timing jitter from the drain thread and interpreter speed variation.
    // 200ms at 48kHz stereo int16 = 48000 * 0.2 * 2 * 2 = 38400 bytes
    return (PS2_SAMPLERATE / 5) * 2 * sizeof(int16_t);
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block {
    if (!VMManager::HasValidVM()) {
        block(NO, [NSError errorWithDomain:@"PCSX2GameCore" code:-1
                                  userInfo:@{NSLocalizedDescriptionKey: @"VM not initialized"}]);
        return;
    }

    std::string path = [fileName fileSystemRepresentation];
    VMManager::SaveState(path.c_str(), false, false, [block](const std::string &error) {
        if (error.empty()) {
            block(YES, nil);
        } else {
            block(NO, [NSError errorWithDomain:@"PCSX2GameCore" code:-2
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithUTF8String:error.c_str()]}]);
        }
    });
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block {
    if (!VMManager::HasValidVM()) {
        block(NO, [NSError errorWithDomain:@"PCSX2GameCore" code:-1
                                  userInfo:@{NSLocalizedDescriptionKey: @"VM not initialized"}]);
        return;
    }

    Error err;
    bool success = VMManager::LoadState([fileName fileSystemRepresentation], &err);
    if (success) {
        block(YES, nil);
    } else {
        block(NO, [NSError errorWithDomain:@"PCSX2GameCore" code:-3
                                  userInfo:@{NSLocalizedDescriptionKey:
                                                 [NSString stringWithUTF8String:err.GetDescription().c_str()]}]);
    }
}

#pragma mark - Input (OEPS2SystemResponderClient)

- (oneway void)didPushPS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player {
    if (player > 2 || player == 0) return;
    uint32_t idx = (uint32_t)(player - 1);

    uint32_t mapped = [self mapButton:button];
    if (mapped) {
        OpenEmuBridge::g_buttonState[idx] |= mapped;
    }

    // Handle pressure-sensitive buttons via Pad API
    if (_isInitialized) {
        int bindIndex = [self bindIndexForButton:button];
        if (bindIndex >= 0) {
            Pad::SetControllerState(idx, bindIndex, 1.0f);
        }
    }
}

- (oneway void)didReleasePS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player {
    if (player > 2 || player == 0) return;
    uint32_t idx = (uint32_t)(player - 1);

    uint32_t mapped = [self mapButton:button];
    if (mapped) {
        OpenEmuBridge::g_buttonState[idx] &= ~mapped;
    }

    if (_isInitialized) {
        int bindIndex = [self bindIndexForButton:button];
        if (bindIndex >= 0) {
            Pad::SetControllerState(idx, bindIndex, 0.0f);
        }
    }
}

- (oneway void)didMovePS2JoystickDirection:(OEPS2Button)button withValue:(CGFloat)value forPlayer:(NSUInteger)player {
    if (player > 2 || player == 0) return;
    uint32_t idx = (uint32_t)(player - 1);

    switch (button) {
        case OEPS2LeftAnalogUp:
            OpenEmuBridge::g_leftAnalogY[idx] = MAX(OpenEmuBridge::g_leftAnalogY[idx].load(), (float)value);
            break;
        case OEPS2LeftAnalogDown:
            OpenEmuBridge::g_leftAnalogY[idx] = MIN(OpenEmuBridge::g_leftAnalogY[idx].load(), -(float)value);
            break;
        case OEPS2LeftAnalogLeft:
            OpenEmuBridge::g_leftAnalogX[idx] = MIN(OpenEmuBridge::g_leftAnalogX[idx].load(), -(float)value);
            break;
        case OEPS2LeftAnalogRight:
            OpenEmuBridge::g_leftAnalogX[idx] = MAX(OpenEmuBridge::g_leftAnalogX[idx].load(), (float)value);
            break;
        case OEPS2RightAnalogUp:
            OpenEmuBridge::g_rightAnalogY[idx] = MAX(OpenEmuBridge::g_rightAnalogY[idx].load(), (float)value);
            break;
        case OEPS2RightAnalogDown:
            OpenEmuBridge::g_rightAnalogY[idx] = MIN(OpenEmuBridge::g_rightAnalogY[idx].load(), -(float)value);
            break;
        case OEPS2RightAnalogLeft:
            OpenEmuBridge::g_rightAnalogX[idx] = MIN(OpenEmuBridge::g_rightAnalogX[idx].load(), -(float)value);
            break;
        case OEPS2RightAnalogRight:
            OpenEmuBridge::g_rightAnalogX[idx] = MAX(OpenEmuBridge::g_rightAnalogX[idx].load(), (float)value);
            break;
        default:
            break;
    }

    // Reset axis when value is 0
    if (value == 0.0) {
        switch (button) {
            case OEPS2LeftAnalogUp:
            case OEPS2LeftAnalogDown:
                OpenEmuBridge::g_leftAnalogY[idx] = 0.0f;
                break;
            case OEPS2LeftAnalogLeft:
            case OEPS2LeftAnalogRight:
                OpenEmuBridge::g_leftAnalogX[idx] = 0.0f;
                break;
            case OEPS2RightAnalogUp:
            case OEPS2RightAnalogDown:
                OpenEmuBridge::g_rightAnalogY[idx] = 0.0f;
                break;
            case OEPS2RightAnalogLeft:
            case OEPS2RightAnalogRight:
                OpenEmuBridge::g_rightAnalogX[idx] = 0.0f;
                break;
            default:
                break;
        }
    }

    // Update analog via Pad API
    if (_isInitialized) {
        int bindIndex = [self bindIndexForButton:button];
        if (bindIndex >= 0) {
            Pad::SetControllerState(idx, bindIndex, (float)fabs(value));
        }
    }
}

#pragma mark - Button Mapping

- (uint32_t)mapButton:(OEPS2Button)button {
    // Bitmask mapping for quick digital button state tracking
    switch (button) {
        case OEPS2ButtonUp:        return (1 << 0);
        case OEPS2ButtonDown:      return (1 << 1);
        case OEPS2ButtonLeft:      return (1 << 2);
        case OEPS2ButtonRight:     return (1 << 3);
        case OEPS2ButtonTriangle:  return (1 << 4);
        case OEPS2ButtonCircle:    return (1 << 5);
        case OEPS2ButtonCross:     return (1 << 6);
        case OEPS2ButtonSquare:    return (1 << 7);
        case OEPS2ButtonL1:        return (1 << 8);
        case OEPS2ButtonL2:        return (1 << 9);
        case OEPS2ButtonL3:        return (1 << 10);
        case OEPS2ButtonR1:        return (1 << 11);
        case OEPS2ButtonR2:        return (1 << 12);
        case OEPS2ButtonR3:        return (1 << 13);
        case OEPS2ButtonStart:     return (1 << 14);
        case OEPS2ButtonSelect:    return (1 << 15);
        default:                   return 0;
    }
}

- (int)bindIndexForButton:(OEPS2Button)button {
    // Must match PadDualshock2::Inputs enum order exactly:
    // 0=UP, 1=RIGHT, 2=DOWN, 3=LEFT, 4=TRI, 5=CIRCLE, 6=CROSS, 7=SQUARE,
    // 8=SELECT, 9=START, 10=L1, 11=L2, 12=R1, 13=R2, 14=L3, 15=R3,
    // 16=ANALOG, 17=PRESSURE,
    // 18=L_UP, 19=L_RIGHT, 20=L_DOWN, 21=L_LEFT,
    // 22=R_UP, 23=R_RIGHT, 24=R_DOWN, 25=R_LEFT
    switch (button) {
        case OEPS2ButtonUp:        return 0;  // PAD_UP
        case OEPS2ButtonRight:     return 1;  // PAD_RIGHT
        case OEPS2ButtonDown:      return 2;  // PAD_DOWN
        case OEPS2ButtonLeft:      return 3;  // PAD_LEFT
        case OEPS2ButtonTriangle:  return 4;  // PAD_TRIANGLE
        case OEPS2ButtonCircle:    return 5;  // PAD_CIRCLE
        case OEPS2ButtonCross:     return 6;  // PAD_CROSS
        case OEPS2ButtonSquare:    return 7;  // PAD_SQUARE
        case OEPS2ButtonSelect:    return 8;  // PAD_SELECT
        case OEPS2ButtonStart:     return 9;  // PAD_START
        case OEPS2ButtonL1:        return 10; // PAD_L1
        case OEPS2ButtonL2:        return 11; // PAD_L2
        case OEPS2ButtonR1:        return 12; // PAD_R1
        case OEPS2ButtonR2:        return 13; // PAD_R2
        case OEPS2ButtonL3:        return 14; // PAD_L3
        case OEPS2ButtonR3:        return 15; // PAD_R3
        case OEPS2LeftAnalogUp:    return 18; // PAD_L_UP
        case OEPS2LeftAnalogRight: return 19; // PAD_L_RIGHT
        case OEPS2LeftAnalogDown:  return 20; // PAD_L_DOWN
        case OEPS2LeftAnalogLeft:  return 21; // PAD_L_LEFT
        case OEPS2RightAnalogUp:   return 22; // PAD_R_UP
        case OEPS2RightAnalogRight:return 23; // PAD_R_RIGHT
        case OEPS2RightAnalogDown: return 24; // PAD_R_DOWN
        case OEPS2RightAnalogLeft: return 25; // PAD_R_LEFT
        default:                   return -1;
    }
}

@end
