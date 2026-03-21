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

/// Errors that can occur during storage provider operations.
enum OEStorageProviderError: Error, LocalizedError {
    case notAuthenticated
    case authenticationFailed(underlying: Error?)
    case fileNotFound(path: String)
    case uploadFailed(path: String, underlying: Error?)
    case downloadFailed(path: String, underlying: Error?)
    case deleteFailed(path: String, underlying: Error?)
    case networkUnavailable
    case quotaExceeded
    case providerUnavailable
    case invalidConfiguration
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return NSLocalizedString("Not authenticated with storage provider.", comment: "")
        case .authenticationFailed(let error):
            return String(format: NSLocalizedString("Authentication failed: %@", comment: ""),
                          error?.localizedDescription ?? "Unknown error")
        case .fileNotFound(let path):
            return String(format: NSLocalizedString("File not found: %@", comment: ""), path)
        case .uploadFailed(let path, let error):
            return String(format: NSLocalizedString("Upload failed for %@: %@", comment: ""),
                          path, error?.localizedDescription ?? "Unknown error")
        case .downloadFailed(let path, let error):
            return String(format: NSLocalizedString("Download failed for %@: %@", comment: ""),
                          path, error?.localizedDescription ?? "Unknown error")
        case .deleteFailed(let path, let error):
            return String(format: NSLocalizedString("Delete failed for %@: %@", comment: ""),
                          path, error?.localizedDescription ?? "Unknown error")
        case .networkUnavailable:
            return NSLocalizedString("Network is unavailable.", comment: "")
        case .quotaExceeded:
            return NSLocalizedString("Storage quota exceeded.", comment: "")
        case .providerUnavailable:
            return NSLocalizedString("Storage provider is unavailable.", comment: "")
        case .invalidConfiguration:
            return NSLocalizedString("Invalid storage configuration.", comment: "")
        }
    }
}

/// Protocol that all storage backends must implement.
/// Each provider handles authentication, upload, download, delete, and listing
/// for a single cloud or remote storage service.
protocol OEStorageProvider: AnyObject {
    
    /// The type of this provider.
    var providerType: OEStorageProviderType { get }
    
    /// Current connection status.
    var status: OEStorageProviderStatus { get }
    
    // MARK: - Authentication
    
    /// Whether the provider is currently authenticated and ready for operations.
    var isAuthenticated: Bool { get }
    
    /// Authenticate with the provider. For OAuth providers, this may present a web view.
    /// For iCloud, this checks iCloud availability. For WebDAV, this validates credentials.
    func authenticate() async throws
    
    /// Sign out and clear stored credentials.
    func signOut() async
    
    /// Handle an OAuth redirect URL (for Google Drive, Dropbox).
    /// Returns `true` if the URL was handled by this provider.
    func handleOAuthRedirect(url: URL) -> Bool
    
    // MARK: - File Operations
    
    /// Upload a local file to the remote storage at the given relative path.
    /// - Parameters:
    ///   - localURL: The local file to upload.
    ///   - remotePath: The destination path relative to the Bit root folder on the provider.
    /// - Returns: The cloud identifier for the uploaded file.
    @discardableResult
    func upload(localURL: URL, toRemotePath remotePath: String) async throws -> String
    
    /// Download a remote file to a local destination.
    /// - Parameters:
    ///   - remotePath: The remote path relative to the Bit root folder.
    ///   - localURL: Where to save the downloaded file locally.
    func download(remotePath: String, toLocalURL localURL: URL) async throws
    
    /// Delete a file from remote storage.
    /// - Parameter remotePath: The remote path relative to the Bit root folder.
    func delete(remotePath: String) async throws
    
    /// List files at a remote path.
    /// - Parameter remotePath: The remote directory path relative to the Bit root folder.
    /// - Returns: Array of file info objects for each item found.
    func list(remotePath: String) async throws -> [OECloudFileInfo]
    
    /// Check if a file exists at the given remote path.
    /// - Parameter remotePath: The remote path to check.
    /// - Returns: `true` if the file exists.
    func fileExists(remotePath: String) async throws -> Bool
    
    // MARK: - Eviction Support
    
    /// For providers that support native eviction (like iCloud), evict the local copy.
    /// Default implementation does nothing (most providers handle eviction by deleting the local file).
    func evictLocalCopy(at localURL: URL) async throws
}

// MARK: - Default Implementations

extension OEStorageProvider {
    
    func handleOAuthRedirect(url: URL) -> Bool {
        return false
    }
    
    func evictLocalCopy(at localURL: URL) async throws {
        // Default: remove the local file. The cloud copy remains.
        try FileManager.default.removeItem(at: localURL)
    }
}
