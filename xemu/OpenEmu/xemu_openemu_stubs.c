/*
 * xemu OpenEmu Stubs
 *
 * Stub implementations for SDL, ImGui, HUD, and other UI-dependent
 * functions that are not needed in the headless OpenEmu plugin.
 *
 * Copyright (c) 2024 OpenEmu Team
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

/*
 * When building xemu as a library for OpenEmu, we exclude the SDL-based
 * UI code (ui/xemu.c, ui/xui/, etc.). This file provides stub implementations
 * for functions that other parts of the codebase reference.
 *
 * Functions are grouped by subsystem. Each stub either:
 * - Returns a safe default value
 * - Logs a diagnostic message
 * - Does nothing (void functions)
 */

// ============================================================================
// xemu HUD / UI stubs
// ============================================================================

void xemu_hud_init(void *window, void *context) {}
void xemu_hud_cleanup(void) {}
void xemu_hud_render(void) {}
void xemu_hud_should_capture_kbd_mouse(int *kbd, int *mouse)
{
    if (kbd) *kbd = 0;
    if (mouse) *mouse = 0;
}
bool xemu_hud_is_idle(void) { return true; }

// ============================================================================
// xemu notification stubs
// ============================================================================

void xemu_queue_notification(const char *msg) {
    fprintf(stderr, "[XEMU Stub] Notification: %s\n", msg ? msg : "(null)");
}
void xemu_queue_error_message(const char *msg) {
    fprintf(stderr, "[XEMU Stub] Error: %s\n", msg ? msg : "(null)");
}

// ============================================================================
// xemu window / display stubs
// ============================================================================

void *xemu_get_window(void) { return NULL; }
void xemu_toggle_fullscreen(void) {}

int xemu_is_fullscreen(void) { return 0; }
void xemu_eject_disc(void *errp) {}
void xemu_monitor_init(void) {}

// ============================================================================
// xemu settings stubs (we configure g_config directly)
// ============================================================================

// Note: xemu_settings_load/save are only stubbed if the full settings
// system is excluded from the build. The actual g_config struct and
// xemu_settings_set_string() must still be available.

// ============================================================================
// xemu network stubs
// ============================================================================

void xemu_net_enable(void) {}
void xemu_net_disable(void) {}
int xemu_net_is_enabled(void) { return 0; }

// ============================================================================
// xemu snapshot UI stubs
// ============================================================================

// Provided by libxemu.a (xemu-snapshots.c):
// void xemu_snapshots_mark_dirty(void);

// ============================================================================
// xemu thumbnail stubs
// ============================================================================

void xemu_snapshots_save_thumbnail(void) {}

// ============================================================================
// xemu controller UI stubs
// ============================================================================

// These are provided by libxemu.a (xemu-input.c):
// void xemu_input_process_sdl_events(void *event);
// int xemu_input_get_test_mode(void);

// ============================================================================
// SDL stubs (for any residual SDL references)
// ============================================================================

// These are only needed if some xemu code still references SDL functions
// after building with --disable-sdl. Most should be eliminated by the
// configure step, but we provide fallbacks just in case.

// ============================================================================
// ImGui stubs (for any residual ImGui references)
// ============================================================================

// These stubs prevent linker errors from xemu code that references ImGui
// functions outside of the xui/ directory.

void *ImGui_GetCurrentContext(void) { return NULL; }
