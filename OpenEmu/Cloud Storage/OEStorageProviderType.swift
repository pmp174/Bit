// Copyright (c) 2024, OpenEmu Team
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

/// The type of storage provider used for library or save data.
enum OEStorageProviderType: String, Codable, CaseIterable {
    case local      = "local"
    case iCloud     = "icloud"
    case googleDrive = "googledrive"
    case dropbox    = "dropbox"
    case webDAV     = "webdav"
    
    var displayName: String {
        switch self {
        case .local:        return "Local"
        case .iCloud:       return "iCloud"
        case .googleDrive:  return "Google Drive"
        case .dropbox:      return "Dropbox"
        case .webDAV:       return "NAS (WebDAV)"
        }
    }
    
    var iconName: String {
        switch self {
        case .local:        return "internaldrive"
        case .iCloud:       return "icloud"
        case .googleDrive:  return "externaldrive.badge.icloud"
        case .dropbox:      return "externaldrive.badge.icloud"
        case .webDAV:       return "server.rack"
        }
    }
    
    var requiresAuthentication: Bool {
        switch self {
        case .local:        return false
        case .iCloud:       return false
        case .googleDrive:  return true
        case .dropbox:      return true
        case .webDAV:       return true
        }
    }
}

/// Defines what content categories a user wants to sync.
struct OESyncScope: OptionSet, Codable {
    let rawValue: Int
    
    static let library     = OESyncScope(rawValue: 1 << 0)  // ROMs, box art, metadata
    static let saves       = OESyncScope(rawValue: 1 << 1)  // Save states
    static let screenshots = OESyncScope(rawValue: 1 << 2)  // Screenshots
    
    static let all: OESyncScope = [.library, .saves, .screenshots]
    static let savesOnly: OESyncScope = [.saves]
}

/// Remote file metadata returned by storage providers.
struct OECloudFileInfo {
    let identifier: String
    let name: String
    let path: String
    let size: Int64
    let modifiedDate: Date
    let isDirectory: Bool
}

/// Status of a cloud storage provider connection.
enum OEStorageProviderStatus {
    case disconnected
    case authenticating
    case connected
    case syncing(progress: Double)
    case error(Error)
    
    var isConnected: Bool {
        switch self {
        case .connected, .syncing: return true
        default: return false
        }
    }
}
