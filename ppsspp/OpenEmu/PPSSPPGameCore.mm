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
#import "PPSSPPGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEGameCore.h>
#import <OpenGL/gl3.h>

// Prevent GLEW from being included (conflicts with macOS OpenGL headers)
#define __glew_h__
#define __GLEW_H__

// PPSSPP headers
#include "Common/System/System.h"
#include "Common/System/NativeApp.h"
#include "Common/File/VFS/VFS.h"
#include "Common/File/VFS/DirectoryReader.h"
#include "Common/File/FileUtil.h"
#include "Common/GraphicsContext.h"
#include "Common/TimeUtil.h"
#include "Common/Thread/ThreadUtil.h"
#include "Common/Log.h"
#include "Common/Log/LogManager.h"
#include "Common/CPUDetect.h"
#include "Common/Thread/ThreadManager.h"

#include "Core/Config.h"
#include "Core/ConfigValues.h"
#include "Core/Core.h"
#include "Core/CoreParameter.h"
#include "Core/System.h"
#include "Core/HLE/sceCtrl.h"
#include "Core/HLE/sceUtility.h"
#include "Core/MemMap.h"
#include "Core/SaveState.h"

#include "GPU/GPUState.h"
#include "GPU/GPU.h"
#include "GPU/Common/GPUDebugInterface.h"

#include <sys/stat.h>
#include <signal.h>

#define SAMPLERATE 44100
#define NATIVEWIDTH 480
#define NATIVEHEIGHT 272

__weak PPSSPPGameCore *_current = nil;

#pragma mark - OpenEmu Graphics Context

// Minimal GraphicsContext implementation for software rendering
class OpenEmuGraphicsContext : public GraphicsContext {
public:
    OpenEmuGraphicsContext() {}
    ~OpenEmuGraphicsContext() override { Shutdown(); }

    bool Init() { return true; }
    void Shutdown() override {}
    void Resize() override {}

    Draw::DrawContext *GetDrawContext() override { return nullptr; }
};

static OpenEmuGraphicsContext *g_graphicsContext = nullptr;

#pragma mark - Button state

static uint32_t g_buttonState = 0;
static float g_analogX = 0.0f;
static float g_analogY = 0.0f;

#pragma mark - Video buffer for software rendering

static uint32_t g_videoBuffer[NATIVEWIDTH * NATIVEHEIGHT];

#pragma mark - System_ callback implementations

// These functions are required by PPSSPP's platform abstraction layer.
// Every platform that hosts PPSSPP must implement them.

void System_Toast(std::string_view text) {
    NSLog(@"[PPSSPP] Toast: %s", std::string(text).c_str());
}

void System_ShowKeyboard() {}

void System_Vibrate(int length_ms) {}

void System_LaunchUrl(LaunchUrlType urlType, std::string_view url) {}

void System_RunOnMainThread(std::function<void()> func) {
    dispatch_async(dispatch_get_main_queue(), [func]() {
        func();
    });
}

bool System_MakeRequest(SystemRequestType type, int requestId, const std::string &param1, const std::string &param2, int64_t param3, int64_t param4) {
    return false;
}

PermissionStatus System_GetPermissionStatus(SystemPermission permission) {
    return PERMISSION_STATUS_GRANTED;
}

void System_AskForPermission(SystemPermission permission) {}

std::string System_GetProperty(SystemProperty prop) {
    switch (prop) {
        case SYSPROP_NAME:
            return "OpenEmu";
        case SYSPROP_LANGREGION:
            return "en_US";
        default:
            return "";
    }
}

std::vector<std::string> System_GetPropertyStringVec(SystemProperty prop) {
    return std::vector<std::string>();
}

int64_t System_GetPropertyInt(SystemProperty prop) {
    switch (prop) {
        case SYSPROP_AUDIO_SAMPLE_RATE:
            return SAMPLERATE;
        case SYSPROP_DISPLAY_REFRESH_RATE:
            return 60;
        case SYSPROP_DEVICE_TYPE:
            return DEVICE_TYPE_DESKTOP;
        case SYSPROP_DISPLAY_XRES:
            return NATIVEWIDTH;
        case SYSPROP_DISPLAY_YRES:
            return NATIVEHEIGHT;
        default:
            return 0;
    }
}

float System_GetPropertyFloat(SystemProperty prop) {
    switch (prop) {
        case SYSPROP_DISPLAY_REFRESH_RATE:
            return 60.0f / 1.001f;
        default:
            return 0.0f;
    }
}

