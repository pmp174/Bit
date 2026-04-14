/*
 Copyright (c) 2024, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "XEMUGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>

#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

// Diagnostic logging
#define XEMULog(fmt, ...) NSLog(@"[XEMU] " fmt, ##__VA_ARGS__)

static void xemuLogToFile(const char *fmt, ...) {
    static FILE *logFile = NULL;
    if (!logFile) {
        logFile = fopen("/tmp/xemu_openemu.log", "a");
    }
    if (logFile) {
        va_list args;
        va_start(args, fmt);
        vfprintf(logFile, fmt, args);
        va_end(args);
        fprintf(logFile, "\n");
        fflush(logFile);
    }
}

// Xbox video output dimensions
#define XBOX_WIDTH  640
#define XBOX_HEIGHT 480
#define XBOX_SAMPLERATE 48000

// Forward declarations for xemu/QEMU C functions
#ifdef __cplusplus
extern "C" {
#endif

// QEMU core lifecycle
void qemu_init(int argc, char **argv);
int  qemu_main_loop(void);
void qemu_cleanup(void);
void qemu_system_shutdown_request(int reason);

// Shutdown diagnostics
int qemu_shutdown_requested_get(void);
int qemu_reset_requested_get(void);

// NV2A GL context initialization (creates SDL GL contexts for the renderer)
void nv2a_context_init(void);

// xemu display bridge (implemented in xemu_openemu_display.c)
void xemu_openemu_display_init(void);
void xemu_openemu_display_register(void);  // call after qemu_init
void xemu_openemu_render_frame(uint32_t *buffer, int width, int height);

// xemu input bridge (implemented in XEMUHost.c)
void xemu_openemu_input_init(void);
void xemu_openemu_update_buttons(int port, uint16_t buttons);
void xemu_openemu_update_axis(int port, int axis_index, int16_t value);

// xemu audio bridge
void xemu_openemu_audio_set_callback(void (*callback)(const void *buf, size_t len));

// Real config struct from xemu build (must match actual g_config layout)
#include "xemu-config.h"

extern struct config g_config;

// Settings initialization (populates g_config with defaults — all strings
// become empty strings, not NULL, which prevents strlen(NULL) crashes)
bool xemu_settings_load(void);
void xemu_settings_set_path(const char *path);

static inline void xemu_settings_set_string_oe(const char **str, const char *new_str)
{
    free((char *)*str);
    *str = strdup(new_str);
}

#ifdef __cplusplus
}
#endif

// ============================================================================
// OpenEmuXboxBridge — shared state between ObjC and C/C++ worlds
// ============================================================================
namespace OpenEmuXboxBridge {
    // Audio
    OERingBuffer *g_audioBuffer = nil;

    // Video buffer (BGRA8, 640x480)
    uint32_t g_videoBuffer[XBOX_WIDTH * XBOX_HEIGHT] = {};

    // Input state per player (4 players)
    std::atomic<uint16_t> g_buttonState[4] = {};
    std::atomic<int16_t>  g_axisState[4][6] = {}; // 6 axes per controller

    // Frame synchronization
    std::mutex g_frameMutex;
    std::condition_variable g_frameCV;
    std::atomic<bool> g_frameReady{false};

    // Lifecycle
    std::atomic<bool> g_shutdownRequested{false};
    std::atomic<bool> g_initialized{false};

    // Paths
    std::string g_biosPath;
    std::string g_supportPath;
    std::string g_romPath;
}

// Audio callback invoked by QEMU audio backend
static void oeAudioWriteCallback(const void *buf, size_t len) {
    if (OpenEmuXboxBridge::g_audioBuffer) {
        [OpenEmuXboxBridge::g_audioBuffer write:buf maxLength:len];
    }
}

// Frame ready callback invoked by display backend
extern "C" void xemu_openemu_frame_ready(const uint32_t *pixels, int width, int height) {
    if (!pixels || width <= 0 || height <= 0) return;

    size_t copyW = (width  < XBOX_WIDTH)  ? width  : XBOX_WIDTH;
    size_t copyH = (height < XBOX_HEIGHT) ? height : XBOX_HEIGHT;

    // Copy framebuffer to shared video buffer
    for (size_t y = 0; y < copyH; y++) {
        memcpy(&OpenEmuXboxBridge::g_videoBuffer[y * XBOX_WIDTH],
               &pixels[y * width],
               copyW * sizeof(uint32_t));
    }

    // Signal frame ready
    {
        std::lock_guard<std::mutex> lock(OpenEmuXboxBridge::g_frameMutex);
        OpenEmuXboxBridge::g_frameReady = true;
    }
    OpenEmuXboxBridge::g_frameCV.notify_one();
}

// ============================================================================
// XEMUGameCore implementation
// ============================================================================

@implementation XEMUGameCore {
    NSString *_romPath;
    BOOL _isInitialized;
    std::thread _emuThread;
    std::atomic<bool> _emuThreadExited;
}

static __unsafe_unretained XEMUGameCore *_current;

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _isInitialized = NO;
        _emuThreadExited = false;
        _current = self;
    }
    return self;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error {
    XEMULog(@"loadFileAtPath: %@", path);
    _romPath = [path copy];
    return YES;
}

- (void)setupEmulation {
    XEMULog(@"setupEmulation");

    // Store paths
    NSString *supportPath = [self supportDirectoryPath];
    NSString *biosPath = [self biosDirectoryPath];

    OpenEmuXboxBridge::g_biosPath = [biosPath fileSystemRepresentation];
    OpenEmuXboxBridge::g_supportPath = [supportPath fileSystemRepresentation];
    OpenEmuXboxBridge::g_romPath = [_romPath fileSystemRepresentation];

    // Create support subdirectories
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:supportPath withIntermediateDirectories:YES attributes:nil error:nil];

    // Point xemu settings at our support directory so it doesn't touch ~/.local
    NSString *settingsPath = [supportPath stringByAppendingPathComponent:@"xemu.toml"];
    xemu_settings_set_path([settingsPath fileSystemRepresentation]);

    // Initialize g_config with defaults — all string fields become "" (not NULL).
    // This is CRITICAL: vl.c calls strlen() on these fields and will crash on NULL.
    xemu_settings_load();

    // Auto-create HDD image with FATX partition headers if missing or blank
    NSString *hddPath = [supportPath stringByAppendingPathComponent:@"xbox_hdd.img"];
    NSDictionary *hddAttrs = [fm attributesOfItemAtPath:hddPath error:nil];
    unsigned long long hddSize = [hddAttrs fileSize];

    // Check if the image needs formatting (missing, empty, or no FATX signature)
    bool needsFormat = false;
    if (![fm fileExistsAtPath:hddPath] || hddSize == 0) {
        needsFormat = true;
    } else {
        // Check for FATX signature at first partition offset
        int checkFd = open([hddPath fileSystemRepresentation], O_RDONLY);
        if (checkFd >= 0) {
            uint32_t sig = 0;
            // First data partition at 0x80000
            if (pread(checkFd, &sig, 4, 0x80000) == 4) {
                needsFormat = (sig != 0x58544146); // "FATX" little-endian
            } else {
                needsFormat = true;
            }
            close(checkFd);
        }
    }

    if (needsFormat) {
        XEMULog(@"Creating formatted Xbox HDD image at %@", hddPath);
        const off_t imgSize = (off_t)8 * 1024 * 1024 * 1024;
        int fd = open([hddPath fileSystemRepresentation], O_CREAT | O_RDWR | O_TRUNC, 0644);
        if (fd >= 0) {
            // Create 8GB sparse file
            ftruncate(fd, imgSize);

            // Standard Xbox HDD partition layout (from Xbox kernel).
            // The Xbox kernel reads these at fixed LBA offsets × 512 bytes/sector.
            // Partitions 0-2 are cache, 3 is C: (system), 4 is E: (data), 5 is F:.
            struct { off_t offset; off_t size; } partitions[] = {
                { 0x00080000LL,  0x2ee00000LL },  // Partition 0: X: Cache 0 (750MB)
                { 0x2ee80000LL,  0x2ee00000LL },  // Partition 1: Y: Cache 1 (750MB)
                { 0x5dd00000LL,  0x2ee00000LL },  // Partition 2: Z: Cache 2 (750MB)
                { 0x8cb80000LL,  0x1f400000LL },  // Partition 3: C: System (500MB)
                { 0xabe80000LL,  0x131260000LL },  // Partition 4: E: Data (~4.8GB for 8GB drive)
            };

            // Write FATX superblock at each partition start
            for (int i = 0; i < 5; i++) {
                // FATX superblock: 4096 bytes
                uint8_t superblock[4096];
                memset(superblock, 0xFF, sizeof(superblock));

                // Signature: "FATX"
                uint32_t fatx_sig = 0x58544146;
                memcpy(superblock + 0, &fatx_sig, 4);

                // Volume ID (random)
                uint32_t vol_id = (uint32_t)(arc4random());
                memcpy(superblock + 4, &vol_id, 4);

                // Sectors per cluster: 32 for large partitions, 4 for small
                uint32_t spc = (partitions[i].size > 0x20000000) ? 32 : 4;
                memcpy(superblock + 8, &spc, 4);

                // Root cluster: 1
                uint32_t root = 1;
                memcpy(superblock + 12, &root, 4);

                // Unknown field: 0
                uint16_t unk = 0;
                memcpy(superblock + 16, &unk, 2);

                pwrite(fd, superblock, sizeof(superblock), partitions[i].offset);

                // Write initial FAT entry (end-of-chain marker)
                uint32_t fat_entry = 0xFFFFFFF8;
                pwrite(fd, &fat_entry, 4, partitions[i].offset + 4096);
            }

            close(fd);
            XEMULog(@"Created 8GB formatted Xbox HDD image with FATX partitions");
        }
    }

    // Find MCPX Boot ROM (search common filenames)
    NSArray *mcpxNames = @[@"mcpx_1.0.bin", @"mcpx-1.0.bin", @"mcpx-1.1.bin"];
    NSString *bootromPath = nil;
    for (NSString *name in mcpxNames) {
        NSString *path = [biosPath stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:path]) {
            bootromPath = path;
            break;
        }
    }
    if (!bootromPath) {
        bootromPath = [biosPath stringByAppendingPathComponent:@"mcpx_1.0.bin"];
        XEMULog(@"WARNING: No MCPX Boot ROM found in BIOS directory");
    }

    // Find Xbox Flash ROM / BIOS (search common filenames)
    NSArray *biosNames = @[@"xbox_bios.bin", @"Complex_4627v1.03.bin", @"cerbios.bin",
                           @"xbox-3944.bin", @"xbox-4034.bin", @"xbox-4817.bin",
                           @"xbox-5101.bin", @"xbox-5530.bin", @"xbox-5713.bin",
                           @"xbox-5838.bin"];
    NSString *flashromPath = nil;
    for (NSString *name in biosNames) {
        NSString *path = [biosPath stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:path]) {
            flashromPath = path;
            break;
        }
    }
    if (!flashromPath) {
        flashromPath = [biosPath stringByAppendingPathComponent:@"xbox_bios.bin"];
        XEMULog(@"WARNING: No Xbox Flash ROM found in BIOS directory");
    }

    // Set paths in g_config using the REAL struct layout.
    // vl.c reads these to construct its own argv for QEMU initialization.
    xemu_settings_set_string_oe(&g_config.sys.files.bootrom_path, [bootromPath fileSystemRepresentation]);
    xemu_settings_set_string_oe(&g_config.sys.files.flashrom_path, [flashromPath fileSystemRepresentation]);
    xemu_settings_set_string_oe(&g_config.sys.files.hdd_path, [hddPath fileSystemRepresentation]);
    xemu_settings_set_string_oe(&g_config.sys.files.dvd_path, [_romPath fileSystemRepresentation]);

    // Set EEPROM path — vl.c's get_eeprom_path() will auto-generate if missing
    NSString *eepromPath = [supportPath stringByAppendingPathComponent:@"eeprom.bin"];
    xemu_settings_set_string_oe(&g_config.sys.files.eeprom_path, [eepromPath fileSystemRepresentation]);

    g_config.sys.avpack = CONFIG_SYS_AVPACK_HDTV;
    g_config.sys.mem_limit = CONFIG_SYS_MEM_LIMIT_64;
    g_config.general.skip_boot_anim = true;
    g_config.general.show_welcome = false;
    g_config.display.renderer = CONFIG_DISPLAY_RENDERER_OPENGL; // GL renderer for NV2A output

    XEMULog(@"Config: bootrom=%s flashrom=%s hdd=%s dvd=%s eeprom=%s",
            g_config.sys.files.bootrom_path,
            g_config.sys.files.flashrom_path,
            g_config.sys.files.hdd_path,
            g_config.sys.files.dvd_path,
            g_config.sys.files.eeprom_path);
}

- (void)startEmulation {
    XEMULog(@"startEmulation");

    [super startEmulation];

    // Set up audio bridge
    OpenEmuXboxBridge::g_audioBuffer = [self audioBufferAtIndex:0];
    xemu_openemu_audio_set_callback(oeAudioWriteCallback);

    // Reset state
    OpenEmuXboxBridge::g_shutdownRequested = false;
    OpenEmuXboxBridge::g_frameReady = false;

    // Spawn emulation thread
    _emuThread = std::thread([self]() {
        xemuLogToFile("XEMU emulation thread started");

        // Initialize headless display backend (also initializes SDL3)
        xemu_openemu_display_init();

        // Create NV2A GL contexts via SDL (must happen before qemu_init
        // spawns pfifo thread which calls pgraph_gl_init)
        nv2a_context_init();

        // Initialize input bridge (4 virtual controllers)
        xemu_openemu_input_init();

        // Construct minimal QEMU argv.
        // vl.c reads g_config to build its own -machine, -bios, -drive,
        // -device, -m, and -display args. We only pass extras here.
        // Passing "-display none" overrides vl.c's hardcoded "-display xemu"
        // since our args are appended after vl.c's fake_argv entries.
        const char *argv[] = {
            "qemu-system-i386",
            "-display", "none",
            NULL
        };
        int argc = 0;
        while (argv[argc] != NULL) argc++;

        // Redirect stderr to log file for the entire emulation thread
        // so QEMU error messages during both init and main loop are captured
        FILE *logFp = fopen("/tmp/xemu_openemu.log", "a");
        if (logFp) {
            fprintf(logFp, "--- qemu_init starting ---\n");
            fflush(logFp);
            dup2(fileno(logFp), STDERR_FILENO);
            fclose(logFp);
        }

        XEMULog(@"Calling qemu_init with %d args", argc);
        qemu_init(argc, (char **)argv);

        // EEPROM is auto-generated by vl.c's get_eeprom_path() during qemu_init

        // Register our display change listener now that QEMU consoles exist
        xemu_openemu_display_register();

        _isInitialized = YES;
        OpenEmuXboxBridge::g_initialized = true;
        xemuLogToFile("qemu_init completed, entering main loop");

        // Enter QEMU main loop (blocks until shutdown)
        int mlret = qemu_main_loop();
        int shutdownCause = qemu_shutdown_requested_get();
        int resetCause = qemu_reset_requested_get();
        xemuLogToFile("qemu_main_loop exited with code %d, shutdown_cause=%d, reset_cause=%d",
                       mlret, shutdownCause, resetCause);

        qemu_cleanup();
        xemuLogToFile("qemu_cleanup done");

        _isInitialized = NO;
        OpenEmuXboxBridge::g_initialized = false;
        _emuThreadExited = true;

        xemuLogToFile("XEMU emulation thread exiting");
    });

    // Wait briefly for initialization
    for (int i = 0; i < 100 && !OpenEmuXboxBridge::g_initialized; i++) {
        usleep(50000); // 50ms
    }

    XEMULog(@"startEmulation completed, initialized=%d", (int)_isInitialized);
}

- (void)stopEmulation {
    XEMULog(@"stopEmulation");

    // Signal shutdown
    OpenEmuXboxBridge::g_shutdownRequested = true;

    // Request QEMU shutdown (SHUTDOWN_CAUSE_HOST_UI = 5)
    if (_isInitialized) {
        qemu_system_shutdown_request(5);
    }

    // Clear audio callback to prevent writes during teardown
    xemu_openemu_audio_set_callback(NULL);

    // Wake frame sync
    {
        std::lock_guard<std::mutex> lock(OpenEmuXboxBridge::g_frameMutex);
        OpenEmuXboxBridge::g_frameReady = true;
    }
    OpenEmuXboxBridge::g_frameCV.notify_all();

    // Join emulation thread with timeout
    if (_emuThread.joinable()) {
        // Wait up to 5 seconds
        for (int i = 0; i < 100 && !_emuThreadExited; i++) {
            usleep(50000);
        }

        if (_emuThreadExited) {
            _emuThread.join();
            XEMULog(@"Emulation thread joined cleanly");
        } else {
            _emuThread.detach();
            XEMULog(@"Emulation thread detached (timeout)");
        }
    }

    // Clean up
    OpenEmuXboxBridge::g_audioBuffer = nil;
    _isInitialized = NO;

    [super stopEmulation];
    XEMULog(@"stopEmulation completed");
}

- (void)resetEmulation {
    XEMULog(@"resetEmulation");
    // QEMU reset can be triggered via qmp_system_reset
    // For now, this is a no-op; full reset requires more work
}

#pragma mark - Frame Execution

- (void)executeFrame {
    if (!_isInitialized) return;

    // Wait for the QEMU display backend to produce a frame
    std::unique_lock<std::mutex> lock(OpenEmuXboxBridge::g_frameMutex);
    OpenEmuXboxBridge::g_frameCV.wait_for(lock, std::chrono::milliseconds(50), [] {
        return OpenEmuXboxBridge::g_frameReady.load() ||
               OpenEmuXboxBridge::g_shutdownRequested.load();
    });
    OpenEmuXboxBridge::g_frameReady = false;
}

#pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering {
    return OEGameCoreRenderingBitmap;
}

- (const void *)getVideoBufferWithHint:(void *)hint {
    return OpenEmuXboxBridge::g_videoBuffer;
}

- (OEIntSize)bufferSize {
    return OEIntSizeMake(XBOX_WIDTH, XBOX_HEIGHT);
}

- (OEIntSize)aspectSize {
    return OEIntSizeMake(4, 3);
}

- (NSTimeInterval)frameInterval {
    return 59.94; // NTSC
}

- (uint32_t)pixelFormat {
    return 0x80E1; // OEPixelFormat_BGRA
}

- (uint32_t)pixelType {
    return 0x8367; // OEPixelType_UNSIGNED_INT_8_8_8_8_REV
}

- (NSInteger)bytesPerRow {
    return XBOX_WIDTH * 4;
}

#pragma mark - Audio

- (double)audioSampleRate {
    return XBOX_SAMPLERATE;
}

- (NSUInteger)channelCount {
    return 2;
}

- (NSUInteger)audioBufferSizeForBuffer:(NSUInteger)buffer {
    // 200ms buffer at 48kHz stereo int16 = 38400 bytes
    return (XBOX_SAMPLERATE / 5) * 2 * sizeof(int16_t);
}

#pragma mark - Input (OEXboxSystemResponderClient)

static uint16_t xboxButtonToMask(OEXboxButton button) {
    switch (button) {
        case OEXboxButtonA:          return (1 << 0);
        case OEXboxButtonB:          return (1 << 1);
        case OEXboxButtonX:          return (1 << 2);
        case OEXboxButtonY:          return (1 << 3);
        case OEXboxButtonDpadLeft:   return (1 << 4);
        case OEXboxButtonDpadUp:     return (1 << 5);
        case OEXboxButtonDpadRight:  return (1 << 6);
        case OEXboxButtonDpadDown:   return (1 << 7);
        case OEXboxButtonBack:       return (1 << 8);
        case OEXboxButtonStart:      return (1 << 9);
        case OEXboxButtonWhite:      return (1 << 10);
        case OEXboxButtonBlack:      return (1 << 11);
        case OEXboxButtonLeftStick:  return (1 << 12);
        case OEXboxButtonRightStick: return (1 << 13);
        default: return 0;
    }
}

- (oneway void)didPushXboxButton:(OEXboxButton)button forPlayer:(NSUInteger)player {
    if (player < 1 || player > 4) return;
    int idx = (int)(player - 1);

    uint16_t mask = xboxButtonToMask(button);
    if (mask) {
        uint16_t state = OpenEmuXboxBridge::g_buttonState[idx].fetch_or(mask);
        xemu_openemu_update_buttons(idx, state | mask);
    }

    // Handle triggers as digital-to-analog (full press)
    if (button == OEXboxLeftTrigger) {
        OpenEmuXboxBridge::g_axisState[idx][0] = 32767;
        xemu_openemu_update_axis(idx, 0, 32767);
    } else if (button == OEXboxRightTrigger) {
        OpenEmuXboxBridge::g_axisState[idx][1] = 32767;
        xemu_openemu_update_axis(idx, 1, 32767);
    }
}

- (oneway void)didReleaseXboxButton:(OEXboxButton)button forPlayer:(NSUInteger)player {
    if (player < 1 || player > 4) return;
    int idx = (int)(player - 1);

    uint16_t mask = xboxButtonToMask(button);
    if (mask) {
        uint16_t state = OpenEmuXboxBridge::g_buttonState[idx].fetch_and(~mask);
        xemu_openemu_update_buttons(idx, state & ~mask);
    }

    if (button == OEXboxLeftTrigger) {
        OpenEmuXboxBridge::g_axisState[idx][0] = 0;
        xemu_openemu_update_axis(idx, 0, 0);
    } else if (button == OEXboxRightTrigger) {
        OpenEmuXboxBridge::g_axisState[idx][1] = 0;
        xemu_openemu_update_axis(idx, 1, 0);
    }
}

- (oneway void)didMoveXboxJoystickDirection:(OEXboxButton)button
                                  withValue:(CGFloat)value
                                  forPlayer:(NSUInteger)player {
    if (player < 1 || player > 4) return;
    int idx = (int)(player - 1);

    int16_t axisValue = (int16_t)(value * 32767.0);

    switch (button) {
        case OEXboxLeftTrigger:
            OpenEmuXboxBridge::g_axisState[idx][0] = axisValue;
            xemu_openemu_update_axis(idx, 0, axisValue);
            break;
        case OEXboxRightTrigger:
            OpenEmuXboxBridge::g_axisState[idx][1] = axisValue;
            xemu_openemu_update_axis(idx, 1, axisValue);
            break;
        case OEXboxLeftAnalogLeft:
            OpenEmuXboxBridge::g_axisState[idx][2] = -axisValue;
            xemu_openemu_update_axis(idx, 2, -axisValue);
            break;
        case OEXboxLeftAnalogRight:
            OpenEmuXboxBridge::g_axisState[idx][2] = axisValue;
            xemu_openemu_update_axis(idx, 2, axisValue);
            break;
        case OEXboxLeftAnalogUp:
            OpenEmuXboxBridge::g_axisState[idx][3] = axisValue;
            xemu_openemu_update_axis(idx, 3, axisValue);
            break;
        case OEXboxLeftAnalogDown:
            OpenEmuXboxBridge::g_axisState[idx][3] = -axisValue;
            xemu_openemu_update_axis(idx, 3, -axisValue);
            break;
        case OEXboxRightAnalogLeft:
            OpenEmuXboxBridge::g_axisState[idx][4] = -axisValue;
            xemu_openemu_update_axis(idx, 4, -axisValue);
            break;
        case OEXboxRightAnalogRight:
            OpenEmuXboxBridge::g_axisState[idx][4] = axisValue;
            xemu_openemu_update_axis(idx, 4, axisValue);
            break;
        case OEXboxRightAnalogUp:
            OpenEmuXboxBridge::g_axisState[idx][5] = axisValue;
            xemu_openemu_update_axis(idx, 5, axisValue);
            break;
        case OEXboxRightAnalogDown:
            OpenEmuXboxBridge::g_axisState[idx][5] = -axisValue;
            xemu_openemu_update_axis(idx, 5, -axisValue);
            break;
        default:
            break;
    }
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block {
    // TODO: Implement via QEMU VM snapshots
    block(NO, [NSError errorWithDomain:@"org.openemu.XEMU" code:1
               userInfo:@{NSLocalizedDescriptionKey: @"Save states not yet supported for Xbox"}]);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block {
    // TODO: Implement via QEMU VM snapshots
    block(NO, [NSError errorWithDomain:@"org.openemu.XEMU" code:1
               userInfo:@{NSLocalizedDescriptionKey: @"Save states not yet supported for Xbox"}]);
}

@end
