/*
 * xemu OpenEmu Display Backend
 *
 * Uses VRAM direct readback. A dedicated sync thread calls
 * nv2a_get_framebuffer_surface() to trigger pgraph_gl_sync, which downloads
 * the rendered surface to VRAM via glReadPixels on the render context.
 * The main display refresh reads from VRAM without blocking the QEMU main loop.
 *
 * Copyright (c) 2024 OpenEmu Team
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "qemu/osdep.h"
#include "ui/console.h"
#include "ui/surface.h"

#include "hw/xbox/nv2a/nv2a.h"

#include <pthread.h>

// Callback to XEMUGameCore.mm
extern void xemu_openemu_frame_ready(const uint32_t *pixels, int width, int height);

// Display state
static bool g_display_initialized = false;
static DisplayChangeListener g_dcl;
static uint32_t g_readback_buffer[720 * 480];
static int g_update_count = 0;
static int g_refresh_count = 0;

// Sync thread state
static pthread_t g_sync_thread;
static volatile bool g_sync_running = false;

// Background sync thread — calls nv2a_get_framebuffer_surface() in a loop
// to trigger pgraph_gl_sync (which downloads the surface to VRAM).
// This must NOT run on the QEMU main loop thread.
static void *sync_thread_func(void *arg)
{
    (void)arg;
    fprintf(stderr, "[XEMU Display] Sync thread started\n");

    while (g_sync_running) {
        nv2a_get_framebuffer_surface();
        nv2a_release_framebuffer_surface();

        // ~60 FPS sync rate
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 16000000 }; // 16ms
        nanosleep(&ts, NULL);
    }

    fprintf(stderr, "[XEMU Display] Sync thread exiting\n");
    return NULL;
}

// Read framebuffer from VRAM at pcrtc.start
static bool try_vram_readback(void)
{
    const uint8_t *vram = nv2a_get_vram_ptr();
    if (!vram) return false;

    uint64_t fb_start = nv2a_get_pcrtc_start();
    uint64_t vram_size = nv2a_get_vram_size();
    if (fb_start == 0 || fb_start >= vram_size) return false;

    int width = 640;
    int height = 480;
    int pitch = width * 4;

    // Bounds check
    if (fb_start + (uint64_t)(pitch * height) > vram_size) return false;

    const uint8_t *fb = vram + fb_start;

    // Check for non-zero data (skip if all black)
    bool has_data = false;
    for (int i = 0; i < pitch * height; i += 4096) {
        uint32_t px = *(const uint32_t *)(fb + i);
        if ((px & 0x00FFFFFF) != 0) {
            has_data = true;
            break;
        }
    }

    static int vram_frame_count = 0;
    vram_frame_count++;
    if (vram_frame_count <= 5 || (vram_frame_count % 300) == 0) {
        uint32_t sample = *(const uint32_t *)fb;
        uint32_t center = *(const uint32_t *)(fb + (height/2) * pitch + (width/2) * 4);
        fprintf(stderr, "[XEMU Display] VRAM frame #%d: start=0x%llx has_data=%d "
                "sample=0x%08X center=0x%08X\n",
                vram_frame_count, (unsigned long long)fb_start,
                has_data, sample, center);
    }

    if (!has_data) return false;

    // Copy with alpha fix (NV2A may output A=0)
    for (int row = 0; row < height; row++) {
        const uint32_t *src = (const uint32_t *)(fb + row * pitch);
        uint32_t *dst = &g_readback_buffer[row * width];
        for (int col = 0; col < width; col++) {
            dst[col] = src[col] | 0xFF000000;
        }
    }

    xemu_openemu_frame_ready(g_readback_buffer, width, height);
    return true;
}

static void deliver_vga_frame(DisplayChangeListener *dcl)
{
    QemuConsole *con = dcl->con;
    if (!con) return;

    DisplaySurface *surface = qemu_console_surface(con);
    if (!surface) return;

    int sw = surface_width(surface);
    int sh = surface_height(surface);
    int stride = surface_stride(surface);
    uint8_t *data = (uint8_t *)surface_data(surface);
    if (!data || sw <= 0 || sh <= 0) return;

    int bpp = surface_bits_per_pixel(surface);
    int copyW = (sw < 720) ? sw : 720;
    int copyH = (sh < 480) ? sh : 480;

    if (bpp == 32) {
        for (int row = 0; row < copyH; row++) {
            memcpy(&g_readback_buffer[row * copyW],
                   data + row * stride,
                   copyW * sizeof(uint32_t));
        }
    } else if (bpp == 16) {
        for (int row = 0; row < copyH; row++) {
            uint16_t *src = (uint16_t *)(data + row * stride);
            uint32_t *dst = &g_readback_buffer[row * copyW];
            for (int col = 0; col < copyW; col++) {
                uint16_t px = src[col];
                uint8_t r = ((px >> 11) & 0x1F) << 3;
                uint8_t g = ((px >> 5) & 0x3F) << 2;
                uint8_t b = (px & 0x1F) << 3;
                dst[col] = 0xFF000000 | (r << 16) | (g << 8) | b;
            }
        }
    }

    xemu_openemu_frame_ready(g_readback_buffer, copyW, copyH);
}

static void oe_dpy_gfx_update(DisplayChangeListener *dcl,
                               int x, int y, int w, int h)
{
    g_update_count++;
    if (g_update_count <= 5 || (g_update_count % 300) == 0) {
        fprintf(stderr, "[XEMU Display] gfx_update #%d: %dx%d\n",
                g_update_count, w, h);
    }
}

static void oe_dpy_gfx_switch(DisplayChangeListener *dcl,
                               struct DisplaySurface *new_surface)
{
    static int switch_count = 0;
    switch_count++;
    if (new_surface && (switch_count <= 3 || (switch_count % 300) == 0)) {
        fprintf(stderr, "[XEMU Display] Surface switch #%d: %dx%d bpp=%d\n",
                switch_count,
                surface_width(new_surface), surface_height(new_surface),
                surface_bits_per_pixel(new_surface));
    }
}

static void oe_dpy_refresh(DisplayChangeListener *dcl)
{
    g_refresh_count++;
    if (g_refresh_count <= 3 || (g_refresh_count % 300) == 0) {
        fprintf(stderr, "[XEMU Display] refresh #%d\n", g_refresh_count);
    }

    // Try VRAM readback first (NV2A 3D rendered frames downloaded by sync thread)
    if (try_vram_readback()) {
        return;
    }

    // Fall back to VGA surface for early boot
    graphic_hw_update(dcl->con);
    deliver_vga_frame(dcl);
}

static const DisplayChangeListenerOps oe_dcl_ops = {
    .dpy_name        = "openemu",
    .dpy_gfx_update  = oe_dpy_gfx_update,
    .dpy_gfx_switch  = oe_dpy_gfx_switch,
    .dpy_refresh     = oe_dpy_refresh,
};

void xemu_openemu_display_init(void)
{
    if (g_display_initialized)
        return;

    memset(g_readback_buffer, 0, sizeof(g_readback_buffer));
    g_display_initialized = true;
    fprintf(stderr, "[XEMU Display] Display bridge initialized (VRAM readback + sync thread)\n");
}

void xemu_openemu_display_register(void)
{
    if (!g_display_initialized) {
        fprintf(stderr, "[XEMU Display] ERROR: display_register called before init\n");
        return;
    }

    QemuConsole *con = qemu_console_lookup_by_index(0);
    if (!con) {
        con = qemu_console_lookup_default();
    }
    if (!con) {
        fprintf(stderr, "[XEMU Display] ERROR: No QemuConsole found\n");
        return;
    }

    memset(&g_dcl, 0, sizeof(g_dcl));
    g_dcl.ops = &oe_dcl_ops;
    g_dcl.con = con;

    register_displaychangelistener(&g_dcl);
    fprintf(stderr, "[XEMU Display] DisplayChangeListener registered on console %p\n", con);

    // Start the background sync thread
    g_sync_running = true;
    pthread_create(&g_sync_thread, NULL, sync_thread_func, NULL);
}

void xemu_openemu_render_frame(uint32_t *buffer, int width, int height)
{
    (void)buffer; (void)width; (void)height;
}
