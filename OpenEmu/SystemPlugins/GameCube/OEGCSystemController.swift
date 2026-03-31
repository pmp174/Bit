// Copyright (c) 2023, OpenEmu Team
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

class OEGCSystemController: OESystemController {
    // Read header to detect GameCube ISO, GCM, CISO, GCZ & RVZ.
    override func canHandle(_ file: OEFile) -> OEFileSupport {
        let ext = file.fileExtension.lowercased()

        // GCM files are exclusively GameCube
        if ext == "gcm" {
            return .yes
        }

        // GameCube Magicword 0xC2339F3D
        let gcMagic = Data([0xC2, 0x33, 0x9F, 0x3D])

        // RVZ/WIA: disc header is stored uncompressed at file offset 0x58.
        // The GameCube magic word is at disc offset 0x1C, so file offset 0x58 + 0x1C = 0x74.
        if ext == "rvz" {
            let dataBuffer = file.readData(in: NSRange(location: 0x74, length: 4))
            return dataBuffer == gcMagic ? .yes : .no
        }

        // GCZ: compressed format — disc data is not at raw file offsets.
        // Check GCZ container magic (0xB10BC001) at offset 0, then decompress
        // would be needed for true detection. Use .uncertain so the Wii controller
        // also gets a chance, and the user can choose if both claim it.
        if ext == "gcz" {
            let containerMagic = file.readData(in: NSRange(location: 0x0, length: 4))
            let gczMagic = Data([0xB1, 0x0B, 0xC0, 0x01])
            return containerMagic == gczMagic ? .uncertain : .no
        }

        var dataRange = NSRange(location: 0x1C, length: 4)

        // Handle ciso file and set the offset for the Magicword in compressed iso.
        if ext == "ciso" {
            dataRange.location = 0x801C
        }

        // For ISO and CISO, check the GameCube magic word at the standard offset
        let dataBuffer = file.readData(in: dataRange)
        if dataBuffer == gcMagic {
            return .yes
        }

        return .no
    }

    override func serialLookup(for file: OEFile) -> String? {
        var dataRange = NSRange(location: 0x0, length: 6)

        // Check if it's a CISO and adjust the Game ID offset location
        let magic = file.readASCIIString(in: NSRange(location: 0x0, length: 4))
        if magic == "CISO" {
            dataRange.location = 0x8000
        }

        // Read the game ID
        var gameID = file.readASCIIString(in: dataRange)

        // Read the disc number and version number bytes from the header.
        let headerDiscData = file.readData(in: NSRange(location: dataRange.location + 0x6, length: 1))
        let headerDiscByte = [UInt8](headerDiscData).first ?? 0
        let headerVersionData = file.readData(in: NSRange(location: dataRange.location + 0x7, length: 1))
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
