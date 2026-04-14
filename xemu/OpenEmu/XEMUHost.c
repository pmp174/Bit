/*
 * xemu OpenEmu Host Bridge
 *
 * Provides input injection and host callback functions for the
 * headless OpenEmu integration of xemu.
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
 * Input Bridge
 *
 * The Xbox controller has:
 * - 14 digital buttons (A, B, X, Y, White, Black, DPad x4, Start, Back, L3, R3)
 * - 6 analog axes (LTrig, RTrig, LStick X/Y, RStick X/Y)
 * - 4 controller ports
 *
 * xemu stores input in ControllerState structs that the XID USB device reads
 * via update_input(). For OpenEmu integration, we maintain our own state arrays
 * that get copied into ControllerState when QEMU polls for input.
 *
 * The actual ControllerState integration happens when the QEMU build is complete.
 * For now, we store the state and provide the functions that XEMUGameCore calls.
 */

// Per-controller input state
static uint16_t g_oe_buttons[4] = {0, 0, 0, 0};
static int16_t  g_oe_axes[4][6] = {{0}};
static bool     g_input_initialized = false;

void xemu_openemu_input_init(void)
{
    memset(g_oe_buttons, 0, sizeof(g_oe_buttons));
    memset(g_oe_axes, 0, sizeof(g_oe_axes));
    g_input_initialized = true;
    fprintf(stderr, "[XEMU Input] OpenEmu input bridge initialized (4 controllers)\n");
}

void xemu_openemu_update_buttons(int port, uint16_t buttons)
{
    if (port >= 0 && port < 4) {
        g_oe_buttons[port] = buttons;
    }
}

void xemu_openemu_update_axis(int port, int axis_index, int16_t value)
{
    if (port >= 0 && port < 4 && axis_index >= 0 && axis_index < 6) {
        g_oe_axes[port][axis_index] = value;
    }
}

/*
 * Called by xemu's input polling to get the current controller state.
 * This replaces the SDL gamepad polling that normally happens in
 * xemu_input_update_sdl_controller_state().
 *
 * When integrated into the full build, this function populates the
 * ControllerState.buttons and ControllerState.axis[] fields.
 */
uint16_t xemu_openemu_get_buttons(int port)
{
    if (port >= 0 && port < 4)
        return g_oe_buttons[port];
    return 0;
}

int16_t xemu_openemu_get_axis(int port, int axis_index)
{
    if (port >= 0 && port < 4 && axis_index >= 0 && axis_index < 6)
        return g_oe_axes[port][axis_index];
    return 0;
}

bool xemu_openemu_input_is_initialized(void)
{
    return g_input_initialized;
}
