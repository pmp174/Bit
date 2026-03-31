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
// Peripheral device dictionary keys (matching OEGameCorePeripheralDevices.h)
#define OEPeripheralPortNameKey @"OEPeripheralPortNameKey"
#define OEPeripheralPortIdentifierKey @"OEPeripheralPortIdentifierKey"
#define OEPeripheralPortDevicesKey @"OEPeripheralPortDevicesKey"
#define OEPeripheralPortExpansionsKey @"OEPeripheralPortExpansionsKey"
#define OEPeripheralDeviceNameKey @"OEPeripheralDeviceNameKey"
#define OEPeripheralDeviceIdentifierKey @"OEPeripheralDeviceIdentifierKey"
#define OEPeripheralDeviceSelectedKey @"OEPeripheralDeviceSelectedKey"

#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>

#include "emulator.h"
#include "types.h"
#include "cfg/option.h"
#include "stdclass.h"
#include "hw/maple/maple_cfg.h"
#include "hw/maple/maple_devs.h"
#include "hw/maple/maple_if.h"
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
#include <signal.h>
#include <execinfo.h>
#define SAMPLERATE 44100
#define SIZESOUNDBUFFER (44100 / 60 * 4)

#pragma mark - Diagnostic Signal Handler

// Installed BEFORE Flycast's fault handler so that Flycast chains to us when
// it encounters a signal it can't handle. Without this, Flycast calls die()
// which invokes __builtin_trap() — crashing the XPC helper with no diagnostics.
static void oe_diagnostic_signal_handler(int sig, siginfo_t *si, void *ctx)
{
    const char *sigName = (sig == SIGSEGV) ? "SIGSEGV" :
                          (sig == SIGBUS)  ? "SIGBUS"  :
                          (sig == SIGTRAP) ? "SIGTRAP" : "UNKNOWN";

    // Use fprintf (async-signal-safe) for the critical info
    fprintf(stderr, "[Flycast] FATAL SIGNAL %s (%d) at address %p\n",
            sigName, sig, si ? si->si_addr : NULL);

    // Also try NSLog for Console.app visibility (not strictly signal-safe,
    // but the process is about to die anyway)
    NSLog(@"[Flycast] FATAL SIGNAL %s (%d) at address %p — emulator crash",
          sigName, sig, si ? si->si_addr : NULL);

    // Print a mini backtrace
    void *bt[20];
    int count = backtrace(bt, 20);
    char **syms = backtrace_symbols(bt, count);
    if (syms) {
        for (int i = 0; i < count; i++)
            fprintf(stderr, "  [%d] %s\n", i, syms[i]);
        free(syms);
    }

    // Restore default handler and re-raise to get a proper crash report
    signal(sig, SIG_DFL);
    raise(sig);
}

#pragma mark - OpenEmu Audio Backend

// Custom AudioBackend that writes samples to OpenEmu's ring buffer.
// The `wait` parameter controls frame pacing: when true, Flycast expects
// us to block until there's room, which keeps the emulation at real-time speed.
class OpenEmuAudioBackend : public AudioBackend
{
    // Recording state for microphone support (Seaman, etc.)
    AudioQueueRef recordQueue = nullptr;
    u8 recordBuffer[2400];
    static constexpr size_t RecordBufSize = sizeof(recordBuffer);
    std::atomic<int> rec_wptr{0};
    std::atomic<int> rec_rptr{0};

    static void recordCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer,
            const AudioTimeStamp *inStartTime, UInt32 frameSize, const AudioStreamPacketDescription *dataFormat)
    {
        OpenEmuAudioBackend *backend = (OpenEmuAudioBackend *)inUserData;
        UInt32 size = inBuffer->mAudioDataByteSize;
        UInt32 freeSpace = (backend->rec_rptr - backend->rec_wptr - 2 + RecordBufSize) % RecordBufSize;
        if (size > freeSpace)
            size = freeSpace;
        const u8 *src = (const u8 *)inBuffer->mAudioData;
        while (size != 0) {
            UInt32 chunk = std::min(size, (UInt32)(RecordBufSize - backend->rec_wptr));
            memcpy(backend->recordBuffer + backend->rec_wptr, src, chunk);
            backend->rec_wptr = (backend->rec_wptr + chunk) % RecordBufSize;
            src += chunk;
            size -= chunk;
        }
        AudioQueueEnqueueBuffer(backend->recordQueue, inBuffer, 0, nullptr);
    }

