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
import OSLog

/// iCloud Drive storage provider.
/// Uses native FileManager ubiquity APIs for seamless iCloud integration.
/// Files placed in the ubiquity container are automatically synced by the system.
final class OEiCloudStorageProvider: OEStorageProvider {
    
    let providerType: OEStorageProviderType = .iCloud
    
    private(set) var status: OEStorageProviderStatus = .disconnected
    
    /// The iCloud ubiquity container URL, lazily resolved.
    private var containerURL: URL?
    
    /// Root folder inside the iCloud container for Bit data.
    private var bitRootURL: URL? {
        containerURL?.appendingPathComponent("Documents/Bit", isDirectory: true)
    }
    
    var isAuthenticated: Bool {
        return containerURL != nil && FileManager.default.ubiquityIdentityToken != nil
    }
    
    func authenticate() async throws {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .error(OEStorageProviderError.notAuthenticated)
            throw OEStorageProviderError.notAuthenticated
        }
        
        // Resolve the container URL on a background thread (can block)
        let url = await Task.detached(priority: .userInitiated) {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }.value
        
        guard let url else {
            status = .error(OEStorageProviderError.providerUnavailable)
            throw OEStorageProviderError.providerUnavailable
        }
        
        containerURL = url
        
        // Ensure the root directory exists
        let rootURL = url.appendingPathComponent("Documents/Bit", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        
        status = .connected
        
        if #available(macOS 11.0, *) {
            Logger.cloudStorage.info("iCloud container resolved: \(url.path)")
        }
    }
    
    func signOut() async {
        containerURL = nil
        status = .disconnected
    }
    
    @discardableResult
    func upload(localURL: URL, toRemotePath remotePath: String) async throws -> String {
        guard let root = bitRootURL else { throw OEStorageProviderError.notAuthenticated }
        
        let destinationURL = root.appendingPathComponent(remotePath)
        let destinationDir = destinationURL.deletingLastPathComponent()
        
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        
        // If file already exists in iCloud location, remove it first
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        
        // Copy file into the iCloud container. The system handles the actual upload.
        try fm.copyItem(at: localURL, to: destinationURL)
        
        return remotePath
    }
    
    func download(remotePath: String, toLocalURL localURL: URL) async throws {
        guard let root = bitRootURL else { throw OEStorageProviderError.notAuthenticated }
        
        let sourceURL = root.appendingPathComponent(remotePath)
        
        // Tell iCloud to start downloading if it's cloud-only
        try FileManager.default.startDownloadingUbiquitousItem(at: sourceURL)
        
        // Wait for download to complete
        try await waitForDownload(of: sourceURL)
        
        // Copy to local destination
        let fm = FileManager.default
        let localDir = localURL.deletingLastPathComponent()
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        
        if fm.fileExists(atPath: localURL.path) {
            try fm.removeItem(at: localURL)
        }
        try fm.copyItem(at: sourceURL, to: localURL)
    }
    
    func delete(remotePath: String) async throws {
        guard let root = bitRootURL else { throw OEStorageProviderError.notAuthenticated }
        
        let fileURL = root.appendingPathComponent(remotePath)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        try FileManager.default.removeItem(at: fileURL)
    }
    
    func list(remotePath: String) async throws -> [OECloudFileInfo] {
        guard let root = bitRootURL else { throw OEStorageProviderError.notAuthenticated }
        
        let directoryURL = root.appendingPathComponent(remotePath)
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else { return [] }
        
        let keys: [URLResourceKey] = [.nameKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let contents = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: keys)
        
        return try contents.map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            return OECloudFileInfo(
                identifier: url.lastPathComponent,
                name: values.name ?? url.lastPathComponent,
                path: remotePath + "/" + url.lastPathComponent,
                size: Int64(values.fileSize ?? 0),
                modifiedDate: values.contentModificationDate ?? Date(),
                isDirectory: values.isDirectory ?? false
            )
        }
    }
    
    func fileExists(remotePath: String) async throws -> Bool {
        guard let root = bitRootURL else { throw OEStorageProviderError.notAuthenticated }
        let fileURL = root.appendingPathComponent(remotePath)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    func evictLocalCopy(at localURL: URL) async throws {
        // Use the native iCloud eviction API
        try FileManager.default.evictUbiquitousItem(at: localURL)
    }
    
    // MARK: - Private
    
    /// Polls until the iCloud file download completes or times out.
    private func waitForDownload(of url: URL, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if let downloadStatus = values.ubiquitousItemDownloadingStatus,
               downloadStatus == .current {
                return
            }
            
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        
        throw OEStorageProviderError.downloadFailed(path: url.lastPathComponent, underlying: nil)
    }
}

@available(macOS 11.0, *)
private extension Logger {
    static let cloudStorage = Logger(subsystem: "org.openemu.Bit", category: "CloudStorage")
}
