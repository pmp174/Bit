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

/// Central orchestrator for cloud storage operations.
/// Manages the active provider, sync scope, and coordinates uploads/downloads.
///
/// Users select a single provider for their library and/or saves.
/// The manager routes all storage operations through the active provider.
@objc final class OECloudStorageManager: NSObject {
    
    @objc static let shared = OECloudStorageManager()
    
    // MARK: - Notifications

    static let providerDidChangeNotification = Notification.Name("OECloudStorageProviderDidChange")
    static let statusDidChangeNotification = Notification.Name("OECloudStorageStatusDidChange")
    static let syncProgressDidChangeNotification = Notification.Name("OECloudStorageSyncProgressDidChange")

    /// Current sync progress (0.0–1.0). Observable via `syncProgressDidChangeNotification`.
    private(set) var syncProgress: Double = 0
    private(set) var syncStatusMessage: String = ""
    private(set) var isSyncing: Bool = false
    
    // MARK: - UserDefaults Keys
    
    private static let libraryProviderKey = "OECloudStorageLibraryProvider"
    private static let savesProviderKey = "OECloudStorageSavesProvider"
    private static let syncScopeKey = "OECloudStorageSyncScope"
    
    // MARK: - State
    
    /// The provider used for the game library (ROMs, box art).
    private(set) var libraryProvider: OEStorageProvider
    
    /// The provider used for saves/save states. Can differ from libraryProvider
    /// when user wants saves on cloud but library local (or vice versa).
    private(set) var savesProvider: OEStorageProvider
    
    /// What content categories are synced.
    var syncScope: OESyncScope {
        get {
            let raw = UserDefaults.standard.integer(forKey: Self.syncScopeKey)
            return raw == 0 ? .all : OESyncScope(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.syncScopeKey)
        }
    }
    
    /// All available providers, keyed by type.
    private var providers: [OEStorageProviderType: OEStorageProvider] = [:]
    
    // MARK: - Initialization
    
    private override init() {
        // Create all provider instances
        let local = OELocalStorageProvider()
        let icloud = OEiCloudStorageProvider()
        let gdrive = OEGoogleDriveStorageProvider()
        let dropbox = OEDropboxStorageProvider()
        let webdav = OEWebDAVStorageProvider()
        
        providers = [
            .local: local,
            .iCloud: icloud,
            .googleDrive: gdrive,
            .dropbox: dropbox,
            .webDAV: webdav,
        ]
        
        // Restore saved provider selection
        let libType = Self.savedProviderType(for: Self.libraryProviderKey)
        let savesType = Self.savedProviderType(for: Self.savesProviderKey)
        
        libraryProvider = providers[libType] ?? local
        savesProvider = providers[savesType] ?? local
        
        super.init()
    }
    
    // MARK: - Provider Selection
    
    /// The type of the current library provider.
    var libraryProviderType: OEStorageProviderType {
        return libraryProvider.providerType
    }
    
    /// The type of the current saves provider.
    var savesProviderType: OEStorageProviderType {
        return savesProvider.providerType
    }
    
    /// Set the provider for the library (ROMs, box art, metadata).
    func setLibraryProvider(_ type: OEStorageProviderType) {
        guard let provider = providers[type] else { return }
        libraryProvider = provider
        UserDefaults.standard.set(type.rawValue, forKey: Self.libraryProviderKey)
        NotificationCenter.default.post(name: Self.providerDidChangeNotification, object: self)
    }
    
    /// Set the provider for saves/save states.
    func setSavesProvider(_ type: OEStorageProviderType) {
        guard let provider = providers[type] else { return }
        savesProvider = provider
        UserDefaults.standard.set(type.rawValue, forKey: Self.savesProviderKey)
        NotificationCenter.default.post(name: Self.providerDidChangeNotification, object: self)
    }
    
    /// Set a single provider for both library and saves.
    func setProvider(_ type: OEStorageProviderType) {
        setLibraryProvider(type)
        setSavesProvider(type)
    }
    
