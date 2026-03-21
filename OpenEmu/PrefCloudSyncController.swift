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

import Cocoa

final class PrefCloudSyncController: NSViewController {
    
    // MARK: - UI Elements
    
    private var providerPopup: NSPopUpButton!
    private var savesOnlyRadio: NSButton!
    private var fullLibraryRadio: NSButton!
    private var providerSettingsBox: NSBox!
    private var statusLabel: NSTextField!
    private var statusIndicator: NSTextField!
    private var evictionDaysStepper: NSStepper!
    private var evictionDaysLabel: NSTextField!
    private var recentPlayDaysStepper: NSStepper!
    private var recentPlayDaysLabel: NSTextField!
    private var syncNowButton: NSButton!
    
    // WebDAV-specific
    private var webDAVURLField: NSTextField!
    private var webDAVUserField: NSTextField!
    private var webDAVPassField: NSSecureTextField!
    private var webDAVSaveButton: NSButton!
    
    // OAuth-specific
    private var signInButton: NSButton!
    private var signOutButton: NSButton!
    
    private var providerSettingsContainer: NSStackView!
    
    private let manager = OECloudStorageManager.shared
    
    // MARK: - UserDefaults Keys
    
    private static let evictionDaysKey = "OECloudEvictionDays"
    private static let recentPlayDaysKey = "OECloudRecentPlayDays"
    
