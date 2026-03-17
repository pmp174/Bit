// Copyright (c) 2020, OpenEmu Team
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

final class PrefLibraryController: NSViewController {

    @IBOutlet var availableLibrariesViewController: AvailableLibrariesViewController!
    @IBOutlet var librariesView: NSView!
    @IBOutlet var pathField: NSPathControl!
    @IBOutlet var resetLocationButton: NSButton!

    // MARK: - Cloud Storage UI Elements

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

    private lazy var cloudManager = OECloudStorageManager.shared

    private static let evictionDaysKey = "OECloudEvictionDays"
    private static let recentPlayDaysKey = "OECloudRecentPlayDays"

    override func viewDidLoad() {
        super.viewDidLoad()

        pathField.url = OELibraryDatabase.default?.databaseFolderURL
        showResetLocationButtonIfNeeded()

        availableLibrariesViewController.isEnableObservers = true
        addChild(availableLibrariesViewController)

        let size = librariesView.frame.size
        let scrollView = availableLibrariesViewController.view as! NSScrollView
        let gridView = librariesView.superview as! NSGridView
        gridView.cell(for: librariesView)?.contentView = scrollView
        librariesView.removeFromSuperview()
        librariesView = scrollView

        scrollView.borderType = .bezelBorder
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: size.width),
            scrollView.heightAnchor.constraint(equalToConstant: size.height)
        ])

        // Append the cloud storage section below the XIB grid
        buildCloudStorageSection(below: gridView)

        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudStatusDidChange(_:)),
            name: OECloudStorageManager.statusDidChangeNotification, object: nil)
    }

    deinit {
        availableLibrariesViewController.isEnableObservers = false
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Actions

    @IBAction func resetLibraryFolder(_ sender: Any?) {

        OELibraryDatabase.default?.moveGameLibraryToDefaultLocation()

        pathField.url = OELibraryDatabase.default?.databaseFolderURL
        showResetLocationButtonIfNeeded()
    }

    @IBAction func changeLibraryFolder(_ sender: Any?) {

        let alert = OEAlert()
        alert.messageUsesHTML = true
        alert.messageText = NSLocalizedString(
            "Moving the Game Library is not recommended",
            comment: "Message headline (attempted to change location of library)")
        alert.informativeText = NSLocalizedString("ALERT_MOVE_LIBRARY_HTML",
            comment: "Message text (attempted to change location of library, HTML)")
        alert.defaultButtonTitle = NSLocalizedString("Cancel", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("I understand the risks",
            comment: "OK button (attempted to change location of library)")
        alert.beginSheetModal(for: view.window!) { result in
            if result == .alertSecondButtonReturn {
                self.moveGameLibrary()
            }
        }
    }

    private func moveGameLibrary() {

        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.beginSheetModal(for: view.window!) { result in
            if result == .OK, let url = openPanel.url {
                openPanel.orderOut(nil)
                OELibraryDatabase.default?.moveGameLibrary(to: url)
                self.pathField.url = OELibraryDatabase.default?.databaseFolderURL
                self.showResetLocationButtonIfNeeded()
            }
        }
    }

    private func showResetLocationButtonIfNeeded() {

        let defaultDatabasePath = (UserDefaults.standard.string(forKey: OELibraryDatabase.defaultDatabasePathKey)! as NSString).expandingTildeInPath
        let defaultLocation = URL(fileURLWithPath: defaultDatabasePath, isDirectory: true)

        let currentLocation = OELibraryDatabase.default?.databaseFolderURL

        resetLocationButton.isHidden = currentLocation == defaultLocation
    }

    @IBAction func resetWarningDialogs(_ sender: Any?) {

        let keysToRemove: [String] = [
            OEAlert.OEDeleteGameAlertSuppressionKey,
            OEAlert.OEDeleteSaveStateAlertSuppressionKey,
            OEAlert.OEDeleteScreenshotAlertSuppressionKey,
            OEAlert.OERemoveCollectionAlertSuppressionKey,
            OEAlert.OERemoveGameFromCollectionAlertSuppressionKey,
            OEAlert.OERemoveGameFromLibraryAlertSuppressionKey,
            OEAlert.OERenameSpecialSaveStateAlertSuppressionKey,
            OEAlert.OELoadAutoSaveAlertSuppressionKey,
            OEAlert.OEDownloadRomWarningSuppressionKey,
            OEAlert.OESaveGameAlertSuppressionKey,
            OEAlert.OEResetSystemAlertSuppressionKey,
            OEAlert.OEStopEmulationAlertSuppressionKey,
            OEAlert.OEChangeCoreAlertSuppressionKey,
            OEAlert.OEAutoSwitchCoreAlertSuppressionKey,
            OEAlert.OEGameCoreGlitchesSuppressionKey,
            OEAlert.OEDeleteShaderPresetAlertSuppressionKey,
        ]

        keysToRemove.forEach { key in
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Cloud Storage Section

    private func buildCloudStorageSection(below xibGrid: NSGridView) {
        let cloudStack = NSStackView()
        cloudStack.orientation = .vertical
        cloudStack.alignment = .leading
        cloudStack.spacing = 0
        cloudStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cloudStack)

        NSLayoutConstraint.activate([
            cloudStack.topAnchor.constraint(equalTo: xibGrid.bottomAnchor, constant: 6),
            cloudStack.leadingAnchor.constraint(equalTo: xibGrid.leadingAnchor),
            cloudStack.trailingAnchor.constraint(equalTo: xibGrid.trailingAnchor),
        ])

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cloudStack.addArrangedSubview(separator)
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalTo: cloudStack.widthAnchor),
        ])
        cloudStack.setCustomSpacing(12, after: separator)

        // ── CLOUD STORAGE HEADER ─────────────────────────────────
        let cloudHeader = NSTextField(labelWithString: NSLocalizedString("Cloud Storage", comment: ""))
        cloudHeader.font = .boldSystemFont(ofSize: 13)
        cloudStack.addArrangedSubview(cloudHeader)
        cloudStack.setCustomSpacing(12, after: cloudHeader)

        // ── PROVIDER ROW ─────────────────────────────────────────
        let providerGrid = NSGridView(numberOfColumns: 2, rows: 0)
        providerGrid.column(at: 0).xPlacement = .trailing
        providerGrid.rowAlignment = .firstBaseline
        providerGrid.columnSpacing = 8
        providerGrid.rowSpacing = 12

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
        providerPopup.action = #selector(cloudProviderChanged(_:))

        switch cloudManager.libraryProviderType {
        case .local:       providerPopup.selectItem(at: 0)
        case .iCloud:      providerPopup.selectItem(at: 1)
        case .googleDrive: providerPopup.selectItem(at: 2)
        case .dropbox:     providerPopup.selectItem(at: 3)
        case .webDAV:      providerPopup.selectItem(at: 4)
        }

        providerGrid.addRow(with: [providerLabel, providerPopup])
        cloudStack.addArrangedSubview(providerGrid)
        cloudStack.setCustomSpacing(16, after: providerGrid)

        // ── WHAT TO SYNC ─────────────────────────────────────────
        let scopeLabel = NSTextField(labelWithString: NSLocalizedString("What to Sync:", comment: ""))
        scopeLabel.font = .boldSystemFont(ofSize: 11)
        cloudStack.addArrangedSubview(scopeLabel)
        cloudStack.setCustomSpacing(6, after: scopeLabel)

        savesOnlyRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Saves only (battery saves + save states)", comment: ""),
                                   target: self, action: #selector(cloudSyncScopeChanged(_:)))
        savesOnlyRadio.tag = 0

        fullLibraryRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Entire library (ROMs + saves + screenshots)", comment: ""),
                                     target: self, action: #selector(cloudSyncScopeChanged(_:)))
        fullLibraryRadio.tag = 1

        cloudStack.addArrangedSubview(savesOnlyRadio)
        cloudStack.setCustomSpacing(4, after: savesOnlyRadio)
        cloudStack.addArrangedSubview(fullLibraryRadio)
        cloudStack.setCustomSpacing(16, after: fullLibraryRadio)

        // ── PROVIDER SETTINGS BOX ────────────────────────────────
        providerSettingsContainer = NSStackView()
        providerSettingsContainer.orientation = .vertical
        providerSettingsContainer.alignment = .leading
        providerSettingsContainer.spacing = 8
        providerSettingsContainer.translatesAutoresizingMaskIntoConstraints = false

        providerSettingsBox = NSBox()
        providerSettingsBox.title = NSLocalizedString("Provider Settings", comment: "")
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

        cloudStack.addArrangedSubview(providerSettingsBox)
        NSLayoutConstraint.activate([
            providerSettingsBox.widthAnchor.constraint(equalTo: cloudStack.widthAnchor),
        ])
        cloudStack.setCustomSpacing(16, after: providerSettingsBox)

        // ── STATUS ROW ───────────────────────────────────────────
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 6

        statusIndicator = NSTextField(labelWithString: "●")
        statusIndicator.font = .systemFont(ofSize: 12)
        statusIndicator.textColor = .systemGray
        statusRow.addArrangedSubview(statusIndicator)

        statusLabel = NSTextField(labelWithString: NSLocalizedString("Not connected", comment: ""))
        statusLabel.font = .systemFont(ofSize: 12)
        statusRow.addArrangedSubview(statusLabel)

        cloudStack.addArrangedSubview(statusRow)
        cloudStack.setCustomSpacing(16, after: statusRow)

        // ── EVICTION ─────────────────────────────────────────────
        let evictionLabel = NSTextField(labelWithString: NSLocalizedString("Eviction:", comment: ""))
        evictionLabel.font = .boldSystemFont(ofSize: 11)
        cloudStack.addArrangedSubview(evictionLabel)
        cloudStack.setCustomSpacing(6, after: evictionLabel)

        let evictionGrid = buildCloudEvictionSection()
        cloudStack.addArrangedSubview(evictionGrid)
        cloudStack.setCustomSpacing(16, after: evictionGrid)

        // ── SYNC NOW ─────────────────────────────────────────────
        syncNowButton = NSButton(title: NSLocalizedString("Sync Now", comment: ""), target: self, action: #selector(cloudSyncNow(_:)))
        cloudStack.addArrangedSubview(syncNowButton)

        // Initialize state
        updateCloudProviderSettings()
        updateCloudStatus()
        updateCloudSyncScopeSelection()
    }

    private func buildCloudEvictionSection() -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8

        let defaults = UserDefaults.standard

        let currentEvictionDays = defaults.integer(forKey: Self.evictionDaysKey)
        let evictionDays = currentEvictionDays > 0 ? currentEvictionDays : 30

        let autoRemoveLabel = NSTextField(labelWithString: NSLocalizedString("Auto-remove unused games after:", comment: ""))
        autoRemoveLabel.alignment = .right

        let evictionRow = NSStackView()
        evictionRow.orientation = .horizontal
        evictionRow.spacing = 4

        evictionDaysLabel = NSTextField(labelWithString: "\(evictionDays) days")
        evictionDaysLabel.font = .systemFont(ofSize: 12)

        evictionDaysStepper = NSStepper()
        evictionDaysStepper.minValue = 7
        evictionDaysStepper.maxValue = 365
        evictionDaysStepper.increment = 7
        evictionDaysStepper.integerValue = evictionDays
        evictionDaysStepper.target = self
        evictionDaysStepper.action = #selector(cloudEvictionDaysChanged(_:))

        evictionRow.addArrangedSubview(evictionDaysLabel)
        evictionRow.addArrangedSubview(evictionDaysStepper)
        grid.addRow(with: [autoRemoveLabel, evictionRow])

        let currentRecentDays = defaults.integer(forKey: Self.recentPlayDaysKey)
        let recentDays = currentRecentDays > 0 ? currentRecentDays : 7

        let recentLabel = NSTextField(labelWithString: NSLocalizedString("Keep recently played games:", comment: ""))
        recentLabel.alignment = .right

        let recentRow = NSStackView()
        recentRow.orientation = .horizontal
        recentRow.spacing = 4

        recentPlayDaysLabel = NSTextField(labelWithString: "\(recentDays) days")
        recentPlayDaysLabel.font = .systemFont(ofSize: 12)

        recentPlayDaysStepper = NSStepper()
        recentPlayDaysStepper.minValue = 1
        recentPlayDaysStepper.maxValue = 90
        recentPlayDaysStepper.increment = 1
        recentPlayDaysStepper.integerValue = recentDays
        recentPlayDaysStepper.target = self
        recentPlayDaysStepper.action = #selector(cloudRecentPlayDaysChanged(_:))

        recentRow.addArrangedSubview(recentPlayDaysLabel)
        recentRow.addArrangedSubview(recentPlayDaysStepper)
        grid.addRow(with: [recentLabel, recentRow])

        return grid
    }

    // MARK: - Cloud Provider Settings

    private func updateCloudProviderSettings() {
        providerSettingsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let type = selectedCloudProviderType()

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

            signInButton = NSButton(title: NSLocalizedString("Enable iCloud Sync", comment: ""), target: self, action: #selector(cloudSignIn(_:)))
            providerSettingsContainer.addArrangedSubview(signInButton)

        case .googleDrive:
            buildCloudOAuthSettings(providerName: "Google Drive")

        case .dropbox:
            buildCloudOAuthSettings(providerName: "Dropbox")

        case .webDAV:
            buildCloudWebDAVSettings()
        }
    }

    private func buildCloudOAuthSettings(providerName: String) {
        let provider = cloudManager.provider(for: selectedCloudProviderType())
        let isAuth = provider?.isAuthenticated ?? false

        if isAuth {
            let label = NSTextField(labelWithString: String(format: NSLocalizedString("Connected to %@.", comment: ""), providerName))
            label.font = .systemFont(ofSize: 11)
            label.textColor = .systemGreen
            providerSettingsContainer.addArrangedSubview(label)

            signOutButton = NSButton(title: NSLocalizedString("Sign Out", comment: ""), target: self, action: #selector(cloudSignOut(_:)))
            providerSettingsContainer.addArrangedSubview(signOutButton)
        } else {
            signInButton = NSButton(title: String(format: NSLocalizedString("Sign in to %@", comment: ""), providerName),
                                     target: self, action: #selector(cloudSignIn(_:)))
            providerSettingsContainer.addArrangedSubview(signInButton)
        }
    }

    private func buildCloudWebDAVSettings() {
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
        webDAVURLField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        grid.addRow(with: [urlLabel, webDAVURLField])

        let userLabel = NSTextField(labelWithString: NSLocalizedString("Username:", comment: ""))
        userLabel.alignment = .right

        webDAVUserField = NSTextField()
        webDAVUserField.placeholderString = "username"
        webDAVUserField.stringValue = defaults.string(forKey: "OEWebDAVUsername") ?? ""
        webDAVUserField.translatesAutoresizingMaskIntoConstraints = false
        webDAVUserField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        grid.addRow(with: [userLabel, webDAVUserField])

        let passLabel = NSTextField(labelWithString: NSLocalizedString("Password:", comment: ""))
        passLabel.alignment = .right

        webDAVPassField = NSSecureTextField()
        webDAVPassField.placeholderString = "password"
        webDAVPassField.translatesAutoresizingMaskIntoConstraints = false
        webDAVPassField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        grid.addRow(with: [passLabel, webDAVPassField])

        providerSettingsContainer.addArrangedSubview(grid)

        webDAVSaveButton = NSButton(title: NSLocalizedString("Save & Connect", comment: ""), target: self, action: #selector(cloudSaveWebDAVSettings(_:)))
        providerSettingsContainer.addArrangedSubview(webDAVSaveButton)

        let hint = NSTextField(labelWithString: NSLocalizedString("Tip: Use rclone serve webdav with Docker for easy NAS setup.", comment: ""))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 380
        providerSettingsContainer.addArrangedSubview(hint)
    }

    // MARK: - Cloud Status

    private func updateCloudStatus() {
        let type = cloudManager.libraryProviderType

        if type == .local {
            statusIndicator.stringValue = "●"
            statusIndicator.textColor = .systemGray
            statusLabel.stringValue = NSLocalizedString("Local storage — no cloud sync active", comment: "")
        } else {
            let provider = cloudManager.provider(for: type)
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

    private func updateCloudSyncScopeSelection() {
        let scope = cloudManager.syncScope
        if scope == .all {
            fullLibraryRadio.state = .on
            savesOnlyRadio.state = .off
        } else {
            savesOnlyRadio.state = .on
            fullLibraryRadio.state = .off
        }
    }

    // MARK: - Cloud Actions

    @objc private func cloudProviderChanged(_ sender: NSPopUpButton) {
        let type = selectedCloudProviderType()
        cloudManager.setProvider(type)
        updateCloudProviderSettings()
        updateCloudStatus()
    }

    @objc private func cloudSyncScopeChanged(_ sender: NSButton) {
        if sender.tag == 0 {
            cloudManager.syncScope = .saves
            savesOnlyRadio.state = .on
            fullLibraryRadio.state = .off
        } else {
            cloudManager.syncScope = .all
            fullLibraryRadio.state = .on
            savesOnlyRadio.state = .off
        }
    }

    @objc private func cloudSignIn(_ sender: NSButton) {
        let type = selectedCloudProviderType()
        guard let provider = cloudManager.provider(for: type) else { return }

        sender.isEnabled = false
        sender.title = NSLocalizedString("Signing in…", comment: "")

        Task {
            do {
                try await provider.authenticate()
                await MainActor.run {
                    sender.isEnabled = true
                    updateCloudProviderSettings()
                    updateCloudStatus()
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

    @objc private func cloudSignOut(_ sender: NSButton) {
        Task {
            await cloudManager.signOutAll()
            await MainActor.run {
                providerPopup.selectItem(at: 0)
                updateCloudProviderSettings()
                updateCloudStatus()
            }
        }
    }

    @objc private func cloudSaveWebDAVSettings(_ sender: NSButton) {
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

        if let webDAVProvider = cloudManager.provider(for: .webDAV) as? OEWebDAVStorageProvider,
           let serverURL = URL(string: url) {
            webDAVProvider.configure(serverURL: serverURL, username: user, password: pass)
        }

        sender.isEnabled = false
        sender.title = NSLocalizedString("Connecting…", comment: "")

        Task {
            do {
                try await cloudManager.provider(for: .webDAV)?.authenticate()
                await MainActor.run {
                    sender.isEnabled = true
                    sender.title = NSLocalizedString("Save & Connect", comment: "")
                    updateCloudStatus()
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

    @objc private func cloudEvictionDaysChanged(_ sender: NSStepper) {
        let days = sender.integerValue
        evictionDaysLabel.stringValue = "\(days) days"
        UserDefaults.standard.set(days, forKey: Self.evictionDaysKey)
    }

    @objc private func cloudRecentPlayDaysChanged(_ sender: NSStepper) {
        let days = sender.integerValue
        recentPlayDaysLabel.stringValue = "\(days) days"
        UserDefaults.standard.set(days, forKey: Self.recentPlayDaysKey)
    }

    @objc private func cloudSyncNow(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = NSLocalizedString("Syncing…", comment: "")

        Task {
            do {
                try await cloudManager.authenticate()
                UserDefaults.standard.set(Date(), forKey: "OELastCloudSyncDate")
                await MainActor.run {
                    sender.isEnabled = true
                    sender.title = NSLocalizedString("Sync Now", comment: "")
                    updateCloudStatus()
                }
            } catch {
                await MainActor.run {
                    sender.isEnabled = true
                    sender.title = NSLocalizedString("Sync Now", comment: "")
                }
            }
        }
    }

    @objc private func cloudStatusDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateCloudStatus()
            self?.updateCloudProviderSettings()
        }
    }

    // MARK: - Cloud Helpers

    private func selectedCloudProviderType() -> OEStorageProviderType {
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

extension PrefLibraryController: PreferencePane {

    var icon: NSImage? { NSImage(named: "library_tab_icon") }

    var panelTitle: String { "Library" }

    var viewSize: NSSize { NSSize(width: 468, height: 700) }
}
