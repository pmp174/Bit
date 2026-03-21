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

/// Monitors library directories for file changes and automatically uploads
/// modified files to the active cloud storage provider.
///
/// Uses FSEvents to watch:
/// - Save States directory
/// - Battery Saves directories (per-core)
/// - ROMs directory (when full library sync is enabled)
/// - Screenshots directory
final class OEFileMonitor {
    
    static let shared = OEFileMonitor()
    
    // MARK: - State
    
    private var eventStream: FSEventStreamRef?
    private let coalesceLatency: CFTimeInterval = 2.0
    private var isRunning = false
    
    /// File extensions for save-related files.
    private static let saveExtensions: Set<String> = [
        "sav", "srm", "oesavestate", "state", "rtc", "eep", "nv", "sram"
    ]
    
    /// File extensions for screenshots.
    private static let screenshotExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff"
    ]
    
    private init() {}
    
    // MARK: - Start / Stop
    
    /// Start monitoring library directories.
    func start() {
        guard !isRunning else { return }
        guard OECloudStorageManager.shared.isCloudEnabled else { return }
        guard let database = OELibraryDatabase.default else { return }
        
        var pathsToWatch: [String] = []
        
        // Save states directory
        let statesFolderURL = database.stateFolderURL
        pathsToWatch.append(statesFolderURL.path)
        
        // Screenshots directory
        let screenshotsFolderURL = database.screenshotFolderURL
        pathsToWatch.append(screenshotsFolderURL.path)
        
        // ROMs directory (when full library sync)
        let scope = OECloudStorageManager.shared.syncScope
        if scope.contains(.library), let romsFolderURL = database.romsFolderURL {
            pathsToWatch.append(romsFolderURL.path)
        }
        
        // Application Support directory (for Battery Saves)
        let appSupportURL = database.databaseFolderURL
        pathsToWatch.append(appSupportURL.path)
        
        guard !pathsToWatch.isEmpty else { return }
        
        let cfPaths = pathsToWatch as CFArray
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        
        eventStream = FSEventStreamCreate(
            nil,
            fsEventCallback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            coalesceLatency,
            flags
        )
        
        guard let stream = eventStream else { return }
        
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        isRunning = true
        
        if #available(macOS 11.0, *) {
            Logger.fileMonitor.info("File monitor started watching \(pathsToWatch.count) paths")
        }
    }
    
    /// Stop monitoring.
    func stop() {
        guard isRunning, let stream = eventStream else { return }
        
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
        isRunning = false
        
        if #available(macOS 11.0, *) {
            Logger.fileMonitor.info("File monitor stopped")
        }
    }
    
    // MARK: - Event Handling
    
    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        let manager = OECloudStorageManager.shared
        guard manager.isCloudEnabled else { return }
        
        guard let database = OELibraryDatabase.default else { return }
        let romsFolderPath = database.romsFolderURL?.path
        let statesFolderPath = database.stateFolderURL.path
        let screenshotsFolderPath = database.screenshotFolderURL.path
        let appSupportPath = database.databaseFolderURL.path
        
        for (index, path) in paths.enumerated() {
            let eventFlags = flags[index]
            
            // Skip directory events, only care about file modifications/creations
            let isFile = (eventFlags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
            let isModified = (eventFlags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
            let isCreated = (eventFlags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
            let isRenamed = (eventFlags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
            
            guard isFile && (isModified || isCreated || isRenamed) else { continue }
            
            let fileURL = URL(fileURLWithPath: path)
            let ext = fileURL.pathExtension.lowercased()
            
            // Determine which category this file belongs to
            if path.hasPrefix(statesFolderPath) {
                // Save state files
                if Self.saveExtensions.contains(ext) || ext == "oesavestate" {
                    let relativePath = String(path.dropFirst(statesFolderPath.count + 1))
                    Task.detached(priority: .utility) {
                        try? await manager.uploadSaveState(localURL: fileURL, relativePath: relativePath)
                    }
                }
            } else if path.hasPrefix(screenshotsFolderPath) {
                // Screenshot files
                if Self.screenshotExtensions.contains(ext) {
                    let relativePath = String(path.dropFirst(screenshotsFolderPath.count + 1))
                    Task.detached(priority: .utility) {
                        try? await manager.uploadScreenshot(localURL: fileURL, relativePath: relativePath)
                    }
                }
            } else if let romsPath = romsFolderPath, path.hasPrefix(romsPath) {
                // ROM files (only when full library sync)
                if manager.syncScope.contains(.library) {
                    let relativePath = String(path.dropFirst(romsPath.count + 1))
                    Task.detached(priority: .utility) {
                        try? await manager.uploadROM(localURL: fileURL, relativePath: relativePath)
                    }
                }
            } else if path.hasPrefix(appSupportPath) && path.contains("Battery Saves") {
                // Battery save files — upload as save states
                if Self.saveExtensions.contains(ext) {
                    // Extract relative path from Battery Saves onwards
                    if let range = path.range(of: "Battery Saves/") {
                        let relativePath = "BatterySaves/" + String(path[range.upperBound...])
                        Task.detached(priority: .utility) {
                            try? await manager.uploadSaveState(localURL: fileURL, relativePath: relativePath)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - FSEvents Callback

private func fsEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let monitor = Unmanaged<OEFileMonitor>.fromOpaque(info).takeUnretainedValue()
    
    guard let cfArray = unsafeBitCast(eventPaths, to: CFArray?.self) else { return }
    let count = CFArrayGetCount(cfArray)
    
    var paths = [String]()
    var flags = [FSEventStreamEventFlags]()
    
    for i in 0..<min(numEvents, count) {
        if let cfStr = CFArrayGetValueAtIndex(cfArray, i) {
            let str = unsafeBitCast(cfStr, to: CFString.self) as String
            paths.append(str)
            flags.append(eventFlags[i])
        }
    }
    
    monitor.handleEvents(paths: paths, flags: flags)
}

@available(macOS 11.0, *)
private extension Logger {
    static let fileMonitor = Logger(subsystem: "org.openemu.Bit", category: "FileMonitor")
}
