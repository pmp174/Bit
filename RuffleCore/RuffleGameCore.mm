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

#import "RuffleGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import "OEFlashSystemResponderClient.h"
#import <OpenGL/gl.h>

#include "ruffle_openemu.h"

static const double kAudioSampleRate = 44100.0;
static const int kAudioChannels = 2;
// Number of audio frames to mix per executeFrame call
static const int kAudioFramesPerTick = 735; // ~44100 / 60

@interface RuffleGameCore () <OEFlashSystemResponderClient>
{
    RuffleHandle _ruffleHandle;
    uint8_t *_videoBuffer;
    uint32_t _width;
    uint32_t _height;
    double _frameRate;
    uint64_t _lastTickTime;
}
@end

@implementation RuffleGameCore

- (id)init
{
    if ((self = [super init]))
    {
        _ruffleHandle = NULL;
        _videoBuffer = NULL;
        _width = 550;  // Default Flash stage size
        _height = 400;
        _frameRate = 30.0;
        _lastTickTime = 0;
    }
    return self;
}

- (void)dealloc
{
    if (_videoBuffer) {
        free(_videoBuffer);
        _videoBuffer = NULL;
    }
    if (_ruffleHandle) {
        ruffle_destroy(_ruffleHandle);
        _ruffleHandle = NULL;
    }
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    // Create Ruffle context with default dimensions; will be updated after SWF load
    _ruffleHandle = ruffle_create(_width, _height, (uint32_t)kAudioSampleRate);
    if (!_ruffleHandle) {
        if (error) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotStartCoreError
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create Ruffle context"}];
        }
        return NO;
    }

    if (!ruffle_load(_ruffleHandle, path.fileSystemRepresentation)) {
        if (error) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to load SWF file"}];
        }
        ruffle_destroy(_ruffleHandle);
        _ruffleHandle = NULL;
        return NO;
    }

    // Read movie dimensions and frame rate from the loaded SWF
    uint32_t movieWidth = ruffle_get_movie_width(_ruffleHandle);
    uint32_t movieHeight = ruffle_get_movie_height(_ruffleHandle);
    double fps = ruffle_get_frame_rate(_ruffleHandle);

    if (movieWidth > 0 && movieHeight > 0) {
        _width = movieWidth;
        _height = movieHeight;
    }
    if (fps > 0) {
        _frameRate = fps;
    }

    // Allocate video buffer (RGBA, 4 bytes per pixel)
    if (_videoBuffer) free(_videoBuffer);
    _videoBuffer = (uint8_t *)calloc(_width * _height * 4, sizeof(uint8_t));

    return YES;
}

- (void)executeFrame
{
    if (!_ruffleHandle) return;

    // Calculate dt in microseconds based on frame rate
    uint64_t dt_micros = (uint64_t)(1000000.0 / _frameRate);

    // Advance the Flash player
    ruffle_tick(_ruffleHandle, dt_micros);

    // Render the current frame into our pixel buffer
    ruffle_render(_ruffleHandle, _videoBuffer, _width, _height);

    // Mix audio and write to the ring buffer
    int audioFrames = (int)(kAudioSampleRate / _frameRate);
    int16_t audioBuffer[audioFrames * kAudioChannels];
    int32_t written = ruffle_get_audio(_ruffleHandle, audioBuffer, audioFrames);
    if (written > 0) {
        [[self audioBufferAtIndex:0] write:audioBuffer maxLength:written * kAudioChannels * sizeof(int16_t)];
    }
}

- (void)resetEmulation
{
    if (_ruffleHandle) {
        ruffle_reset(_ruffleHandle);
    }
}

- (void)stopEmulation
{
    if (_ruffleHandle) {
        ruffle_destroy(_ruffleHandle);
        _ruffleHandle = NULL;
    }
    if (_videoBuffer) {
        free(_videoBuffer);
        _videoBuffer = NULL;
    }
    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return _frameRate;
}

#pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (!hint) {
        if (!_videoBuffer) {
            _videoBuffer = (uint8_t *)calloc(_width * _height * 4, sizeof(uint8_t));
        }
        hint = _videoBuffer;
    }
    return _videoBuffer = (uint8_t *)hint;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, _width, _height);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(_width, _height);
}

- (OEIntSize)aspectSize
{
    // Use the SWF's native aspect ratio
    return OEIntSizeMake(_width, _height);
}

- (GLenum)pixelFormat
{
    return GL_RGBA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_BYTE;
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return kAudioSampleRate;
}

- (NSUInteger)channelCount
{
    return kAudioChannels;
}

#pragma mark - Input

- (oneway void)didPushFlashButton:(OEFlashButton)button
{
    if (_ruffleHandle) {
        ruffle_key_down(_ruffleHandle, (uint32_t)button);
    }
}

- (oneway void)didReleaseFlashButton:(OEFlashButton)button
{
    if (_ruffleHandle) {
        ruffle_key_up(_ruffleHandle, (uint32_t)button);
    }
}

@end
