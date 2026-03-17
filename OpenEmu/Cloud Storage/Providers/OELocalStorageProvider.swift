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

/// Local storage provider. Files stay on disk with no cloud sync.
/// This is the default provider and acts as a passthrough — all operations
/// are simple file system operations within the library folder.
final class OELocalStorageProvider: OEStorageProvider {
    
    let providerType: OEStorageProviderType = .local
    
    var status: OEStorageProviderStatus { .connected }
    
    var isAuthenticated: Bool { true }
    
    func authenticate() async throws {
        // Local storage is always available
    }
    
    func signOut() async {
        // No-op for local storage
    }
    
    func handleOAuthRedirect(url: URL) -> Bool {
        return false
    }
    
    @discardableResult
    func upload(localURL: URL, toRemotePath remotePath: String) async throws -> String {
        // Local storage: files are already where they need to be.
        // Return the local path as the "cloud identifier".
        return localURL.lastPathComponent
    }
    
    func download(remotePath: String, toLocalURL localURL: URL) async throws {
        // Local storage: files are already local. No-op.
    }
    
    func delete(remotePath: String) async throws {
        // Local storage: handled by the normal file deletion path.
    }
    
    func list(remotePath: String) async throws -> [OECloudFileInfo] {
        // Not used for local storage
        return []
    }
    
    func fileExists(remotePath: String) async throws -> Bool {
        return true
    }
    
    func evictLocalCopy(at localURL: URL) async throws {
        // Local storage cannot evict — files must remain.
        throw OEStorageProviderError.providerUnavailable
    }
}
