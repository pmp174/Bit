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

final class PrefGeneralController: NSViewController {
    
    // MARK: - Appearance UI
    
    private var appearancePopup: NSPopUpButton!
    private var tintButtons = [NSButton]()
    private var noneButton: NSButton!
    
    // MARK: - Cloud Sync UI
    
    private let headerLabel       = NSTextField(labelWithString: "")
    private let descLabel         = NSTextField(wrappingLabelWithString: "")
    private let signInButton      = NSButton()
    private let signOutButton     = NSButton()
    private let statusDot         = NSTextField(labelWithString: "●")
    private let statusLabel       = NSTextField(labelWithString: "")
    private let lastSyncedLabel   = NSTextField(labelWithString: "")
    private let syncNowButton     = NSButton()
    private let syncInfoLabel     = NSTextField(wrappingLabelWithString: "")
    private let loadingIndicator  = NSProgressIndicator()
    
    private let scrollView        = NSScrollView()
    private let tableView         = NSTableView()
    
    private var cloudFiles: [OESaveSyncManager.DriveFile] = []
    
    private lazy var dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()
    
    private lazy var tableDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()
    
    private var syncStatusToken: NSObjectProtocol?
    
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
            container.widthAnchor.constraint(equalToConstant: 396),
        ])
        
        // ── APPEARANCE SECTION ──────────────────────────────────────
        let appearanceHeader = makeSectionHeader("Appearance")
        container.addArrangedSubview(appearanceHeader)
        container.setCustomSpacing(12, after: appearanceHeader)
        
        let appearanceGrid = buildAppearanceSection()
        container.addArrangedSubview(appearanceGrid)
        container.setCustomSpacing(24, after: appearanceGrid)
        
        // ── DIVIDER ─────────────────────────────────────────────────
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(divider)
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalTo: container.widthAnchor),
        ])
        container.setCustomSpacing(20, after: divider)
        
        // ── CLOUD SYNC SECTION ──────────────────────────────────────
        let cloudHeader = makeSectionHeader("Cloud Sync")
        container.addArrangedSubview(cloudHeader)
        container.setCustomSpacing(12, after: cloudHeader)
        
        let cloudContent = buildCloudSyncSection()
        cloudContent.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(cloudContent)
        NSLayoutConstraint.activate([
            cloudContent.widthAnchor.constraint(equalTo: container.widthAnchor),
        ])
        
        // Table view structure setup (no sync manager access)
        setupTableView()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        guard syncStatusToken == nil else { return }
        
        syncStatusToken = NotificationCenter.default.addObserver(
            forName: .OESaveSyncStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateSyncStatus()
        }
        
        // Defer sync manager access to the next run loop iteration
        // to avoid blocking the preferences window from appearing.
        DispatchQueue.main.async { [weak self] in
            self?.updateSyncStatus()
        }
    }
    
    deinit {
        if let token = syncStatusToken {
            NotificationCenter.default.removeObserver(token)
        }
    }
    
    // MARK: - Section Header
    
    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }
    
    // MARK: - Appearance Section
    
    private func buildAppearanceSection() -> NSView {
        let gridView = NSGridView(numberOfColumns: 2, rows: 0)
        gridView.column(at: 0).xPlacement = .trailing
        gridView.rowAlignment = .firstBaseline
        gridView.columnSpacing = 8
        gridView.rowSpacing = 12
        
        // Appearance Mode
        let appearanceLabel = NSTextField(labelWithString: NSLocalizedString("Appearance:", comment: ""))
        appearanceLabel.alignment = .right
        
        appearancePopup = NSPopUpButton()
        appearancePopup.addItems(withTitles: [
            NSLocalizedString("Automatic", comment: ""),
            NSLocalizedString("Light", comment: ""),
            NSLocalizedString("Dark", comment: ""),
        ])
        appearancePopup.target = self
        appearancePopup.action = #selector(changeAppearance(_:))
        
        switch OEAppearance.application {
        case .system: appearancePopup.selectItem(at: 0)
        case .light:  appearancePopup.selectItem(at: 1)
        case .dark:   appearancePopup.selectItem(at: 2)
        }
        
        gridView.addRow(with: [appearanceLabel, appearancePopup])
        
        // Tint Color
        let tintLabel = NSTextField(labelWithString: NSLocalizedString("Accent Tint:", comment: ""))
        tintLabel.alignment = .right
        
        let tintContainer = NSStackView()
        tintContainer.orientation = .horizontal
        tintContainer.spacing = 6
        
        noneButton = makeCircleButton(color: nil, tag: 0)
        noneButton.toolTip = NSLocalizedString("None", comment: "")
        tintContainer.addArrangedSubview(noneButton)
        tintButtons.append(noneButton)
        
        let tintCases: [OEAppearance.TintColor] = [.blue, .purple, .red, .orange, .yellow, .green]
        for (index, tint) in tintCases.enumerated() {
            let button = makeCircleButton(color: tint.color, tag: index + 1)
            button.toolTip = tint.displayName
            tintContainer.addArrangedSubview(button)
            tintButtons.append(button)
        }
        
        let tintRow = gridView.addRow(with: [tintLabel, tintContainer])
        tintRow.rowAlignment = .none
        tintRow.cell(at: 0).yPlacement = .center
        tintRow.cell(at: 1).yPlacement = .center

        updateTintSelection()

        return gridView
    }
    
    // MARK: - Cloud Sync Section
    
    private func buildCloudSyncSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        
        // Description
        descLabel.stringValue = "Sign in with Google to automatically back up your battery saves and save states."
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.preferredMaxLayoutWidth = 396
        stack.addArrangedSubview(descLabel)
        
        // Status row
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        
        statusDot.font = .systemFont(ofSize: 14)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(loadingIndicator)
        stack.addArrangedSubview(statusRow)
        
        // Buttons row
        let buttonsRow = NSStackView()
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 12
        
        signInButton.title = "Sign In with Google"
        signInButton.bezelStyle = .rounded
        signInButton.controlSize = .regular
        signInButton.font = .systemFont(ofSize: 13, weight: .semibold)
        signInButton.target = self
        signInButton.action = #selector(signIn)
        signInButton.contentTintColor = NSColor(red: 0.259, green: 0.522, blue: 0.957, alpha: 1)
        
        signOutButton.title = "Sign Out"
        signOutButton.bezelStyle = .rounded
        signOutButton.controlSize = .regular
        signOutButton.font = .systemFont(ofSize: 12)
        signOutButton.target = self
        signOutButton.action = #selector(signOut)
        
        buttonsRow.addArrangedSubview(signInButton)
        buttonsRow.addArrangedSubview(signOutButton)
        stack.addArrangedSubview(buttonsRow)
        
        // Table
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 160),
        ])
        
        // Sync row
        let syncRow = NSStackView()
        syncRow.orientation = .horizontal
        syncRow.spacing = 8
        
        lastSyncedLabel.font = .systemFont(ofSize: 11)
        lastSyncedLabel.textColor = .secondaryLabelColor
        
        syncNowButton.title = "Sync Now"
        syncNowButton.bezelStyle = .rounded
        syncNowButton.controlSize = .small
        syncNowButton.font = .systemFont(ofSize: 11)
        syncNowButton.target = self
        syncNowButton.action = #selector(syncNow)
        
        syncRow.addArrangedSubview(lastSyncedLabel)
        syncRow.addArrangedSubview(syncNowButton)
        stack.addArrangedSubview(syncRow)
        
        // Info
        syncInfoLabel.stringValue = "Saves are stored in a hidden App Data folder in your Google Drive."
        syncInfoLabel.font = .systemFont(ofSize: 11)
        syncInfoLabel.textColor = .tertiaryLabelColor
        syncInfoLabel.preferredMaxLayoutWidth = 396
        stack.addArrangedSubview(syncInfoLabel)
        
        return stack
    }
    
    // MARK: - TableView Setup
    
    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 20
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        
        let sysCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("System"))
        sysCol.headerCell.stringValue = "System"
        sysCol.width = 60
        tableView.addTableColumn(sysCol)
        
        let fileCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Filename"))
        fileCol.headerCell.stringValue = "Filename"
        fileCol.width = 200
        tableView.addTableColumn(fileCol)
        
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Modified"))
        dateCol.headerCell.stringValue = "Modified"
        dateCol.width = 120
        tableView.addTableColumn(dateCol)
        
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }
    
    // MARK: - Appearance Helpers
    
    private func makeCircleButton(color: NSColor?, tag: Int) -> NSButton {
        let size: CGFloat = 24
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.tag = tag
        button.bezelStyle = .circular
        button.isBordered = false
        button.wantsLayer = true
        button.target = self
        button.action = #selector(changeTintColor(_:))
        button.setButtonType(.onOff)
        
        if let color = color {
            button.image = makeCircleImage(color: color, size: size, selected: false)
            button.alternateImage = makeCircleImage(color: color, size: size, selected: true)
        } else {
            button.image = makeNoneImage(size: size, selected: false)
            button.alternateImage = makeNoneImage(size: size, selected: true)
        }
        
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
        
        return button
    }
    
    private func makeCircleImage(color: NSColor, size: CGFloat, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset: CGFloat = selected ? 2 : 3
            let circlePath = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            color.setFill()
            circlePath.fill()
            
            if selected {
                NSColor.labelColor.setStroke()
                let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                borderPath.lineWidth = 2
                borderPath.stroke()
            }
            return true
        }
    }
    
    private func makeNoneImage(size: CGFloat, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset: CGFloat = selected ? 2 : 3
            let circleRect = rect.insetBy(dx: inset, dy: inset)
            let circlePath = NSBezierPath(ovalIn: circleRect)
            
            NSColor.tertiaryLabelColor.setFill()
            circlePath.fill()
            
            if selected {
                NSColor.labelColor.setStroke()
                let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                borderPath.lineWidth = 2
                borderPath.stroke()
            }
            
            NSColor.secondaryLabelColor.setStroke()
            let line = NSBezierPath()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = circleRect.width / 2 - 2
            line.move(to: NSPoint(x: center.x - radius * 0.7, y: center.y - radius * 0.7))
            line.line(to: NSPoint(x: center.x + radius * 0.7, y: center.y + radius * 0.7))
            line.lineWidth = 1.5
            line.stroke()
            
            return true
        }
    }
    
    private func updateTintSelection() {
        let current = OEAppearance.tintColor
        let allTints: [OEAppearance.TintColor] = [.none, .blue, .purple, .red, .orange, .yellow, .green]
        
        for (index, tint) in allTints.enumerated() {
            guard index < tintButtons.count else { break }
            tintButtons[index].state = (tint == current) ? .on : .off
        }
    }
    
    // MARK: - Appearance Actions
    
    @objc private func changeAppearance(_ sender: NSPopUpButton) {
        let value: Int
        switch sender.indexOfSelectedItem {
        case 0: value = OEAppearance.Application.system.rawValue
        case 1: value = OEAppearance.Application.light.rawValue
        case 2: value = OEAppearance.Application.dark.rawValue
        default: value = OEAppearance.Application.system.rawValue
        }
        UserDefaults.standard.set(value, forKey: OEAppearance.Application.key)
    }
    
    @objc private func changeTintColor(_ sender: NSButton) {
        let allTints: [OEAppearance.TintColor] = [.none, .blue, .purple, .red, .orange, .yellow, .green]
        let index = sender.tag
        guard index < allTints.count else { return }
        
        let selectedTint = allTints[index]
        UserDefaults.standard.set(selectedTint.rawValue, forKey: OEAppearance.TintColor.key)
        
        updateTintSelection()
        
        NotificationCenter.default.post(name: .OETintColorDidChange, object: nil)
    }
    
    // MARK: - Cloud Sync Status
    
    private func updateSyncStatus() {
        let isSignedIn = OESaveSyncManager.shared.isSignedIn
        
        if isSignedIn {
            statusDot.textColor    = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
            statusLabel.stringValue = "Connected"
            statusLabel.textColor   = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
            fetchCloudFiles()
        } else {
            statusDot.textColor    = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
            statusLabel.stringValue = "Not Connected"
            statusLabel.textColor   = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
            cloudFiles = []
            tableView.reloadData()
        }
        
        signInButton.isHidden  = isSignedIn
        signOutButton.isHidden = !isSignedIn
        
        scrollView.isHidden    = !isSignedIn
        syncNowButton.isHidden = !isSignedIn
        lastSyncedLabel.isHidden = !isSignedIn
        
        if isSignedIn {
            if let date = OESaveSyncManager.shared.lastSyncDate {
                lastSyncedLabel.stringValue = "Last synced: \(dateFormatter.string(from: date))"
            } else {
                lastSyncedLabel.stringValue = "Not synced yet"
            }
        }
    }
    
    private func fetchCloudFiles() {
        guard OESaveSyncManager.shared.isSignedIn else { return }
        
        loadingIndicator.startAnimation(nil)
        
        Task {
            do {
                let files = try await OESaveSyncManager.shared.fetchCloudFileList()
                await MainActor.run {
                    self.cloudFiles = files.sorted { ($0.modifiedTime ?? .distantPast) > ($1.modifiedTime ?? .distantPast) }
                    self.tableView.reloadData()
                    self.loadingIndicator.stopAnimation(nil)
                }
            } catch {
                await MainActor.run {
                    self.loadingIndicator.stopAnimation(nil)
                }
            }
        }
    }
    
    // MARK: - Cloud Sync Actions
    
    @objc private func signIn() {
        OESaveSyncManager.shared.signIn()
    }
    
    @objc private func signOut() {
        let alert = NSAlert()
        alert.messageText     = "Sign Out of Google Drive?"
        alert.informativeText = "Your local saves will not be affected. You can sign back in at any time."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        OESaveSyncManager.shared.signOut()
        updateSyncStatus()
    }
    
    @objc private func syncNow() {
        OESaveSyncManager.shared.performFullSyncCheck()
        fetchCloudFiles()
    }
}