public:
    OpenEmuAudioBackend() : AudioBackend("openemu", "OpenEmu") {}

    bool init() override { return true; }

    u32 push(const void *data, u32 frames, bool wait) override
    {
        if (!_current) return frames;

        OERingBuffer *buf = [_current audioBufferAtIndex:0];
        u32 bytes = frames * 4; // stereo s16 = 4 bytes per frame

        // No blocking — just write what fits, drop the rest.
        // Audio pacing will be handled differently once rendering works.
        [buf write:(const uint8_t *)data maxLength:bytes];
        return frames;
    }

    void term() override {}

    bool initRecord(u32 sampling_freq) override
    {
        AudioStreamBasicDescription desc{};
        desc.mFormatID = kAudioFormatLinearPCM;
        desc.mSampleRate = (double)sampling_freq;
        desc.mChannelsPerFrame = 1;
        desc.mBitsPerChannel = 16;
        desc.mBytesPerPacket = desc.mBytesPerFrame = 2;
        desc.mFramesPerPacket = 1;
        desc.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;

        // Use the main run loop for AudioQueue callbacks. initRecord() is called
        // on the emulation thread whose run loop is only briefly serviced once per
        // frame. Passing nullptr would attach to that thread's run loop, causing
        // callbacks to never fire (starving the ring buffer) and AudioQueueStart
        // to potentially block or deadlock — freezing the app.
        OSStatus err = AudioQueueNewInput(&desc, recordCallback, this,
                                          CFRunLoopGetMain(), kCFRunLoopCommonModes, 0, &recordQueue);
        if (err != noErr) {
            NSLog(@"[Flycast] AudioQueueNewInput failed: %d", (int)err);
            return false;
        }

        AudioQueueBufferRef buffers[2];
        for (UInt32 i = 0; i < std::size(buffers) && err == noErr; i++) {
            err = AudioQueueAllocateBuffer(recordQueue, 480, &buffers[i]);
            if (err == noErr)
                err = AudioQueueEnqueueBuffer(recordQueue, buffers[i], 0, nullptr);
        }
        rec_wptr = 0;
        rec_rptr = 0;
        if (err == noErr)
            err = AudioQueueStart(recordQueue, nullptr);
        if (err != noErr) {
            NSLog(@"[Flycast] AudioQueue init failed: %d", (int)err);
            termRecord();
            return false;
        }
        NSLog(@"[Flycast] Microphone recording started at %u Hz", sampling_freq);
        return true;
    }

    u32 record(void *frame, u32 samples) override
    {
        u32 size = samples * 2;
        u32 originalSize = size;
        while (size != 0) {
            u32 avail = (rec_wptr - rec_rptr + RecordBufSize) % RecordBufSize;
            if (avail == 0)
                break;
            avail = std::min(avail, size);
            avail = std::min(avail, (u32)(RecordBufSize - rec_rptr));
            memcpy(frame, &recordBuffer[rec_rptr], avail);
            frame = (u8 *)frame + avail;
            rec_rptr = (rec_rptr + avail) % RecordBufSize;
            size -= avail;
        }
        return samples - size / 2;
    }

    void termRecord() override
    {
        if (recordQueue != nullptr) {
            AudioQueueStop(recordQueue, true);
            AudioQueueDispose(recordQueue, true);
            recordQueue = nullptr;
            NSLog(@"[Flycast] Microphone recording stopped");
        }
    }
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

@interface FlycastGameCore ()
{
    NSString *_romPath;
    int _videoWidth;
    int _videoHeight;
    BOOL _isInitialized;
    double _frameInterval;
    BOOL _needsMapleReconnect;
    BOOL _needsResetForMic;
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

    // Add ROM directory as content path so Flycast can find arcade BIOS files
    // (naomi.zip, naomi2.zip, awbios.zip) stored alongside ROMs
    if (_romPath) {
        NSString *romDir = [_romPath stringByDeletingLastPathComponent];
        add_system_data_dir(romDir.fileSystemRepresentation);
    }