bool System_GetPropertyBool(SystemProperty prop) {
    switch (prop) {
        case SYSPROP_CAN_JIT:
            return true;
        case SYSPROP_HAS_BACK_BUTTON:
            return false;
        case SYSPROP_HAS_KEYBOARD:
            return false;
        default:
            return false;
    }
}

void System_Notify(SystemNotification notification) {}

void System_PostUIMessage(UIMessage message, std::string_view param) {}

std::vector<std::string> System_GetCameraDeviceList() {
    return std::vector<std::string>();
}

bool System_AudioRecordingIsAvailable() { return false; }
bool System_AudioRecordingState() { return false; }

void System_AudioGetDebugStats(char *buf, size_t bufSize) {
    if (buf) buf[0] = '\0';
}

void System_AudioClear() {}

void System_AudioPushSamples(const int32_t *audio, int numSamples, float volume) {
    if (!_current) return;

    // Convert 32-bit samples to 16-bit and write to OpenEmu's ring buffer
    int16_t buffer[1024 * 2];
    int remaining = numSamples;
    const int32_t *src = audio;

    OERingBuffer *ringBuffer = [_current audioBufferAtIndex:0];

    while (remaining > 0) {
        int blockSize = std::min(1024, remaining);
        for (int i = 0; i < blockSize * 2; i++) {
            int32_t sample = (int32_t)(src[i] * volume);
            if (sample < -32767) sample = -32767;
            if (sample > 32767) sample = 32767;
            buffer[i] = (int16_t)sample;
        }
        [ringBuffer write:(const uint8_t *)buffer maxLength:blockSize * 2 * sizeof(int16_t)];
        src += blockSize * 2;
        remaining -= blockSize;
    }
}

// Required by PPSSPP but not used in our context
void NativeFrame(GraphicsContext *graphicsContext) {}
void NativeResized() {}
bool NativeSaveSecret(std::string_view nameOfSecret, std::string_view data) { return false; }
std::string NativeLoadSecret(std::string_view nameOfSecret) { return ""; }

#pragma mark - PPSSPPGameCore Implementation

@implementation PPSSPPGameCore {
    NSString *_romPath;
    BOOL _isInitialized;
    BOOL _pendingBoot;
}

- (id)init {
    if (self = [super init]) {
        _current = self;
        _isInitialized = NO;
        _pendingBoot = NO;
    }
    return self;
}

- (void)dealloc {
    if (_current == self) {
        _current = nil;
    }
}

#pragma mark - Lifecycle

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error {
    _romPath = [path copy];
    return YES;
}

- (void)setupEmulation {
    // Initialize timing
    TimeInit();
    SetCurrentThreadName("Main");

    // Set up logging
    g_logManager.Init(&g_Config.bEnableLogging);

    // Set up directories
    NSString *supportPath = [self supportDirectoryPath];
    NSString *savesPath = [self batterySavesDirectoryPath];
    NSString *biosPath = [self biosDirectoryPath];

    // Create directories if needed
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:supportPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];

    // Configure PPSSPP paths
    g_Config.memStickDirectory = Path(supportPath.fileSystemRepresentation);
    g_Config.flash0Directory = Path(std::string(supportPath.fileSystemRepresentation) + "/flash0");
    g_Config.internalDataDirectory = Path(supportPath.fileSystemRepresentation);

    // Load configuration
    g_Config.Load("");

    // Override key settings for OpenEmu integration
    g_Config.bEnableSound = true;
    g_Config.iCpuCore = (int)CPUCore::JIT;
    g_Config.iGPUBackend = (int)GPUBackend::OPENGL;
    g_Config.bSoftwareRendering = true;  // Use software rendering for simplicity
    g_Config.bVertexDecoderJit = true;
    g_Config.iInternalResolution = 1;  // Native resolution
    g_Config.bAutoFrameSkip = false;
    g_Config.iFrameSkip = 0;
    g_Config.bEnableLogging = false;
    g_Config.iLanguage = PSP_SYSTEMPARAM_LANGUAGE_ENGLISH;

    // Initialize thread manager (required by software renderer's BinManager)
    g_threadManager.Init(cpu_info.num_cores, cpu_info.logical_cpu_count);

    // Create system directories
    CreateSysDirectories();

    // Register VFS for assets
    g_VFS.Register("", new DirectoryReader(Path(std::string(supportPath.fileSystemRepresentation) + "/assets")));
}

