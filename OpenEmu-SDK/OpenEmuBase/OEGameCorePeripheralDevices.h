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

// Note: all definitions here shall be macros, matching the pattern of
// OEGameCoreDisplayModes.h for consistency.

/*
 * Keys for peripheralDevices entries.
 *
 * Each entry in the peripheralDevices array represents a port.
 */

/** NSString. Display name of the port (e.g. "Port A", "Controller Port 1"). */
#define OEPeripheralPortNameKey @"OEPeripheralPortNameKey"

/** NSString. Unique identifier for the port (e.g. "maple.0", "si.0"). */
#define OEPeripheralPortIdentifierKey @"OEPeripheralPortIdentifierKey"

/** NSArray of NSDictionary. The available devices for this port.
 *  Each device dictionary contains OEPeripheralDeviceNameKey,
 *  OEPeripheralDeviceIdentifierKey, and OEPeripheralDeviceSelectedKey. */
#define OEPeripheralPortDevicesKey @"OEPeripheralPortDevicesKey"

/** NSArray of NSDictionary. Optional expansion sub-ports, each with the
 *  same structure as a top-level port entry (one level of nesting). */
#define OEPeripheralPortExpansionsKey @"OEPeripheralPortExpansionsKey"

/** NSString. Display name of a device option (e.g. "Controller", "Microphone"). */
#define OEPeripheralDeviceNameKey @"OEPeripheralDeviceNameKey"

/** NSString. Unique identifier for a device (e.g. "dc.main.0", "gc.exi.mic"). */
#define OEPeripheralDeviceIdentifierKey @"OEPeripheralDeviceIdentifierKey"

/** NSNumber (BOOL). @(YES) if this device is currently selected for the port. */
#define OEPeripheralDeviceSelectedKey @"OEPeripheralDeviceSelectedKey"
