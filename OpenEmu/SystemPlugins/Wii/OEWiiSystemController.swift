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

import Foundation
import OpenEmuSystem

class OEWiiSystemController: OESystemController {
    override func canHandle(_ file: OEFile) -> OEFileSupport {
        let ext = file.fileExtension.lowercased()

        // WBFS and WAD files are always Wii
        if ext == "wbfs" || ext == "wad" {
            return .yes
        }

        // Wii magic word 0x5D1C9EA3
        let wiiMagic = Data([0x5D, 0x1C, 0x9E, 0xA3])

        // RVZ/WIA: disc header is stored uncompressed at file offset 0x58.
        // The Wii magic word is at disc offset 0x18, so file offset 0x58 + 0x18 = 0x70.
        if ext == "rvz" {
            let dataBuffer = file.readData(in: NSRange(location: 0x70, length: 4))
            return dataBuffer == wiiMagic ? .yes : .no
        }

        // GCZ: compressed format — disc data is not at raw file offsets.
        // Check GCZ container magic to confirm format, then return .uncertain
        // since we can't verify the disc magic without decompression.
        if ext == "gcz" {
            let containerMagic = file.readData(in: NSRange(location: 0x0, length: 4))
            let gczMagic = Data([0xB1, 0x0B, 0xC0, 0x01])
            return containerMagic == gczMagic ? .uncertain : .no
        }

        // For ISO, CISO, and NKit formats, check the Wii magic word at standard offset
        if ["iso", "ciso", "nkit.iso", "nkit.gcz"].contains(ext) {
            var dataRange = NSRange(location: 0x18, length: 4)

            if ext == "ciso" {
                dataRange.location = 0x8018
            }

            let dataBuffer = file.readData(in: dataRange)
            if dataBuffer == wiiMagic {
                return .yes
            }
        }

        return .no
    }

    override func serialLookup(for file: OEFile) -> String? {
        let ext = file.fileExtension.lowercased()

        var offset = 0

        // WBFS has a special header; game data starts after it
        if ext == "wbfs" {
            // WBFS header: magic "WBFS" + sector info, game ID at offset 0x200
            let magic = file.readASCIIString(in: NSRange(location: 0x0, length: 4))
            if magic == "WBFS" {
                offset = 0x200
            }
        } else if ext == "ciso" {
            offset = 0x8000
        }

        // Read the 6-character game ID
        var gameID = file.readASCIIString(in: NSRange(location: offset, length: 6))

        // Read the disc number byte from the header
        let headerDiscData = file.readData(in: NSRange(location: offset + 0x6, length: 1))
        let headerDiscByte = [UInt8](headerDiscData).first ?? 0
        let headerVersionData = file.readData(in: NSRange(location: offset + 0x7, length: 1))
        let headerVersionByte = [UInt8](headerVersionData).first ?? 0

        if headerDiscByte > 0 {
            gameID += "-DISC\(headerDiscByte + 1)"
        }

        if headerVersionByte > 0 {
            gameID += "-REV\(headerVersionByte)"
        }

        return gameID
    }
}