- (void)startEmulation {
    [super startEmulation];
}

- (void)stopEmulation {
    PSP_Shutdown(true);

    if (g_graphicsContext) {
        g_graphicsContext->Shutdown();
        delete g_graphicsContext;
        g_graphicsContext = nullptr;
    }

    g_VFS.Clear();

    [super stopEmulation];
}

- (void)resetEmulation {
    if (PSP_IsInited()) {
        PSP_Shutdown(true);

        std::string error;
        if (PSP_Init(PSP_CoreParameter(), &error) != BootState::Complete) {
            NSLog(@"[PPSSPP] Reset failed: %s", error.c_str());
        }
    }
}

#pragma mark - Frame Execution

- (void)executeFrame {
    if (!_isInitialized) {
        [self initializeEmulator];
        return;
    }

    if (_pendingBoot) {
        std::string error;
        BootState state = PSP_InitUpdate(&error);

        switch (state) {
            case BootState::Booting:
                // Still booting, try again next frame
                return;
            case BootState::Failed:
                NSLog(@"[PPSSPP] Boot failed: %s", error.c_str());
                _pendingBoot = NO;
                return;
            case BootState::Complete:
                _pendingBoot = NO;
                coreState = CORE_RUNNING_CPU;
                break;
            default:
                return;
        }
    }

    // Update input state
    __CtrlUpdateButtons(g_buttonState, ~g_buttonState & 0xFFFF);
    __CtrlSetAnalogXY(CTRL_STICK_LEFT, g_analogX, g_analogY);

    // Run one frame of emulation
    PSP_RunLoopWhileState();

    // Handle frame boundary
    switch (coreState) {
        case CORE_NEXTFRAME:
        case CORE_POWERDOWN:
            coreState = CORE_RUNNING_CPU;
            break;
        default:
            break;
    }

    // Get the software-rendered framebuffer
    if (gpuDebug) {
        GPUDebugBuffer buf;
        if (gpuDebug->GetOutputFramebuffer(buf)) {
            int stride = buf.GetStride();
            int h = std::min((int)buf.GetHeight(), NATIVEHEIGHT);
            int w = std::min(stride, NATIVEWIDTH);
            const u32 *src = (const u32 *)buf.GetData();
            if (src) {
                for (int y = 0; y < h; y++) {
                    memcpy(g_videoBuffer + y * NATIVEWIDTH, src + y * stride, w * sizeof(u32));
                }
            }
        }
    }
}

- (void)initializeEmulator {
    // Create graphics context for software rendering
    g_graphicsContext = new OpenEmuGraphicsContext();
    g_graphicsContext->Init();

    Core_SetGraphicsContext(g_graphicsContext);
    SetGPUBackend(GPUBackend::OPENGL);

    // Set up CoreParameter
    CoreParameter coreParam = {};
    coreParam.enableSound = true;
    coreParam.fileToStart = Path(_romPath.fileSystemRepresentation);
    coreParam.startBreak = false;
    coreParam.headLess = true;
    coreParam.graphicsContext = g_graphicsContext;
    coreParam.gpuCore = GPUCORE_SOFTWARE;
    coreParam.cpuCore = (CPUCore)g_Config.iCpuCore;
    coreParam.renderScaleFactor = 1;
    coreParam.renderWidth = NATIVEWIDTH;
    coreParam.renderHeight = NATIVEHEIGHT;
    coreParam.pixelWidth = NATIVEWIDTH;
    coreParam.pixelHeight = NATIVEHEIGHT;

    // Start boot process (non-blocking)
    if (!PSP_InitStart(coreParam)) {
        NSLog(@"[PPSSPP] PSP_InitStart failed: %s", coreParam.errorString.c_str());
        return;
    }

    _isInitialized = YES;
    _pendingBoot = YES;
}

#pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering {
    return OEGameCoreRendering2DVideo;
}

- (OEIntSize)bufferSize {
    return OEIntSizeMake(NATIVEWIDTH, NATIVEHEIGHT);
}

- (OEIntSize)aspectSize {
    return OEIntSizeMake(480, 272);
}

- (OEIntRect)screenRect {
    return OEIntRectMake(0, 0, NATIVEWIDTH, NATIVEHEIGHT);
}

- (NSTimeInterval)frameInterval {
    return 60.0 / 1.001;
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    return g_videoBuffer;
}

- (GLenum)pixelFormat {
    return GL_RGBA;
}