    /// Get the provider instance for a given type.
    func provider(for type: OEStorageProviderType) -> OEStorageProvider? {
        return providers[type]
    }
    
    /// Whether cloud storage is active (any non-local provider selected).
    @objc var isCloudEnabled: Bool {
        return libraryProviderType != .local || savesProviderType != .local
    }
    
    // MARK: - Authentication
    
    /// Authenticate the currently selected providers.
    func authenticate() async throws {
        if libraryProviderType != .local {
            try await libraryProvider.authenticate()
        }
        if savesProviderType != .local && savesProviderType != libraryProviderType {
            try await savesProvider.authenticate()
        }
        NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
    }
    
    /// Handle an OAuth redirect URL. Routes to the appropriate provider.
    func handleOAuthRedirect(url: URL) -> Bool {
        for provider in providers.values {
            if provider.handleOAuthRedirect(url: url) {
                return true
            }
        }
        return false
    }
    
    /// Sign out of all providers and reset to local.
    func signOutAll() async {
        for provider in providers.values {
            await provider.signOut()
        }
        setProvider(.local)
        syncScope = .all
        NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
    }
    
    // MARK: - High-Level Operations
    
    /// Upload a ROM file to the cloud.
    /// - Parameters:
    ///   - localURL: Local file path.
    ///   - relativePath: Path relative to the library root (e.g., "roms/SNES/game.smc").
    /// - Returns: The cloud identifier for the file.
    @discardableResult
    func uploadROM(localURL: URL, relativePath: String) async throws -> String {
        guard syncScope.contains(.library) else { return "" }
        return try await libraryProvider.upload(localURL: localURL, toRemotePath: "Library/\(relativePath)")
    }
    
    /// Upload a save state bundle to the cloud.
    @discardableResult
    func uploadSaveState(localURL: URL, relativePath: String) async throws -> String {
        guard syncScope.contains(.saves) else { return "" }
        return try await savesProvider.upload(localURL: localURL, toRemotePath: "SaveStates/\(relativePath)")
    }
    
    /// Upload a screenshot to the cloud.
    @discardableResult
    func uploadScreenshot(localURL: URL, relativePath: String) async throws -> String {
        guard syncScope.contains(.screenshots) else { return "" }
        return try await savesProvider.upload(localURL: localURL, toRemotePath: "Screenshots/\(relativePath)")
    }
    
    /// Download a ROM from the cloud to a local path.
    func downloadROM(relativePath: String, toLocalURL localURL: URL) async throws {
        try await libraryProvider.download(remotePath: "Library/\(relativePath)", toLocalURL: localURL)
    }
    
    /// Download a save state from the cloud.
    func downloadSaveState(relativePath: String, toLocalURL localURL: URL) async throws {
        try await savesProvider.download(remotePath: "SaveStates/\(relativePath)", toLocalURL: localURL)
    }
    
    /// Delete a ROM from cloud storage.
    func deleteROM(relativePath: String) async throws {
        guard syncScope.contains(.library) else { return }
        try await libraryProvider.delete(remotePath: "Library/\(relativePath)")
    }
    
    /// Delete a save state from cloud storage.
    func deleteSaveState(relativePath: String) async throws {
        guard syncScope.contains(.saves) else { return }
        try await savesProvider.delete(remotePath: "SaveStates/\(relativePath)")
    }
    
    /// Evict the local copy of a ROM (remove local file, keep cloud copy).
    func evictROM(localURL: URL) async throws {
        guard libraryProviderType != .local else {
            throw OEStorageProviderError.providerUnavailable
        }
        try await libraryProvider.evictLocalCopy(at: localURL)
    }
    
    // MARK: - Bulk Sync