    NSLog(@"[Flycast] BIOS path: %@", biosPath);
    NSLog(@"[Flycast] Support path: %@", supportPath);
    NSLog(@"[Flycast] Battery saves path: %@", savesPath);
    NSLog(@"[Flycast] ROM path: %@", _romPath);

    // Configure options before init
    config::RendererType = RenderType::OpenGL;
    config::AudioBackend.set("openemu");
    config::DynarecEnabled = true;

    // Reserve the Dreamcast virtual address space and install fault handlers
    // (normally done by flycast_init, which we bypass in OpenEmu)
    if (!addrspace::reserve()) {
        NSLog(@"[Flycast] Failed to reserve address space");
    }

    // Install our diagnostic signal handler BEFORE Flycast's. When Flycast installs
    // its handler via os_InstallFaultHandler(), it saves ours as the "next" handler.
    // If Flycast's handler can't process a fault, it chains to ours, giving us a
    // chance to log the crash details before the process dies.
    {
        struct sigaction diagAct = {};
        diagAct.sa_sigaction = oe_diagnostic_signal_handler;
        sigemptyset(&diagAct.sa_mask);
        diagAct.sa_flags = SA_SIGINFO;
        sigaction(SIGSEGV, &diagAct, nullptr);
        sigaction(SIGBUS, &diagAct, nullptr);
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
        NSLog(@"[Flycast] executeFrame: first call, initializing...");
        NSLog(@"[Flycast] ROM path: %@", _romPath);
        try {
            // Initialize the GL graphics context (registers with Flycast's renderer system)
            // OpenEmu's GL context is already current at this point
            NSLog(@"[Flycast] Calling theGLContext.init()...");
            theGLContext.init();
            NSLog(@"[Flycast] theGLContext.init() succeeded");

            NSLog(@"[Flycast] Calling emu.loadGame()...");
            emu.loadGame(_romPath.fileSystemRepresentation);
            NSLog(@"[Flycast] emu.loadGame() succeeded, platform=%d", settings.platform.system);

            // Override settings that loadGame() may have reset from saved config
            config::ThreadedRendering.override(false);  // OpenEmu drives the frame loop
            config::DynarecEnabled.override(true);      // ARM64 JIT (requires TARGET_ARM_MAC)
            NSLog(@"[Flycast] DynarecEnabled=%d, ThreadedRendering=%d",
                  (int)(bool)config::DynarecEnabled, (int)(bool)config::ThreadedRendering);

            // Initialize the OpenGL renderer (creates shaders, FBOs, etc.)
            NSLog(@"[Flycast] Calling rend_init_renderer()...");
            rend_init_renderer();
            NSLog(@"[Flycast] rend_init_renderer() succeeded");

            NSLog(@"[Flycast] Calling emu.start()...");
            emu.start();
            gui_setState(GuiState::Closed);
            _isInitialized = YES;
            NSLog(@"[Flycast] Initialization complete! display=%dx%d",
                  settings.display.width, settings.display.height);
        } catch (const std::exception &e) {
            NSLog(@"[Flycast] Error loading game: %s", e.what());
            return;
        } catch (...) {
            NSLog(@"[Flycast] Unknown error loading game");
            return;
        }
    }

    // Handle deferred peripheral reconnection on the emulation thread.
    // changePeripheralForPort: is called from the UI/XPC thread, so we defer
    // maple_ReconnectDevices() here to avoid data races with the emulation.
    if (_needsMapleReconnect) {
        _needsMapleReconnect = NO;
        maple_ReconnectDevices();

        // Most Dreamcast games that use the microphone (e.g. Seaman) only detect
        // it during their boot sequence. A reset is needed so the game re-scans
        // the maple bus and discovers the newly connected microphone.
        if (_needsResetForMic) {
            _needsResetForMic = NO;
            emu.requestReset();
        }
    }

    // Run one frame and render via OpenGL into OpenEmu's FBO
    static int frameCount = 0;
    static int consecutiveFailures = 0;
    frameCount++;

    [self.renderDelegate presentDoubleBufferedFBO];

    // Measure frame time to detect CPU timeouts (~200ms when Present() fails)
    CFAbsoluteTime frameStart = CFAbsoluteTimeGetCurrent();