// MARK: - TableView Data Source & Delegate

extension PrefGeneralController: NSTableViewDataSource, NSTableViewDelegate {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return cloudFiles.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("CloudFileCell")
        var view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
        
        if view == nil {
            view = NSTextField(labelWithString: "")
            view?.identifier = identifier
            view?.font = .systemFont(ofSize: 11)
        }
        
        let file = cloudFiles[row]
        let name = file.name ?? "Unknown"
        
        switch tableColumn?.identifier.rawValue {
        case "System":
            let parts = name.components(separatedBy: CharacterSet(charactersIn: "/\\"))
            if let firstPart = parts.first {
                let sys = String(firstPart).replacingOccurrences(of: "openemu.system.", with: "").uppercased()
                view?.stringValue = sys
            } else {
                view?.stringValue = "???"
            }
            
        case "Filename":
            let parts = name.components(separatedBy: CharacterSet(charactersIn: "/\\"))
            if let lastPart = parts.last {
                view?.stringValue = String(lastPart)
            } else {
                view?.stringValue = name
            }
            
        case "Modified":
            if let date = file.modifiedTime {
                view?.stringValue = tableDateFormatter.string(from: date)
            } else {
                view?.stringValue = "-"
            }
            
        default:
            break
        }
        
        return view
    }
}

// MARK: - PreferencePane

extension PrefGeneralController: PreferencePane {
    
    var icon: NSImage? { NSImage(named: NSImage.preferencesGeneralName) }
    
    var panelTitle: String { "General" }
    
    var viewSize: NSSize { NSSize(width: 468, height: 560) }
}
