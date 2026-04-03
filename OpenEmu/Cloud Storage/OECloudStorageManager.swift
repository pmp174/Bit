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

// MARK: - Cloud Library Manifest

/// Metadata manifest uploaded alongside ROMs to enable cross-device library sync
/// without downloading actual ROM files.
struct OECloudLibraryManifest: Codable {
    let version: Int
    let lastUpdated: Date
    var entries: [Entry]

    struct Entry: Codable {
        /// Relative path within the cloud Library/ folder (e.g., "game.smc")
        let relativePath: String
        /// The system identifier (e.g., "openemu.system.snes")
        let systemIdentifier: String
        /// The user-facing game name
        let gameName: String
        /// MD5 hash if available (enables dedup on pull)
        let md5: String?
        /// File size in bytes
        let fileSize: Int64
    }

    static let currentVersion = 1
    static let remotePath = "Library/.oe-manifest.json"
}

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
    /// Note: `relativePath` may be percent-encoded (from Core Data's `rom.location`),
    /// so we decode it to match the filesystem paths used during upload.
    func downloadROM(relativePath: String, toLocalURL localURL: URL) async throws {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        try await libraryProvider.download(remotePath: "Library/\(decoded)", toLocalURL: localURL)
    }

    /// Download a save state from the cloud.
    func downloadSaveState(relativePath: String, toLocalURL localURL: URL) async throws {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        try await savesProvider.download(remotePath: "SaveStates/\(decoded)", toLocalURL: localURL)
    }

    /// Delete a ROM from cloud storage.
    func deleteROM(relativePath: String) async throws {
        guard syncScope.contains(.library) else { return }
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        try await libraryProvider.delete(remotePath: "Library/\(decoded)")
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

    /// Upload library files to the cloud, skipping files already present remotely.
    /// Uploads smaller files first and uses concurrent uploads for speed.
    func syncExistingLibrary() async throws {
        guard isCloudEnabled else { return }
        guard let database = OELibraryDatabase.default else { return }

        isSyncing = true
        syncProgress = 0
        syncStatusMessage = NSLocalizedString("Preparing sync…", comment: "")
        postSyncProgressNotification()

        let scope = syncScope
        var filesToUpload: [(localURL: URL, remotePath: String, category: String, fileSize: Int64)] = []

        // Collect ROMs
        if scope.contains(.library), let romsURL = database.romsFolderURL {
            let romFiles = collectFiles(in: romsURL, baseURL: romsURL)
            for (url, relative) in romFiles {
                let size = Self.rawFileSize(at: url)
                filesToUpload.append((url, "Library/\(relative)", "ROM", size))
            }
        }

        // Collect save states
        if scope.contains(.saves) {
            let statesURL = database.stateFolderURL
            let stateFiles = collectFiles(in: statesURL, baseURL: statesURL)
            for (url, relative) in stateFiles {
                let size = Self.rawFileSize(at: url)
                filesToUpload.append((url, "SaveStates/\(relative)", "Save State", size))
            }
        }

        // Collect screenshots
        if scope.contains(.screenshots) {
            let screenshotsURL = database.screenshotFolderURL
            let screenshotFiles = collectFiles(in: screenshotsURL, baseURL: screenshotsURL)
            for (url, relative) in screenshotFiles {
                let size = Self.rawFileSize(at: url)
                filesToUpload.append((url, "Screenshots/\(relative)", "Screenshot", size))
            }
        }

        guard !filesToUpload.isEmpty else {
            syncStatusMessage = NSLocalizedString("No files to sync.", comment: "")
            isSyncing = false
            postSyncProgressNotification()
            return
        }

        // Phase 1: Check which files already exist on the cloud
        syncStatusMessage = NSLocalizedString("Checking cloud files…", comment: "")
        postSyncProgressNotification()

        var remoteFileSet = Set<String>()
        let categoriesToCheck = Set(filesToUpload.map { ($0.remotePath as NSString).pathComponents.first ?? "" })

        for category in categoriesToCheck {
            do {
                let provider = category == "Library" ? libraryProvider : savesProvider
                let remoteFiles = try await provider.listRecursive(remotePath: category)
                for file in remoteFiles {
                    remoteFileSet.insert(file.path)
                }
            } catch {
                if #available(macOS 11.0, *) {
                    Logger.cloudStorage.warning("Could not list remote files for \(category): \(error.localizedDescription)")
                }
            }
        }

        // Filter out files already present on the cloud
        let skippedCount = filesToUpload.count
        let alreadySyncedFiles = filesToUpload.filter { remoteFileSet.contains($0.remotePath) }
        filesToUpload = filesToUpload.filter { !remoteFileSet.contains($0.remotePath) }
        let actualSkipped = skippedCount - filesToUpload.count

        // Mark ROMs that are already synced with a cloudIdentifier so they can be re-downloaded
        if !alreadySyncedFiles.isEmpty {
            let context = database.mainThreadContext
            context.performAndWait {
                for file in alreadySyncedFiles where file.category == "ROM" {
                    if let rom = try? OEDBRom.rom(with: file.localURL, in: context),
                       rom.cloudIdentifier == nil {
                        rom.cloudIdentifier = file.remotePath
                    }
                }
                try? context.save()
            }
        }

        guard !filesToUpload.isEmpty else {
            syncStatusMessage = String(
                format: NSLocalizedString("Already synced — %d files up to date.", comment: ""),
                actualSkipped
            )
            syncProgress = 1.0
            isSyncing = false
            postSyncProgressNotification()
            NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
            return
        }

        // Phase 2: Sort by size ascending (smaller files first for faster perceived progress)
        filesToUpload.sort { $0.fileSize < $1.fileSize }

        let totalFiles = filesToUpload.count

        // Phase 3: Pre-create remote directories to avoid race conditions
        let uniqueParentPaths = Set(filesToUpload.map {
            ($0.remotePath as NSString).deletingLastPathComponent
        })
        for parentPath in uniqueParentPaths.sorted() {
            let provider = parentPath.hasPrefix("Library") ? libraryProvider : savesProvider
            try? await provider.ensureRemoteDirectory(path: parentPath)
        }

        // Phase 4: Upload concurrently.
        // Dropbox rate-limits at ~4 concurrent writes, so use 2 for Dropbox, 4 for others.
        let maxConcurrency = (libraryProviderType == .dropbox) ? 2 : 4
        syncStatusMessage = String(
            format: NSLocalizedString("Uploading 0 of %d files (%d already synced)…", comment: ""),
            totalFiles, actualSkipped
        )
        postSyncProgressNotification()

        let tracker = UploadProgressTracker(totalFiles: totalFiles)

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0

            for (localURL, remotePath, category, _) in filesToUpload {
                if inFlight >= maxConcurrency {
                    await group.next()
                    inFlight -= 1
                }

                inFlight += 1
                group.addTask { [weak self] in
                    guard let self else { return }
                    let fileName = (remotePath as NSString).lastPathComponent
                    let fileSize = Self.formattedFileSize(at: localURL)

                    do {
                        let provider = remotePath.hasPrefix("Library/") ? self.libraryProvider : self.savesProvider
                        let cloudId = try await provider.upload(localURL: localURL, toRemotePath: remotePath)
                        let completed = await tracker.recordSuccess()

                        await MainActor.run {
                            self.syncProgress = Double(completed) / Double(totalFiles)
                            self.syncStatusMessage = String(
                                format: NSLocalizedString("Uploaded %d of %d — %@ (%@)", comment: ""),
                                completed, totalFiles, fileName, fileSize
                            )
                            self.postSyncProgressNotification()

                            // Persist cloudIdentifier on the ROM so it can be re-downloaded later
                            if category == "ROM" {
                                let context = database.mainThreadContext
                                context.performAndWait {
                                    if let rom = try? OEDBRom.rom(with: localURL, in: context) {
                                        rom.cloudIdentifier = cloudId.isEmpty ? remotePath : cloudId
                                        try? context.save()
                                    }
                                }
                            }
                        }
                    } catch {
                        _ = await tracker.recordFailure()
                        if #available(macOS 11.0, *) {
                            Logger.cloudStorage.error("Failed to upload \(remotePath): \(error.localizedDescription)")
                        }
                    }
                }
            }

            await group.waitForAll()
        }

        let counts = await tracker.counts
        let uploadedCount = counts.uploaded
        let failedCount = counts.failed

        UserDefaults.standard.set(Date(), forKey: "OELastCloudSyncDate")

        if failedCount > 0 {
            syncStatusMessage = String(
                format: NSLocalizedString("Sync complete: %d uploaded, %d failed, %d already synced.", comment: ""),
                uploadedCount, failedCount, actualSkipped
            )
        } else if actualSkipped > 0 {
            syncStatusMessage = String(
                format: NSLocalizedString("Sync complete: %d uploaded, %d already synced.", comment: ""),
                uploadedCount, actualSkipped
            )
        } else {
            syncStatusMessage = String(
                format: NSLocalizedString("Sync complete: %d files uploaded.", comment: ""),
                uploadedCount
            )
        }
        // Upload manifest for cross-device metadata sync
        try? await uploadManifest()

        syncProgress = 1.0
        isSyncing = false
        postSyncProgressNotification()
        NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
    }

    /// Download all cloud-backed ROMs to local storage.
    /// Used before switching providers or reverting to local storage.
    func downloadEntireLibrary(progressHandler: @escaping (_ completed: Int, _ total: Int, _ fileName: String) -> Void) async -> (downloaded: Int, failed: Int) {
        guard isCloudEnabled else { return (0, 0) }
        guard let database = OELibraryDatabase.default else { return (0, 0) }

        let context = database.mainThreadContext
        let roms: [OEDBRom] = context.performAndWait {
            let fetchRequest = OEDBRom.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "cloudIdentifier != nil")
            return (try? context.fetch(fetchRequest) as? [OEDBRom]) ?? []
        }

        // Filter to ROMs whose local file is missing
        let romsToDownload = roms.filter { rom in
            guard let url = rom.url else { return true }
            return (try? url.checkResourceIsReachable()) != true
        }

        guard !romsToDownload.isEmpty else { return (0, 0) }

        let total = romsToDownload.count
        let tracker = UploadProgressTracker(totalFiles: total) // reuse for counting

        await withTaskGroup(of: Void.self) { group in
            let maxConcurrency = 4
            var inFlight = 0

            for rom in romsToDownload {
                if inFlight >= maxConcurrency {
                    await group.next()
                    inFlight -= 1
                }

                inFlight += 1
                group.addTask {
                    guard let location = rom.location,
                          let romFolderURL = database.romsFolderURL,
                          let localURL = URL(string: location, relativeTo: romFolderURL) else {
                        _ = await tracker.recordFailure()
                        return
                    }

                    // Ensure parent directory exists
                    let parentDir = localURL.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                    let fileName = (location as NSString).lastPathComponent

                    do {
                        let decoded = location.removingPercentEncoding ?? location
                        try await self.libraryProvider.download(
                            remotePath: "Library/\(decoded)",
                            toLocalURL: localURL
                        )
                        let completed = await tracker.recordSuccess()

                        await MainActor.run {
                            rom.setDownloaded(true)
                            progressHandler(completed, total, fileName)
                        }
                    } catch {
                        _ = await tracker.recordFailure()
                    }
                }
            }

            await group.waitForAll()
        }

        let counts = await tracker.counts
        return (counts.uploaded, counts.failed) // uploaded == downloaded in this context
    }

    // MARK: - Cloud Library Metadata Pull

    /// Pull cloud library metadata and create local catalog entries for ROMs
    /// not yet in the database. Does NOT download ROM files — they remain
    /// cloud-only until the user launches them.
    ///
    /// Triggered automatically after authentication and optionally via "Sync Now".
    func pullCloudLibrary() async throws {
        guard isCloudEnabled else { return }
        guard syncScope.contains(.library) else { return }
        guard let database = OELibraryDatabase.default else { return }
        guard !isSyncing else { return }

        isSyncing = true
        syncProgress = 0
        syncStatusMessage = NSLocalizedString("Checking cloud library\u{2026}", comment: "")
        postSyncProgressNotification()

        // Step 1: Try to download and parse the manifest
        var manifestEntries: [String: OECloudLibraryManifest.Entry] = [:]
        do {
            let tempManifestURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("oe-manifest-pull.json")
            defer { try? FileManager.default.removeItem(at: tempManifestURL) }

            try await libraryProvider.download(
                remotePath: OECloudLibraryManifest.remotePath,
                toLocalURL: tempManifestURL
            )
            let data = try Data(contentsOf: tempManifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(OECloudLibraryManifest.self, from: data)
            for entry in manifest.entries {
                manifestEntries[entry.relativePath] = entry
            }
        } catch {
            // Manifest not found or unparseable — fall back to extension-only detection
            if #available(macOS 11.0, *) {
                Logger.cloudStorage.info("No manifest found, using extension-only detection: \(error.localizedDescription)")
            }
        }

        // Step 2: List all files in cloud Library/ directory
        syncStatusMessage = NSLocalizedString("Listing cloud files\u{2026}", comment: "")
        postSyncProgressNotification()

        let remoteFiles: [OECloudFileInfo]
        do {
            remoteFiles = try await libraryProvider.listRecursive(remotePath: "Library")
        } catch {
            isSyncing = false
            syncStatusMessage = NSLocalizedString("Could not list cloud library.", comment: "")
            postSyncProgressNotification()
            throw error
        }

        // Filter to actual ROM files (exclude manifest, hidden files, directories)
        let romFiles = remoteFiles.filter { file in
            !file.isDirectory
            && !file.name.hasPrefix(".")
            && file.name != ".oe-manifest.json"
        }

        guard !romFiles.isEmpty else {
            syncStatusMessage = NSLocalizedString("Cloud library is empty.", comment: "")
            syncProgress = 1.0
            isSyncing = false
            postSyncProgressNotification()
            return
        }

        // Step 3: Create Core Data entries for new ROMs
        syncStatusMessage = String(
            format: NSLocalizedString("Processing %d cloud files\u{2026}", comment: ""),
            romFiles.count
        )
        postSyncProgressNotification()

        let context = database.mainThreadContext
        var createdCount = 0
        var skippedCount = 0

        context.performAndWait {
            for file in romFiles {
                // Derive relativePath by stripping "Library/" prefix
                let cloudRemotePath = file.path
                let relativePath: String
                if cloudRemotePath.hasPrefix("Library/") {
                    relativePath = String(cloudRemotePath.dropFirst("Library/".count))
                } else {
                    relativePath = cloudRemotePath
                }

                // Dedup check 1: ROM with this cloudIdentifier already exists
                if let existing = try? OEDBRom.rom(withCloudIdentifier: cloudRemotePath, in: context),
                   existing.game != nil {
                    skippedCount += 1
                    continue
                }

                let manifestEntry = manifestEntries[relativePath]

                // Dedup check 2: ROM with matching md5 (from manifest)
                if let md5 = manifestEntry?.md5, !md5.isEmpty,
                   let existing = try? OEDBRom.rom(withMD5HashString: md5, in: context) {
                    if existing.cloudIdentifier == nil {
                        existing.cloudIdentifier = cloudRemotePath
                    }
                    skippedCount += 1
                    continue
                }

                // Dedup check 3: ROM with matching location URL
                let percentEncodedRelative = relativePath.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? relativePath
                if let romFolderURL = database.romsFolderURL,
                   let localURL = URL(string: percentEncodedRelative, relativeTo: romFolderURL),
                   let existing = try? OEDBRom.rom(with: localURL, in: context),
                   existing.game != nil {
                    if existing.cloudIdentifier == nil {
                        existing.cloudIdentifier = cloudRemotePath
                    }
                    skippedCount += 1
                    continue
                }

                // Determine system
                let fileExtension = (file.name as NSString).pathExtension
                let system: OEDBSystem?

                if let manifestSystemId = manifestEntry?.systemIdentifier {
                    system = OEDBSystem.system(for: manifestSystemId, in: context)
                } else {
                    let candidates = OEDBSystem.systemsForFileExtension(fileExtension, in: context)
                    system = candidates.first
                }

                guard let resolvedSystem = system else {
                    if #available(macOS 11.0, *) {
                        Logger.cloudStorage.warning("Skipping cloud file with unknown extension: \(file.name)")
                    }
                    continue
                }

                // Create OEDBRom
                let rom = OEDBRom.createObject(in: context)
                rom.cloudIdentifier = cloudRemotePath
                rom.location = percentEncodedRelative
                rom.fileName = file.name
                rom.fileSize = NSNumber(value: file.size)
                rom.isDownloaded = NSNumber(value: false)

                if let md5 = manifestEntry?.md5, !md5.isEmpty {
                    rom.md5 = md5.lowercased()
                }

                // Create OEDBGame
                let gameName: String
                if let manifestName = manifestEntry?.gameName, !manifestName.isEmpty {
                    gameName = manifestName
                } else {
                    gameName = (file.name as NSString).deletingPathExtension
                }

                let game = OEDBGame.createGame(
                    withName: gameName,
                    andSystem: resolvedSystem,
                    in: context
                )
                rom.game = game

                createdCount += 1
            }

            // Update progress periodically
            self.syncProgress = 1.0
            try? context.save()
        }

        // Step 4: Finalize
        UserDefaults.standard.set(Date(), forKey: "OELastCloudPullDate")

        if createdCount > 0 {
            syncStatusMessage = String(
                format: NSLocalizedString("Added %d games from cloud (%d already synced).", comment: ""),
                createdCount, skippedCount
            )
        } else {
            syncStatusMessage = String(
                format: NSLocalizedString("Library up to date (%d games synced).", comment: ""),
                skippedCount
            )
        }

        syncProgress = 1.0
        isSyncing = false
        postSyncProgressNotification()
        NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
    }

    // MARK: - Manifest Upload

    /// Build and upload a JSON manifest of all ROMs in the cloud library.
    /// Called after `syncExistingLibrary()` to enable cross-device metadata pull.
    private func uploadManifest() async throws {
        guard let database = OELibraryDatabase.default else { return }

        let context = database.mainThreadContext
        let entries: [OECloudLibraryManifest.Entry] = context.performAndWait {
            let fetchRequest = OEDBRom.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "cloudIdentifier != nil")
            guard let roms = try? context.fetch(fetchRequest) as? [OEDBRom] else { return [] }

            return roms.compactMap { rom -> OECloudLibraryManifest.Entry? in
                guard let location = rom.location,
                      let systemId = rom.game?.system?.systemIdentifier,
                      let gameName = rom.game?.displayName
                else { return nil }

                return OECloudLibraryManifest.Entry(
                    relativePath: location.removingPercentEncoding ?? location,
                    systemIdentifier: systemId,
                    gameName: gameName,
                    md5: rom.md5,
                    fileSize: rom.fileSize?.int64Value ?? 0
                )
            }
        }

        let manifest = OECloudLibraryManifest(
            version: OECloudLibraryManifest.currentVersion,
            lastUpdated: Date(),
            entries: entries
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oe-manifest.json")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await libraryProvider.upload(
            localURL: tempURL,
            toRemotePath: OECloudLibraryManifest.remotePath
        )
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
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: rawFileSize(at: url))
    }

    private static func rawFileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    private static func savedProviderType(for key: String) -> OEStorageProviderType {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let type = OEStorageProviderType(rawValue: raw) else {
            return .local
        }
        return type
    }
}

// MARK: - Upload Progress Tracker

private actor UploadProgressTracker {
    private(set) var uploaded = 0
    private(set) var failed = 0
    let totalFiles: Int

    init(totalFiles: Int) { self.totalFiles = totalFiles }

    func recordSuccess() -> Int {
        uploaded += 1
        return uploaded
    }

    func recordFailure() -> Int {
        failed += 1
        return failed
    }

    var counts: (uploaded: Int, failed: Int) {
        return (uploaded, failed)
    }
}

@available(macOS 11.0, *)
private extension Logger {
    static let cloudStorage = Logger(subsystem: "org.openemu.Bit", category: "CloudStorage")
}
