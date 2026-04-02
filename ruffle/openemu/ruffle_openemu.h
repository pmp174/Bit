/*
 * ruffle_openemu.h - C FFI bindings for Ruffle Flash player
 * Used by the Ruffle OpenEmu core plugin (RuffleGameCore)
 */

#ifndef RUFFLE_OPENEMU_H
#define RUFFLE_OPENEMU_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a Ruffle player context */
typedef void* RuffleHandle;

/*
 * Create a new Ruffle context with offscreen Metal rendering.
 * Returns NULL on failure.
 */
RuffleHandle ruffle_create(uint32_t width, uint32_t height, uint32_t sample_rate);

/*
 * Load a SWF file from the given path.
 * Returns true on success, false on failure.
 */
bool ruffle_load(RuffleHandle handle, const char* path);

/*
 * Advance the Flash player by dt_micros microseconds.
 */
void ruffle_tick(RuffleHandle handle, uint64_t dt_micros);

/*
 * Render the current frame and copy RGBA pixels into pixel_buf.
 * pixel_buf must be at least width * height * 4 bytes.
 */
void ruffle_render(RuffleHandle handle, uint8_t* pixel_buf, uint32_t width, uint32_t height);

/*
 * Mix audio samples into the provided int16 stereo buffer.
 * buffer should hold at least num_frames * 2 int16 values.
 * Returns the number of frames written.
 */
int32_t ruffle_get_audio(RuffleHandle handle, int16_t* buffer, int32_t num_frames);

/*
 * Send a key down event. key_code maps to OEFlashButton enum values.
 */
void ruffle_key_down(RuffleHandle handle, uint32_t key_code);

/*
 * Send a key up event. key_code maps to OEFlashButton enum values.
 */
void ruffle_key_up(RuffleHandle handle, uint32_t key_code);

/*
 * Send a mouse move event.
 */
void ruffle_mouse_move(RuffleHandle handle, double x, double y);

/*
 * Send a mouse button down event.
 * button: 0=left, 1=right, 2=middle
 */
void ruffle_mouse_down(RuffleHandle handle, double x, double y, int32_t button);

/*
 * Send a mouse button up event.
 */
void ruffle_mouse_up(RuffleHandle handle, double x, double y, int32_t button);

/*
 * Get the SWF movie width in pixels.
 */
uint32_t ruffle_get_movie_width(RuffleHandle handle);

/*
 * Get the SWF movie height in pixels.
 */
uint32_t ruffle_get_movie_height(RuffleHandle handle);

/*
 * Get the SWF frame rate (frames per second).
 */
double ruffle_get_frame_rate(RuffleHandle handle);

/*
 * Reset the player by reloading the SWF.
 */
void ruffle_reset(RuffleHandle handle);

/*
 * Destroy the Ruffle context and free all resources.
 * Safe to call with NULL.
 */
void ruffle_destroy(RuffleHandle handle);

#ifdef __cplusplus
}
#endif

#endif /* RUFFLE_OPENEMU_H */