    // Flycast's emu.render() can throw RendererException or FlycastException.
    // The standalone Flycast main loop (mainui.cpp) catches these; we must too,
    // otherwise the uncaught C++ exception crashes the OpenEmu XPC helper process.
    //
    // Also wrap in @try/@catch to catch Objective-C exceptions from macOS's
    // Metal-backed OpenGL layer, which don't inherit from std::exception.
    bool rendered = false;
    @try {
    try {
        rendered = emu.render();
        if (rendered) {
            consecutiveFailures = 0;
        } else {
            consecutiveFailures++;
            if (frameCount <= 50 || consecutiveFailures == 1 || consecutiveFailures == 10 || consecutiveFailures == 100) {
                CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - frameStart;
                NSLog(@"[Flycast] render() returned false at frame=%d (consecutive=%d, elapsed=%.0fms, running=%d)",
                      frameCount, consecutiveFailures, elapsed * 1000, emu.running());
            }
        }
    } catch (const RendererException& e) {
        NSLog(@"[Flycast] RendererException at frame=%d: %s", frameCount, e.what());
        // The exception sets state=Error internally. Reinitialize the renderer
        // (matching standalone Flycast mainui.cpp), then do a full reload
        // since there's no public API to clear the Error state.
        rend_term_renderer();
        rend_init_renderer();
        // Full reload: Error → (unload) → Init → (load) → Loaded → (start) → Running
        emu.unloadGame();
        try {
            emu.loadGame(_romPath.fileSystemRepresentation);
            config::ThreadedRendering.override(false);
            config::DynarecEnabled.override(true);
            emu.start();
            gui_setState(GuiState::Closed);
            NSLog(@"[Flycast] Renderer recovery: full reload succeeded");
        } catch (const std::exception& reloadErr) {
            NSLog(@"[Flycast] Renderer recovery FAILED: %s", reloadErr.what());
            _isInitialized = NO;
        }
    } catch (const FlycastException& e) {
        NSLog(@"[Flycast] FlycastException at frame=%d: %s", frameCount, e.what());
    } catch (const std::exception& e) {
        NSLog(@"[Flycast] std::exception in emu.render() frame=%d: %s", frameCount, e.what());
    } catch (...) {
        NSLog(@"[Flycast] Unknown C++ exception in emu.render() frame=%d", frameCount);
    }
    } @catch (NSException *e) {
        NSLog(@"[Flycast] NSException in emu.render() frame=%d: %@ — %@", frameCount, e.name, e.reason);
    }

    // Check for GL errors after rendering (detect silent OpenGL failures)
    if (frameCount <= 30 || consecutiveFailures == 1) {
        GLenum glErr = glGetError();
        if (glErr != GL_NO_ERROR) {
            NSLog(@"[Flycast] GL error after render at frame=%d: 0x%04X", frameCount, glErr);
            // Drain all pending errors
            while (glGetError() != GL_NO_ERROR) {}
        }
    }