    // MARK: - Lifecycle
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 560))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.widthAnchor.constraint(equalToConstant: 420),
        ])
        
        // ── PROVIDER SECTION ──────────────────────────────────────
        let providerHeader = makeSectionHeader("Storage Provider")
        container.addArrangedSubview(providerHeader)
        container.setCustomSpacing(12, after: providerHeader)
        
        let providerGrid = buildProviderSection()
        container.addArrangedSubview(providerGrid)
        container.setCustomSpacing(20, after: providerGrid)
        
        // ── SYNC SCOPE SECTION ────────────────────────────────────
        let scopeHeader = makeSectionHeader("What to Sync")
        container.addArrangedSubview(scopeHeader)
        container.setCustomSpacing(12, after: scopeHeader)
        
        let scopeStack = buildSyncScopeSection()
        container.addArrangedSubview(scopeStack)
        container.setCustomSpacing(20, after: scopeStack)
        
        // ── PROVIDER SETTINGS ─────────────────────────────────────
        providerSettingsContainer = NSStackView()
        providerSettingsContainer.orientation = .vertical
        providerSettingsContainer.alignment = .leading
        providerSettingsContainer.spacing = 8
        providerSettingsContainer.translatesAutoresizingMaskIntoConstraints = false

        providerSettingsBox = NSBox()
        providerSettingsBox.title = "Provider Settings"
        providerSettingsBox.translatesAutoresizingMaskIntoConstraints = false
        providerSettingsBox.contentView?.addSubview(providerSettingsContainer)

        if let contentView = providerSettingsBox.contentView {
            NSLayoutConstraint.activate([
                providerSettingsContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
                providerSettingsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                providerSettingsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                providerSettingsContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        container.addArrangedSubview(providerSettingsBox)
        NSLayoutConstraint.activate([
            providerSettingsBox.widthAnchor.constraint(equalTo: container.widthAnchor),
        ])
        container.setCustomSpacing(20, after: providerSettingsBox)
        
        // ── STATUS SECTION ────────────────────────────────────────
        let statusHeader = makeSectionHeader("Status")
        container.addArrangedSubview(statusHeader)
        container.setCustomSpacing(8, after: statusHeader)
        
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        
        statusIndicator = NSTextField(labelWithString: "●")
        statusIndicator.font = .systemFont(ofSize: 12)
        statusIndicator.textColor = .systemGray
        statusRow.addArrangedSubview(statusIndicator)
        
        statusLabel = NSTextField(labelWithString: "Not connected")
        statusLabel.font = .systemFont(ofSize: 12)
        statusRow.addArrangedSubview(statusLabel)
        
        container.addArrangedSubview(statusRow)
        container.setCustomSpacing(20, after: statusRow)
        
        // ── EVICTION SECTION ──────────────────────────────────────
        let evictionHeader = makeSectionHeader("Eviction")
        container.addArrangedSubview(evictionHeader)
        container.setCustomSpacing(12, after: evictionHeader)
        
        let evictionGrid = buildEvictionSection()
        container.addArrangedSubview(evictionGrid)
        container.setCustomSpacing(20, after: evictionGrid)
        
        // ── SYNC NOW BUTTON ───────────────────────────────────────
        syncNowButton = NSButton(title: "Sync Now", target: self, action: #selector(syncNow(_:)))
        container.addArrangedSubview(syncNowButton)
        
        // Update UI based on current state
        updateProviderSettings()
        updateStatus()
        updateSyncScopeSelection()
        
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusDidChange(_:)),
            name: OECloudStorageManager.statusDidChangeNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Section Header
    
    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }
    
    // MARK: - Provider Section
    
    private func buildProviderSection() -> NSView {
        let gridView = NSGridView(numberOfColumns: 2, rows: 0)
        gridView.column(at: 0).xPlacement = .trailing
        gridView.rowAlignment = .firstBaseline
        gridView.columnSpacing = 8
        gridView.rowSpacing = 12
        
        let providerLabel = NSTextField(labelWithString: NSLocalizedString("Provider:", comment: ""))
        providerLabel.alignment = .right
        
        providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: [
            NSLocalizedString("Local (No Cloud)", comment: ""),
            NSLocalizedString("iCloud Drive", comment: ""),
            NSLocalizedString("Google Drive", comment: ""),
            NSLocalizedString("Dropbox", comment: ""),
            NSLocalizedString("WebDAV / NAS", comment: ""),
        ])
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        
        // Select current provider
        switch manager.libraryProviderType {
        case .local:       providerPopup.selectItem(at: 0)
        case .iCloud:      providerPopup.selectItem(at: 1)
        case .googleDrive: providerPopup.selectItem(at: 2)
        case .dropbox:     providerPopup.selectItem(at: 3)
        case .webDAV:      providerPopup.selectItem(at: 4)
        }
        
        gridView.addRow(with: [providerLabel, providerPopup])
        
        return gridView
    }
    
    // MARK: - Sync Scope Section
    
    private func buildSyncScopeSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        
        savesOnlyRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Saves only (battery saves + save states)", comment: ""),
                                   target: self, action: #selector(syncScopeChanged(_:)))
        savesOnlyRadio.tag = 0
        
        fullLibraryRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Entire library (ROMs + saves + screenshots)", comment: ""),
                                     target: self, action: #selector(syncScopeChanged(_:)))
        fullLibraryRadio.tag = 1
        
        stack.addArrangedSubview(savesOnlyRadio)
        stack.addArrangedSubview(fullLibraryRadio)
        
        return stack
    }
    
    private func updateSyncScopeSelection() {
        let scope = manager.syncScope
        if scope == .all {
            fullLibraryRadio.state = .on
            savesOnlyRadio.state = .off
        } else {
            savesOnlyRadio.state = .on
            fullLibraryRadio.state = .off
        }
    }
    
    // MARK: - Eviction Section
    
    private func buildEvictionSection() -> NSView {
        let gridView = NSGridView(numberOfColumns: 2, rows: 0)
        gridView.column(at: 0).xPlacement = .trailing
        gridView.rowAlignment = .firstBaseline
        gridView.columnSpacing = 8
        gridView.rowSpacing = 12
        
        let defaults = UserDefaults.standard
        
        // Eviction days
        let evictionLabel = NSTextField(labelWithString: NSLocalizedString("Auto-remove unused games after:", comment: ""))
        evictionLabel.alignment = .right
        
        let evictionRow = NSStackView()
        evictionRow.orientation = .horizontal
        evictionRow.spacing = 4
        
        let currentEvictionDays = defaults.integer(forKey: Self.evictionDaysKey)
        let evictionDays = currentEvictionDays > 0 ? currentEvictionDays : 30
        
        evictionDaysLabel = NSTextField(labelWithString: "\(evictionDays) days")
        evictionDaysLabel.font = .systemFont(ofSize: 12)
        
        evictionDaysStepper = NSStepper()
        evictionDaysStepper.minValue = 7
        evictionDaysStepper.maxValue = 365
        evictionDaysStepper.increment = 7
        evictionDaysStepper.integerValue = evictionDays
        evictionDaysStepper.target = self
        evictionDaysStepper.action = #selector(evictionDaysChanged(_:))
        
        evictionRow.addArrangedSubview(evictionDaysLabel)
        evictionRow.addArrangedSubview(evictionDaysStepper)
        
        gridView.addRow(with: [evictionLabel, evictionRow])
        
        // Recent play protection
        let recentLabel = NSTextField(labelWithString: NSLocalizedString("Keep recently played games:", comment: ""))
        recentLabel.alignment = .right
        
        let recentRow = NSStackView()
        recentRow.orientation = .horizontal
        recentRow.spacing = 4
        
        let currentRecentDays = defaults.integer(forKey: Self.recentPlayDaysKey)
        let recentDays = currentRecentDays > 0 ? currentRecentDays : 7
        
        recentPlayDaysLabel = NSTextField(labelWithString: "\(recentDays) days")
        recentPlayDaysLabel.font = .systemFont(ofSize: 12)
        
        recentPlayDaysStepper = NSStepper()
        recentPlayDaysStepper.minValue = 1
        recentPlayDaysStepper.maxValue = 90
        recentPlayDaysStepper.increment = 1
        recentPlayDaysStepper.integerValue = recentDays
        recentPlayDaysStepper.target = self
        recentPlayDaysStepper.action = #selector(recentPlayDaysChanged(_:))
        
        recentRow.addArrangedSubview(recentPlayDaysLabel)
        recentRow.addArrangedSubview(recentPlayDaysStepper)
        
        gridView.addRow(with: [recentLabel, recentRow])
        
        return gridView
    }
    
    // MARK: - Provider Settings
    
    private func updateProviderSettings() {
        // Remove all existing subviews
        providerSettingsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
        let type = selectedProviderType()
        
        switch type {
        case .local:
            let label = NSTextField(labelWithString: NSLocalizedString("Games are stored locally only. No cloud sync.", comment: ""))
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            providerSettingsContainer.addArrangedSubview(label)
            
        case .iCloud:
            let label = NSTextField(labelWithString: NSLocalizedString("Uses your iCloud Drive storage. Ensure iCloud is enabled in System Settings.", comment: ""))
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 380
            providerSettingsContainer.addArrangedSubview(label)
            
            signInButton = NSButton(title: "Enable iCloud Sync", target: self, action: #selector(signIn(_:)))
            providerSettingsContainer.addArrangedSubview(signInButton)
            
        case .googleDrive:
            buildOAuthSettings(providerName: "Google Drive")
            
        case .dropbox:
            buildOAuthSettings(providerName: "Dropbox")
            
        case .webDAV:
            buildWebDAVSettings()
        }
    }
    
    private func buildOAuthSettings(providerName: String) {
        let provider = manager.provider(for: selectedProviderType())
        let isAuth = provider?.isAuthenticated ?? false
        
        if isAuth {
            let label = NSTextField(labelWithString: String(format: NSLocalizedString("Connected to %@.", comment: ""), providerName))
            label.font = .systemFont(ofSize: 11)
            label.textColor = .systemGreen
            providerSettingsContainer.addArrangedSubview(label)
            
            signOutButton = NSButton(title: NSLocalizedString("Sign Out", comment: ""), target: self, action: #selector(signOut(_:)))
            providerSettingsContainer.addArrangedSubview(signOutButton)
        } else {
            signInButton = NSButton(title: String(format: NSLocalizedString("Sign in to %@", comment: ""), providerName),
                                     target: self, action: #selector(signIn(_:)))
            providerSettingsContainer.addArrangedSubview(signInButton)
        }
    }
    
    private func buildWebDAVSettings() {
        let defaults = UserDefaults.standard
        
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        
        let urlLabel = NSTextField(labelWithString: NSLocalizedString("Server URL:", comment: ""))
        urlLabel.alignment = .right
        
        webDAVURLField = NSTextField()
        webDAVURLField.placeholderString = "https://nas.local:8080"
        webDAVURLField.stringValue = defaults.string(forKey: "OEWebDAVServerURL") ?? ""
        webDAVURLField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webDAVURLField.widthAnchor.constraint(equalToConstant: 250),
        ])
        
        grid.addRow(with: [urlLabel, webDAVURLField])
        
        let userLabel = NSTextField(labelWithString: NSLocalizedString("Username:", comment: ""))
        userLabel.alignment = .right
        
        webDAVUserField = NSTextField()
        webDAVUserField.placeholderString = "username"
        webDAVUserField.stringValue = defaults.string(forKey: "OEWebDAVUsername") ?? ""
        webDAVUserField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webDAVUserField.widthAnchor.constraint(equalToConstant: 250),
        ])
        
        grid.addRow(with: [userLabel, webDAVUserField])
        
        let passLabel = NSTextField(labelWithString: NSLocalizedString("Password:", comment: ""))
        passLabel.alignment = .right
        
        webDAVPassField = NSSecureTextField()
        webDAVPassField.placeholderString = "password"
        webDAVPassField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webDAVPassField.widthAnchor.constraint(equalToConstant: 250),
        ])
        
        grid.addRow(with: [passLabel, webDAVPassField])
        
        providerSettingsContainer.addArrangedSubview(grid)
        
        webDAVSaveButton = NSButton(title: NSLocalizedString("Save & Connect", comment: ""), target: self, action: #selector(saveWebDAVSettings(_:)))
        providerSettingsContainer.addArrangedSubview(webDAVSaveButton)
        
        let hint = NSTextField(labelWithString: NSLocalizedString("Tip: Use rclone serve webdav with Docker for easy NAS setup.", comment: ""))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 380
        providerSettingsContainer.addArrangedSubview(hint)
    }
    
    // MARK: - Status
    
    private func updateStatus() {
        let type = manager.libraryProviderType
        
        if type == .local {
            statusIndicator.stringValue = "●"
            statusIndicator.textColor = .systemGray
            statusLabel.stringValue = NSLocalizedString("Local storage — no cloud sync active", comment: "")
        } else {
            let provider = manager.provider(for: type)
            if provider?.isAuthenticated == true {
                statusIndicator.stringValue = "●"
                statusIndicator.textColor = .systemGreen
                
                let dateStr: String
                if let lastSync = UserDefaults.standard.object(forKey: "OELastCloudSyncDate") as? Date {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .short
                    dateStr = formatter.string(from: lastSync)
                } else {
                    dateStr = NSLocalizedString("Never", comment: "")
                }
                statusLabel.stringValue = String(format: NSLocalizedString("Connected — Last sync: %@", comment: ""), dateStr)
            } else {
                statusIndicator.stringValue = "●"
                statusIndicator.textColor = .systemOrange
                statusLabel.stringValue = NSLocalizedString("Not authenticated", comment: "")
            }
        }
    }
    
    // MARK: - Actions
    
    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let type = selectedProviderType()
        manager.setProvider(type)
        updateProviderSettings()
        updateStatus()
    }
    
    @objc private func syncScopeChanged(_ sender: NSButton) {
        if sender.tag == 0 {
            // Saves only
            manager.syncScope = .saves
            savesOnlyRadio.state = .on
            fullLibraryRadio.state = .off
        } else {
            // Full library
            manager.syncScope = .all
            fullLibraryRadio.state = .on
            savesOnlyRadio.state = .off
        }
    }
    
    @objc private func signIn(_ sender: NSButton) {
        let type = selectedProviderType()
        guard let provider = manager.provider(for: type) else { return }
        
        sender.isEnabled = false
        sender.title = NSLocalizedString("Signing in…", comment: "")
        
        Task {
            do {
                try await provider.authenticate()
                await MainActor.run {
                    sender.isEnabled = true
                    updateProviderSettings()
                    updateStatus()
                }
            } catch {
                await MainActor.run {
                    sender.isEnabled = true
                    sender.title = NSLocalizedString("Sign In Failed — Retry", comment: "")
                    
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Sign In Failed", comment: "")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModal()
                }
            }
        }
    }
    
    @objc private func signOut(_ sender: NSButton) {
        Task {
            await manager.signOutAll()
            await MainActor.run {
                providerPopup.selectItem(at: 0)
                updateProviderSettings()
                updateStatus()
            }
        }
    }
    
    @objc private func saveWebDAVSettings(_ sender: NSButton) {
        let url = webDAVURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = webDAVUserField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = webDAVPassField.stringValue
        
        guard !url.isEmpty else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Server URL is required.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }
        
        UserDefaults.standard.set(url, forKey: "OEWebDAVServerURL")
        UserDefaults.standard.set(user, forKey: "OEWebDAVUsername")
        
        // Store password in Keychain via the WebDAV provider
        if let webDAVProvider = manager.provider(for: .webDAV) as? OEWebDAVStorageProvider,
           let serverURL = URL(string: url) {
            webDAVProvider.configure(serverURL: serverURL, username: user, password: pass)
        }
        
        sender.isEnabled = false
        sender.title = NSLocalizedString("Connecting…", comment: "")
        
        Task {
            do {
                try await manager.provider(for: .webDAV)?.authenticate()
                await MainActor.run {
                    sender.isEnabled = true
                    sender.title = NSLocalizedString("Save & Connect", comment: "")
                    updateStatus()
                }
            } catch {
                await MainActor.run {
                    sender.isEnabled = true
                    sender.title = NSLocalizedString("Save & Connect", comment: "")
                    
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Connection Failed", comment: "")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModal()
                }
            }
        }
    }
    
    @objc private func evictionDaysChanged(_ sender: NSStepper) {
        let days = sender.integerValue
        evictionDaysLabel.stringValue = "\(days) days"
        UserDefaults.standard.set(days, forKey: Self.evictionDaysKey)
    }
    
    @objc private func recentPlayDaysChanged(_ sender: NSStepper) {
        let days = sender.integerValue
        recentPlayDaysLabel.stringValue = "\(days) days"
        UserDefaults.standard.set(days, forKey: Self.recentPlayDaysKey)
    }
    
    @objc private func syncNow(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = NSLocalizedString("Syncing…", comment: "")
        
        Task {
            do {
                try await manager.authenticate()
                UserDefaults.standard.set(Date(), forKey: "OELastCloudSyncDate")
                await MainActor.run {
                    sender.isEnabled = true
                    sender.title = NSLocalizedString("Sync Now", comment: "")
                    updateStatus()
                }
            } catch {
                await MainActor.run {
                    sender.isEnabled = true
                    sender.title = NSLocalizedString("Sync Now", comment: "")
                }
            }
        }
    }
    
    @objc private func statusDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatus()
            self?.updateProviderSettings()
        }
    }
    
    // MARK: - Helpers
    
    private func selectedProviderType() -> OEStorageProviderType {
        switch providerPopup.indexOfSelectedItem {
        case 0: return .local
        case 1: return .iCloud
        case 2: return .googleDrive
        case 3: return .dropbox
        case 4: return .webDAV
        default: return .local
        }
    }
}

// MARK: - PreferencePane

extension PrefCloudSyncController: PreferencePane {
    
    var icon: NSImage? {
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: "cloud", accessibilityDescription: "Cloud Storage")
        }
        return NSImage(named: NSImage.networkName)
    }
    
    var panelTitle: String { "Cloud Storage" }
    
    var viewSize: NSSize { NSSize(width: 468, height: 560) }
}