- (GLenum)pixelType {
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (NSUInteger)bytesPerRow {
    return NATIVEWIDTH * 4;
}

#pragma mark - Audio

- (NSUInteger)channelCount {
    return 2;
}

- (double)audioSampleRate {
    return SAMPLERATE;
}

- (NSUInteger)audioBufferSizeForBuffer:(NSUInteger)buffer {
    return (SAMPLERATE / 60) * 8 * 2 * 2;
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block {
    if (!PSP_IsInited()) {
        block(NO, [NSError errorWithDomain:@"PPSSPPGameCore" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"PSP not initialized"}]);
        return;
    }

    std::vector<u8> stateData;
    CChunkFileReader::Error err = SaveState::SaveToRam(stateData);
    if (err == CChunkFileReader::ERROR_NONE && !stateData.empty()) {
        NSData *saveData = [NSData dataWithBytes:stateData.data() length:stateData.size()];
        BOOL success = [saveData writeToFile:fileName atomically:YES];
        block(success, success ? nil : [NSError errorWithDomain:@"PPSSPPGameCore" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write save state"}]);
    } else {
        block(NO, [NSError errorWithDomain:@"PPSSPPGameCore" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to serialize state"}]);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block {
    if (!PSP_IsInited()) {
        block(NO, [NSError errorWithDomain:@"PPSSPPGameCore" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"PSP not initialized"}]);
        return;
    }

    NSData *saveData = [NSData dataWithContentsOfFile:fileName];
    if (!saveData) {
        block(NO, [NSError errorWithDomain:@"PPSSPPGameCore" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read save state file"}]);
        return;
    }

    std::vector<u8> buffer((const u8 *)saveData.bytes, (const u8 *)saveData.bytes + saveData.length);
    std::string errorString;
    CChunkFileReader::Error err = SaveState::LoadFromRam(buffer, &errorString);
    block(err == CChunkFileReader::ERROR_NONE, err == CChunkFileReader::ERROR_NONE ? nil : [NSError errorWithDomain:@"PPSSPPGameCore" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"Failed to load save state"}]);
}

#pragma mark - Input (OEPSPSystemResponderClient)

- (oneway void)didPushPSPButton:(OEPSPButton)button forPlayer:(NSUInteger)player {
    uint32_t mapped = [self mapButton:button];
    if (mapped) {
        g_buttonState |= mapped;
    }
}

- (oneway void)didReleasePSPButton:(OEPSPButton)button forPlayer:(NSUInteger)player {
    uint32_t mapped = [self mapButton:button];
    if (mapped) {
        g_buttonState &= ~mapped;
    }
}

- (oneway void)didMovePSPJoystickDirection:(OEPSPButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player {
    switch (button) {
        case OEPSPAnalogUp:
            g_analogY = MAX(g_analogY, (float)value);
            break;
        case OEPSPAnalogDown:
            g_analogY = MIN(g_analogY, -(float)value);
            break;
        case OEPSPAnalogLeft:
            g_analogX = MIN(g_analogX, -(float)value);
            break;
        case OEPSPAnalogRight:
            g_analogX = MAX(g_analogX, (float)value);
            break;
        default:
            break;
    }

    // Reset axis when value is 0
    if (value == 0.0) {
        if (button == OEPSPAnalogUp || button == OEPSPAnalogDown) {
            g_analogY = 0.0f;
        }
        if (button == OEPSPAnalogLeft || button == OEPSPAnalogRight) {
            g_analogX = 0.0f;
        }
    }
}

- (uint32_t)mapButton:(OEPSPButton)button {
    switch (button) {
        case OEPSPButtonUp:       return CTRL_UP;
        case OEPSPButtonDown:     return CTRL_DOWN;
        case OEPSPButtonLeft:     return CTRL_LEFT;
        case OEPSPButtonRight:    return CTRL_RIGHT;
        case OEPSPButtonTriangle: return CTRL_TRIANGLE;
        case OEPSPButtonCircle:   return CTRL_CIRCLE;
        case OEPSPButtonCross:    return CTRL_CROSS;
        case OEPSPButtonSquare:   return CTRL_SQUARE;
        case OEPSPButtonL1:       return CTRL_LTRIGGER;
        case OEPSPButtonR1:       return CTRL_RTRIGGER;
        case OEPSPButtonStart:    return CTRL_START;
        case OEPSPButtonSelect:   return CTRL_SELECT;
        default:                  return 0;
    }
}

@end