    // Flush GL pipeline to ensure output is committed to OpenEmu's FBO
    if (rendered) {
        glFlush();
    }
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

- (NSUInteger)audioBufferSizeForBuffer:(NSUInteger)buffer
{
    // ~8 frames of audio at 44100 Hz (~0.13s). OEGameCore doubles this internally,
    // giving ~0.27s total — enough for scheduling jitter without perceptible lag.
    return (SAMPLERATE / 60) * 8 * 2 * 2; // 8 frames * stereo * 16-bit
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

#pragma mark - Peripheral Devices

- (NSArray<NSDictionary<NSString *, id> *> *)peripheralDevices
{
    NSMutableArray *ports = [NSMutableArray array];

    // Main device options for each maple bus port
    NSDictionary *mainDeviceNames = @{
        @(MDT_SegaController):    @"Controller",
        @(MDT_AsciiStick):        @"Arcade Stick",
        @(MDT_TwinStick):         @"Twin Stick",
        @(MDT_Keyboard):          @"Keyboard",
        @(MDT_Mouse):             @"Mouse",
        @(MDT_LightGun):          @"Light Gun",
        @(MDT_RacingController):  @"Racing Controller",
        @(MDT_FishingController): @"Fishing Controller",
        @(MDT_None):              @"None",
    };

    // Expansion device options for each sub-port
    NSDictionary *expDeviceNames = @{
        @(MDT_SegaVMU):      @"VMU",
        @(MDT_Microphone):   @"Microphone",
        @(MDT_PurupuruPack): @"Rumble Pack",
        @(MDT_None):         @"None",
    };

    for (int bus = 0; bus < 4; bus++) {
        NSString *portId = [NSString stringWithFormat:@"maple.%d", bus];
        NSString *portName = [NSString stringWithFormat:@"Port %c", 'A' + bus];

        // Build main device list
        MapleDeviceType currentMain = config::MapleMainDevices[bus];
        NSMutableArray *devices = [NSMutableArray array];
        for (NSNumber *type in mainDeviceNames) {
            [devices addObject:@{
                OEPeripheralDeviceNameKey: mainDeviceNames[type],
                OEPeripheralDeviceIdentifierKey: [NSString stringWithFormat:@"dc.main.%d", type.intValue],
                OEPeripheralDeviceSelectedKey: @(type.intValue == (int)currentMain),
            }];
        }

        // Build expansion sub-ports
        NSMutableArray *expansions = [NSMutableArray array];
        for (int exp = 0; exp < 2; exp++) {
            NSString *expPortId = [NSString stringWithFormat:@"maple.%d.exp.%d", bus, exp];
            NSString *expPortName = [NSString stringWithFormat:@"Expansion %d", exp + 1];

            MapleDeviceType currentExp = config::MapleExpansionDevices[bus][exp];
            NSMutableArray *expDevices = [NSMutableArray array];
            for (NSNumber *type in expDeviceNames) {
                [expDevices addObject:@{
                    OEPeripheralDeviceNameKey: expDeviceNames[type],
                    OEPeripheralDeviceIdentifierKey: [NSString stringWithFormat:@"dc.exp.%d", type.intValue],
                    OEPeripheralDeviceSelectedKey: @(type.intValue == (int)currentExp),
                }];
            }

            [expansions addObject:@{
                OEPeripheralPortNameKey: expPortName,
                OEPeripheralPortIdentifierKey: expPortId,
                OEPeripheralPortDevicesKey: expDevices,
            }];
        }

        [ports addObject:@{
            OEPeripheralPortNameKey: portName,
            OEPeripheralPortIdentifierKey: portId,
            OEPeripheralPortDevicesKey: devices,
            OEPeripheralPortExpansionsKey: expansions,
        }];
    }

    return ports;
}

- (void)changePeripheralForPort:(NSString *)portIdentifier toDevice:(NSString *)deviceIdentifier
{
    if ([portIdentifier isEqualToString:@"__reset__"]) {
        // Reset all to defaults: Port A = Controller + 2 VMUs, Ports B-D = None
        config::MapleMainDevices[0].set(MDT_SegaController);
        config::MapleExpansionDevices[0][0].set(MDT_SegaVMU);
        config::MapleExpansionDevices[0][1].set(MDT_SegaVMU);
        for (int i = 1; i < 4; i++) {
            config::MapleMainDevices[i].set(MDT_None);
            config::MapleExpansionDevices[i][0].set(MDT_None);
            config::MapleExpansionDevices[i][1].set(MDT_None);
        }
        _needsMapleReconnect = YES;
        return;
    }

    // Parse device type from identifier "dc.main.N" or "dc.exp.N"
    int deviceType = [[deviceIdentifier componentsSeparatedByString:@"."].lastObject intValue];

    // Parse port identifier "maple.B" or "maple.B.exp.E"
    NSArray *parts = [portIdentifier componentsSeparatedByString:@"."];
    int bus = [parts[1] intValue];

    if (parts.count == 2) {
        // Main device: "maple.B"
        config::MapleMainDevices[bus].set((MapleDeviceType)deviceType);
    } else if (parts.count == 4) {
        // Expansion device: "maple.B.exp.E"
        int exp = [parts[3] intValue];
        MapleDeviceType previousType = config::MapleExpansionDevices[bus][exp];
        config::MapleExpansionDevices[bus][exp].set((MapleDeviceType)deviceType);

        // Track if a microphone was added or removed — games need a reset to detect it
        if (deviceType == MDT_Microphone || previousType == MDT_Microphone) {
            _needsResetForMic = YES;
        }
    }

    // Defer reconnection to the emulation thread (next executeFrame call)
    // to avoid data races with the emulation accessing maple device state.
    _needsMapleReconnect = YES;
}

#pragma mark - Arcade Input (Naomi / Naomi 2 / Atomiswave)

// Arcade buttons map to DC_BTN_* constants in kcode[].
// Flycast's JVS layer (maple_jvs.cpp naomi_button_mapping[]) remaps these
// to the appropriate NAOMI_*_KEY / AWAVE_*_KEY values internally.

- (oneway void)didMoveArcadeJoystickDirection:(OEArcadeButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    switch (button) {
        case OEArcadeAnalogUp:
            joyy[player] = value * -32768;
            break;
        case OEArcadeAnalogDown:
            joyy[player] = value * 32767;
            break;
        case OEArcadeAnalogLeft:
            joyx[player] = value * -32768;
            break;
        case OEArcadeAnalogRight:
            joyx[player] = value * 32767;
            break;
        default:
            break;
    }
}

- (oneway void)didPushArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    switch (button) {
        case OEArcadeButtonUp:
            kcode[player] &= ~DC_DPAD_UP;
            break;
        case OEArcadeButtonDown:
            kcode[player] &= ~DC_DPAD_DOWN;
            break;
        case OEArcadeButtonLeft:
            kcode[player] &= ~DC_DPAD_LEFT;
            break;
        case OEArcadeButtonRight:
            kcode[player] &= ~DC_DPAD_RIGHT;
            break;
        case OEArcadeButton1:
            kcode[player] &= ~DC_BTN_A;
            break;
        case OEArcadeButton2:
            kcode[player] &= ~DC_BTN_B;
            break;
        case OEArcadeButton3:
            kcode[player] &= ~DC_BTN_C;
            break;
        case OEArcadeButton4:
            kcode[player] &= ~DC_BTN_X;
            break;
        case OEArcadeButton5:
            kcode[player] &= ~DC_BTN_Y;
            break;
        case OEArcadeButton6:
            kcode[player] &= ~DC_BTN_Z;
            break;
        case OEArcadeButtonP1Start:
            kcode[player] &= ~DC_BTN_START;
            break;
        case OEArcadeButtonInsertCoin:
            kcode[player] &= ~DC_BTN_D;
            break;
        case OEArcadeButtonService:
            kcode[player] &= ~DC_DPAD2_UP;
            break;
        case OEArcadeUIConfigure:
            kcode[player] &= ~DC_DPAD2_DOWN;
            break;
        default:
            break;
    }
}

- (oneway void)didReleaseArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    player -= 1;
    if (player > 3) return;