    /// Upload all existing library files to the cloud.
    /// Call this after first sign-in or when the user taps "Sync Now".
    func syncExistingLibrary() async throws {
        guard isCloudEnabled else { return }
        guard let database = OELibraryDatabase.default else { return }

        isSyncing = true
        syncProgress = 0
        syncStatusMessage = NSLocalizedString("Preparing sync…", comment: "")
        postSyncProgressNotification()

        let scope = syncScope
        var filesToUpload: [(localURL: URL, remotePath: String, category: String)] = []

        // Collect ROMs
        if scope.contains(.library), let romsURL = database.romsFolderURL {
            let romFiles = collectFiles(in: romsURL, baseURL: romsURL)
            for (url, relative) in romFiles {
                filesToUpload.append((url, "Library/\(relative)", "ROM"))
            }
        }

        // Collect save states
        if scope.contains(.saves) {
            let statesURL = database.stateFolderURL
            let stateFiles = collectFiles(in: statesURL, baseURL: statesURL)
            for (url, relative) in stateFiles {
                filesToUpload.append((url, "SaveStates/\(relative)", "Save State"))
            }
        }

        // Collect screenshots
        if scope.contains(.screenshots) {
            let screenshotsURL = database.screenshotFolderURL
            let screenshotFiles = collectFiles(in: screenshotsURL, baseURL: screenshotsURL)
            for (url, relative) in screenshotFiles {
                filesToUpload.append((url, "Screenshots/\(relative)", "Screenshot"))
            }
        }

        let totalFiles = filesToUpload.count
        guard totalFiles > 0 else {
            syncStatusMessage = NSLocalizedString("No files to sync.", comment: "")
            isSyncing = false
            postSyncProgressNotification()
            return
        }

        syncStatusMessage = String(format: NSLocalizedString("Uploading 0 of %d files…", comment: ""), totalFiles)
        postSyncProgressNotification()

        var uploadedCount = 0
        var failedCount = 0

        for (index, (localURL, remotePath, _)) in filesToUpload.enumerated() {
            let fileName = (remotePath as NSString).lastPathComponent
            let fileSize = Self.formattedFileSize(at: localURL)

            // Show which file is currently uploading
            syncProgress = Double(index) / Double(totalFiles)
            syncStatusMessage = String(
                format: NSLocalizedString("Uploading %d of %d — %@ (%@)", comment: ""),
                index + 1, totalFiles, fileName, fileSize
            )
            postSyncProgressNotification()

            do {
                // Route through the appropriate provider
                if remotePath.hasPrefix("Library/") {
                    try await libraryProvider.upload(localURL: localURL, toRemotePath: remotePath)
                } else {
                    try await savesProvider.upload(localURL: localURL, toRemotePath: remotePath)
                }
                uploadedCount += 1
            } catch {
                failedCount += 1
                if #available(macOS 11.0, *) {
                    Logger.cloudStorage.error("Failed to upload \(remotePath): \(error.localizedDescription)")
                }
            }
        }

        UserDefaults.standard.set(Date(), forKey: "OELastCloudSyncDate")

        if failedCount > 0 {
            syncStatusMessage = String(
                format: NSLocalizedString("Sync complete: %d uploaded, %d failed.", comment: ""),
                uploadedCount, failedCount
            )
        } else {
            syncStatusMessage = String(
                format: NSLocalizedString("Sync complete: %d files uploaded.", comment: ""),
                uploadedCount
            )
        }
        syncProgress = 1.0
        isSyncing = false
        postSyncProgressNotification()
        NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
    }

    // MARK: - Private

    private func postSyncProgressNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.syncProgressDidChangeNotification, object: self)
        }
    }

    /// Recursively collect all files under a directory with their relative paths.
    private func collectFiles(in directory: URL, baseURL: URL) -> [(url: URL, relativePath: String)] {
        var results: [(URL, String)] = []

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: baseURL.path + "/", with: "")
            results.append((fileURL, relativePath))
        }

        return results
    }

    private static func formattedFileSize(at url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return "unknown size"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private static func savedProviderType(for key: String) -> OEStorageProviderType {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let type = OEStorageProviderType(rawValue: raw) else {
            return .local
        }
        return type
    }
}

@available(macOS 11.0, *)
private extension Logger {
    static let cloudStorage = Logger(subsystem: "org.openemu.Bit", category: "CloudStorage")
}
