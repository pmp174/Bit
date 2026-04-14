/*
 * xemu OpenEmu Audio Backend
 *
 * Custom QEMU audio driver that forwards PCM samples to OpenEmu's
 * ring buffer via a callback function set by XEMUGameCore.
 *
 * Copyright (c) 2024 OpenEmu Team
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>

/*
 * This file implements a QEMU audio_driver that captures audio output
 * and forwards it to OpenEmu. It follows the pattern of audio/noaudio.c
 * and audio/coreaudio.m but routes samples through a function pointer
 * callback instead of a system audio API.
 *
 * When building as part of the full QEMU/xemu build, this file should be
 * added to audio/meson.build. The audio_driver struct is registered with
 * QEMU's audio subsystem and selected via "-audiodev openemu,id=ad0".
 *
 * For the initial bridge development, we provide a simpler standalone
 * callback interface that the XEMUGameCore can use directly.
 */

// Audio callback function pointer (set by XEMUGameCore.mm)
static void (*g_audio_write_callback)(const void *buf, size_t len) = NULL;

void xemu_openemu_audio_set_callback(void (*callback)(const void *buf, size_t len))
{
    g_audio_write_callback = callback;
}

/*
 * Called by the xemu audio mixer when samples are ready.
 * This should be hooked into the audio output path, either:
 * 1. As a proper QEMU audio_driver (when integrated into the Meson build)
 * 2. As a hook in the existing CoreAudio/SDL audio output path
 *
 * Format: interleaved stereo int16_t at 48kHz
 */
void xemu_openemu_audio_write(const void *buf, size_t len)
{
    if (g_audio_write_callback && buf && len > 0) {
        g_audio_write_callback(buf, len);
    }
}

/*
 * QEMU audio_driver implementation for OpenEmu.
 *
 * This section implements the full QEMU audio backend interface.
 * It will be compiled when building with the full QEMU build system
 * (guarded by OPENEMU define from the Meson build).
 *
 * The driver is intentionally simple: it accepts whatever samples QEMU
 * provides and forwards them through the callback. No resampling or
 * format conversion is performed here — QEMU's audio mixer handles that.
 */

#ifdef OPENEMU_QEMU_AUDIO_DRIVER

#include "qemu/osdep.h"
#include "qemu/module.h"
#include "audio/audio.h"
#include "audio/audio_int.h"

typedef struct OEVoiceOut {
    HWVoiceOut hw;
    // No additional state needed — we forward all samples immediately
} OEVoiceOut;

static int oe_init_out(HWVoiceOut *hw, struct audsettings *as, void *drv_opaque)
{
    // Accept whatever format QEMU wants; we'll get S16LE stereo 48kHz
    audio_pcm_init_info(&hw->info, as);
    hw->samples = 4096; // Buffer size in frames
    return 0;
}

static void oe_fini_out(HWVoiceOut *hw)
{
    // Nothing to clean up
}

static size_t oe_write(HWVoiceOut *hw, void *buf, size_t len)
{
    xemu_openemu_audio_write(buf, len);
    return len; // Always consume all samples
}

static void *oe_get_buffer_out(HWVoiceOut *hw, size_t *size)
{
    // Return a pointer to internal buffer for QEMU to write into
    // QEMU will then call put_buffer_out
    return hw->mix_buf;
}

static size_t oe_put_buffer_out(HWVoiceOut *hw, void *buf, size_t size)
{
    xemu_openemu_audio_write(buf, size);
    return size;
}

static void oe_enable_out(HWVoiceOut *hw, bool enable)
{
    // No-op — we're always ready to receive samples
}

static struct audio_pcm_ops oe_pcm_ops = {
    .init_out       = oe_init_out,
    .fini_out       = oe_fini_out,
    .write          = oe_write,
    .get_buffer_out = oe_get_buffer_out,
    .put_buffer_out = oe_put_buffer_out,
    .enable_out     = oe_enable_out,
};

static void *oe_audio_init(Audiodev *dev, Error **errp)
{
    fprintf(stderr, "[XEMU Audio] OpenEmu audio backend initialized\n");
    // Return non-NULL to indicate success
    return (void *)1;
}

static void oe_audio_fini(void *opaque)
{
    fprintf(stderr, "[XEMU Audio] OpenEmu audio backend finalized\n");
}

static struct audio_driver openemu_audio_driver = {
    .name           = "openemu",
    .descr          = "OpenEmu audio output",
    .init           = oe_audio_init,
    .fini           = oe_audio_fini,
    .pcm_ops        = &oe_pcm_ops,
    .max_voices_out = 1,
    .max_voices_in  = 0,
    .voice_size_out = sizeof(OEVoiceOut),
    .voice_size_in  = 0,
};

static void register_audio_openemu(void)
{
    audio_driver_register(&openemu_audio_driver);
}
type_init(register_audio_openemu);

#endif /* OPENEMU_QEMU_AUDIO_DRIVER */