    switch (button) {
        case OEArcadeButtonUp:
            kcode[player] |= DC_DPAD_UP;
            break;
        case OEArcadeButtonDown:
            kcode[player] |= DC_DPAD_DOWN;
            break;
        case OEArcadeButtonLeft:
            kcode[player] |= DC_DPAD_LEFT;
            break;
        case OEArcadeButtonRight:
            kcode[player] |= DC_DPAD_RIGHT;
            break;
        case OEArcadeButton1:
            kcode[player] |= DC_BTN_A;
            break;
        case OEArcadeButton2:
            kcode[player] |= DC_BTN_B;
            break;
        case OEArcadeButton3:
            kcode[player] |= DC_BTN_C;
            break;
        case OEArcadeButton4:
            kcode[player] |= DC_BTN_X;
            break;
        case OEArcadeButton5:
            kcode[player] |= DC_BTN_Y;
            break;
        case OEArcadeButton6:
            kcode[player] |= DC_BTN_Z;
            break;
        case OEArcadeButtonP1Start:
            kcode[player] |= DC_BTN_START;
            break;
        case OEArcadeButtonInsertCoin:
            kcode[player] |= DC_BTN_D;
            break;
        case OEArcadeButtonService:
            kcode[player] |= DC_DPAD2_UP;
            break;
        case OEArcadeUIConfigure:
            kcode[player] |= DC_DPAD2_DOWN;
            break;
        default:
            break;
    }
}

@end
