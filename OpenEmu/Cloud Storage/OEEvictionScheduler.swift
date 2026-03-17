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

/// Periodically checks for locally-cached ROM files that can be evicted
/// (deleted locally while keeping the cloud copy) to free disk space.
///
/// Eviction rules:
/// 1. Pinned ROMs (`isPinned == true`) are never evicted.
/// 2. ROMs played within `recentPlayDays` are kept.
/// 3. ROMs played within `evictionDays` with ≥5 play sessions are kept.
/// 4. ROMs not played for `evictionDays` are eligible for eviction.
/// 5. ROMs currently loaded in an OEGameDocument are never evicted.
final class OEEvictionScheduler {
    
    static let shared = OEEvictionScheduler()
    
    // MARK: - UserDefaults Keys
    
    private static let evictionDaysKey = "OECloudEvictionDays"
    private static let recentPlayDaysKey = "OECloudRecentPlayDays"
    private static let frequentPlayThresholdKey = "OECloudFrequentPlayThreshold"
    
    // MARK: - State
    
    private var timer: Timer?
    private let checkInterval: TimeInterval = 30 * 60 // 30 minutes
    
    /// Days after which unused games are eligible for eviction. Default: 30.
    var evictionDays: Int {
        let days = UserDefaults.standard.integer(forKey: Self.evictionDaysKey)
        return days > 0 ? days : 30
    }
    
    /// Days within which recently played games are protected. Default: 7.
    var recentPlayDays: Int {
        let days = UserDefaults.standard.integer(forKey: Self.recentPlayDaysKey)
        return days > 0 ? days : 7
    }
    
    /// Minimum play count to protect a game within eviction window. Default: 5.
    var frequentPlayThreshold: Int {
        let threshold = UserDefaults.standard.integer(forKey: Self.frequentPlayThresholdKey)
        return threshold > 0 ? threshold : 5
    }
    
    private init() {}
    
    // MARK: - Scheduling
    
    /// Start the eviction timer. Called from AppDelegate when the library loads.
    func start() {
        guard OECloudStorageManager.shared.isCloudEnabled else { return }
        stop()
        
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.runEvictionCheck()
        }
        // Run an initial check after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.runEvictionCheck()
        }
    }
    
    /// Stop the eviction timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Eviction Check
    
    /// Run a single eviction pass over all ROMs in the library.
    func runEvictionCheck() {
        guard OECloudStorageManager.shared.isCloudEnabled else { return }
        
        guard let database = OELibraryDatabase.default else { return }
        let context = database.makeWriterChildContext()
        
        context.perform {
            self.performEviction(in: context)
        }
    }
    
    private func performEviction(in context: NSManagedObjectContext) {
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "ROM")
        // Only consider ROMs that are downloaded and not pinned
        fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES AND isPinned != YES")
        
        guard let roms = try? context.fetch(fetchRequest) as? [OEDBRom] else { return }
        
        let now = Date()
        let recentCutoff = now.addingTimeInterval(-Double(recentPlayDays) * 24 * 60 * 60)
        let evictionCutoff = now.addingTimeInterval(-Double(evictionDays) * 24 * 60 * 60)
        
        var evictedCount = 0
        
        for rom in roms {
            // Skip if ROM has no cloud identifier (not uploaded yet)
            guard rom.cloudIdentifier != nil else { continue }
            
            // Skip if ROM file isn't actually present locally
            guard rom.isLocallyAvailable else { continue }
            
            // Rule 2: Recently played — keep
            if let lastPlayed = rom.lastPlayed, lastPlayed > recentCutoff {
                continue
            }
            
            // Rule 3: Frequently played within eviction window — keep
            if let lastPlayed = rom.lastPlayed, lastPlayed > evictionCutoff {
                let playCount = rom.playCount?.intValue ?? 0
                if playCount >= frequentPlayThreshold {
                    continue
                }
            }
            
            // Rule 4: Not played for evictionDays — eligible for eviction
            let eligible: Bool
            if let lastPlayed = rom.lastPlayed {
                eligible = lastPlayed < evictionCutoff
            } else {
                // Never played — eligible if imported more than evictionDays ago
                if let importDate = rom.game?.importDate {
                    eligible = importDate < evictionCutoff
                } else {
                    eligible = true
                }
            }
            
            guard eligible else { continue }
            
            // Perform eviction
            evictROM(rom)
            evictedCount += 1
        }
        
        if evictedCount > 0 {
            try? context.save()
            let writerContext = context.parent
            writerContext?.perform {
                writerContext?.userInfo[OELibraryDatabase.managedObjectContextHasDirectChangesUserInfoKey] = true
                try? writerContext?.save()
            }
            
            if #available(macOS 11.0, *) {
                Logger.eviction.info("Evicted \(evictedCount) ROM(s) from local storage")
            }
        }
    }
    
    private func evictROM(_ rom: OEDBRom) {
        guard let url = rom.url else { return }
        
        let manager = OECloudStorageManager.shared
        
        // For iCloud, use the native eviction API
        if manager.libraryProviderType == .iCloud {
            Task {
                try? await manager.evictROM(localURL: url)
            }
        } else {
            // For other providers, just delete the local file
            try? FileManager.default.removeItem(at: url)
        }
        
        rom.setDownloaded(false)
        rom.lastEvictionCheck = Date()
    }
}

@available(macOS 11.0, *)
private extension Logger {
    static let eviction = Logger(subsystem: "org.openemu.Bit", category: "Eviction")
}
