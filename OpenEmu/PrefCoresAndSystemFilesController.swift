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
import OpenEmuKit

// MARK: - Data Model

/// Wrapper for a BIOS file child item so NSOutlineView can track each one uniquely by identity.
private class BIOSFileItem: NSObject {
    let coreIndex: Int
    let fileIndex: Int
    let fileInfo: [String: Any]
    
    init(coreIndex: Int, fileIndex: Int, fileInfo: [String: Any]) {
        self.coreIndex = coreIndex
        self.fileIndex = fileIndex
        self.fileInfo = fileInfo
    }
}

private struct CoreWithFiles {
    let core: CoreDownload
    let plugin: OECorePlugin?
    let biosFiles: [[String: Any]]
    var biosFileItems: [BIOSFileItem] = []
    
    var hasMissingBIOS: Bool {
        biosFiles.contains { !BIOSFile.isBIOSFileAvailable(withFileInfo: $0) }
    }
    
    var missingCount: Int {
        biosFiles.filter { !BIOSFile.isBIOSFileAvailable(withFileInfo: $0) }.count
    }
}

// MARK: - Controller

final class PrefCoresAndSystemFilesController: NSViewController {
    
    private var outlineView: NSOutlineView!
    private var infoLabel: NSTextField!
    
    private var items: [CoreWithFiles] = []
    private var coreListObservation: NSKeyValueObservation?
    private var biosImportToken: NSObjectProtocol?
    
    // MARK: - Lifecycle
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupInfoLabel()
        setupOutlineView()
        
        // Observe core list changes
        coreListObservation = CoreUpdater.shared.observe(\.coreList) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.reloadData()
            }
        }
        
        // Observe BIOS file imports
        biosImportToken = NotificationCenter.default.addObserver(forName: .didImportBIOSFile, object: nil, queue: .main) { [weak self] notification in
            self?.biosFileWasImported(notification)
        }
        
        // Observe core plugin changes
        OECorePlugin.addObserver(self, forKeyPath: #keyPath(OECorePlugin.allPlugins), context: nil)
        
        // Trigger initial data load
        CoreUpdater.shared.checkForNewCores()
        CoreUpdater.shared.checkForUpdates()
        
        reloadData()
    }
    
    deinit {
        if let token = biosImportToken {
            NotificationCenter.default.removeObserver(token)
        }
        OECorePlugin.removeObserver(self, forKeyPath: #keyPath(OECorePlugin.allPlugins))
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(OECorePlugin.allPlugins) {
            DispatchQueue.main.async { self.reloadData() }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    // MARK: - Setup
    
    private func setupInfoLabel() {
        let parStyle = NSMutableParagraphStyle()
        parStyle.alignment = .left
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: parStyle
        ]
        
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: parStyle,
            .link: URL.userGuideBIOSFiles
        ]
        
        let linkText = NSLocalizedString("User guide on BIOS files", comment: "")
        let infoText = String(format: NSLocalizedString("Some cores require BIOS files to emulate certain systems. See our %@ for details.", comment: ""), linkText)
        
        let attrString = NSMutableAttributedString(string: infoText, attributes: attributes)
        let linkRange = (infoText as NSString).range(of: linkText)
        attrString.setAttributes(linkAttributes, range: linkRange)
        
        infoLabel = NSTextField(wrappingLabelWithString: "")
        infoLabel.attributedStringValue = attrString
        infoLabel.allowsEditingTextAttributes = true
        infoLabel.isSelectable = true
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)
        
        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
    
    private func setupOutlineView() {
        outlineView = NSOutlineView()
        outlineView.style = .plain
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 0
        outlineView.rowSizeStyle = .custom
        outlineView.selectionHighlightStyle = .none
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        
        // Drag-and-drop support
        outlineView.registerForDraggedTypes([.fileURL])
        
        // Context menu
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        outlineView.menu = menu
        
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    // MARK: - Data
    
    private func reloadData() {
        let coreList = CoreUpdater.shared.coreList
        let allPlugins = OECorePlugin.allPlugins
        
        items = coreList.enumerated().map { (coreIndex, core) in
            let plugin = allPlugins.first { $0.bundleIdentifier == core.bundleIdentifier }
            let biosFiles: [[String: Any]]
            if let plugin = plugin {
                let files = plugin.requiredFiles as NSArray
                biosFiles = files.sortedArray(using: [NSSortDescriptor(key: "Description", ascending: true)]) as? [[String: Any]] ?? []
            } else {
                biosFiles = []
            }
            var coreWithFiles = CoreWithFiles(core: core, plugin: plugin, biosFiles: biosFiles)
            // Create unique child item objects for the outline view
            coreWithFiles.biosFileItems = biosFiles.enumerated().map { (fileIndex, fileInfo) in
                BIOSFileItem(coreIndex: coreIndex, fileIndex: fileIndex, fileInfo: fileInfo)
            }
            return coreWithFiles
        }
        
        outlineView.reloadData()
        
        // Auto-expand cores that have BIOS files
        for item in items where !item.biosFiles.isEmpty {
            outlineView.expandItem(item.core)
        }
    }
    
    // MARK: - BIOS Import Notification
    
    private func biosFileWasImported(_ notification: Notification) {
        guard let md5 = notification.userInfo?["MD5"] as? String else { return }
        
        // Find the BIOS file row that matches and refresh it
        for coreItem in items {
            for biosFileItem in coreItem.biosFileItems {
                guard let fileMD5 = biosFileItem.fileInfo["MD5"] as? String,
                      fileMD5.caseInsensitiveCompare(md5) == .orderedSame
                else { continue }
                
                // Refresh just this row
                let row = outlineView.row(forItem: biosFileItem)
                if row >= 0 {
                    outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
                
                // Also refresh the parent core row to update warning count
                let coreRow = outlineView.row(forItem: coreItem.core)
                if coreRow >= 0 {
                    outlineView.reloadData(forRowIndexes: IndexSet(integer: coreRow), columnIndexes: IndexSet(integer: 0))
                }
                return
            }
        }
    }
    
    // MARK: - Actions
    
    @objc private func updateOrInstall(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard row >= 0, let core = outlineView.item(atRow: row) as? CoreDownload else { return }
        CoreUpdater.shared.installCoreInBackgroundUserInitiated(core)
    }
    
    @objc private func revertCore(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard row >= 0, let core = outlineView.item(atRow: row) as? CoreDownload else { return }
        
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Revert to previous version?", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Are you sure you want to revert '%@' to the previous version?", comment: ""), core.name)
        alert.addButton(withTitle: NSLocalizedString("Revert", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        
        alert.beginSheetModal(for: self.view.window!) { response in
            if response == .alertFirstButtonReturn {
                CoreUpdater.shared.revertCore(bundleID: core.bundleIdentifier) { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            NSApp.presentError(error)
                        } else {
                            self.reloadData()
                        }
                    }
                }
            }
        }
    }
    
    @objc private func deleteBIOSFile(_ sender: Any?) {
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0 else { return }
        
        guard let biosItem = outlineView.item(atRow: clickedRow) as? BIOSFileItem else { return }
        guard let fileName = biosItem.fileInfo["Name"] as? String else { return }
        
        if BIOSFile.deleteBIOSFile(withFileName: fileName) {
            outlineView.reloadData(forRowIndexes: IndexSet(integer: clickedRow), columnIndexes: IndexSet(integer: 0))
            // Also refresh parent core row
            if let parentCore = outlineView.parent(forItem: biosItem) as? CoreDownload {
                let coreRow = outlineView.row(forItem: parentCore)
                if coreRow >= 0 {
                    outlineView.reloadData(forRowIndexes: IndexSet(integer: coreRow), columnIndexes: IndexSet(integer: 0))
                }
            }
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension PrefCoresAndSystemFilesController: NSOutlineViewDataSource {
    
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return items.count
        }
        if let core = item as? CoreDownload,
           let coreItem = items.first(where: { $0.core === core }) {
            return coreItem.biosFiles.count
        }
        return 0
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return items[index].core
        }
        // Child of a core: return the unique BIOSFileItem object
        if let core = item as? CoreDownload,
           let coreItem = items.first(where: { $0.core === core }) {
            return coreItem.biosFileItems[index]
        }
        return index
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let core = item as? CoreDownload,
           let coreItem = items.first(where: { $0.core === core }) {
            return !coreItem.biosFiles.isEmpty
        }
        return false
    }
    
    // MARK: Drag and Drop
    
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }
    
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }
        
        var importedSomething = false
        func importFile(at url: URL) {
            importedSomething = BIOSFile.checkIfBIOSFileAndImport(at: url) || importedSomething
        }
        
        for url in fileURLs {
            if !url.isDirectory {
                importFile(at: url)
            } else {
                let fm = FileManager.default
                guard let dirEnum = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                
                for case let fileURL as URL in dirEnum where !fileURL.isDirectory {
                    importFile(at: fileURL)
                }
            }
        }
        
        return importedSomething
    }
}

// MARK: - NSOutlineViewDelegate

extension PrefCoresAndSystemFilesController: NSOutlineViewDelegate {
    
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is CoreDownload {
            // Check if this is the first core — no top separator padding needed
            if let core = item as? CoreDownload, items.first?.core === core {
                return 52
            }
            return 68 // Extra top padding for separator spacing between sections
        }
        return 28
    }
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let core = item as? CoreDownload {
            return makeCoreRowView(for: core)
        }
        if let biosItem = item as? BIOSFileItem {
            return makeBIOSFileRowView(for: biosItem.fileInfo)
        }
        return nil
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return false
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        return false
    }
    
    // MARK: - Cell Views
    
    private func makeCoreRowView(for core: CoreDownload) -> NSView {
        guard let coreItem = items.first(where: { $0.core === core }) else {
            return NSView()
        }
        
        let isFirstCore = (items.first?.core === core)
        let container = NSView()
        
        // Separator line between sections (skip for first core)
        var topAnchorView: NSView = container
        var topAnchorAttribute: NSLayoutConstraint.Attribute = .top
        
        if !isFirstCore {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(separator)
            
            NSLayoutConstraint.activate([
                separator.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            ])
            topAnchorView = separator
        }
        
        // Core name — bold section header style
        let nameLabel = NSTextField(labelWithString: core.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = core.canBeInstalled ? .disabledControlTextColor : .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)
        
        // Systems + version + BIOS status on one detail line
        let systemsText = core.systemNames.joined(separator: ", ")
        var detailText = "\(systemsText)  ·  v\(core.version)"
        var detailColor = NSColor.secondaryLabelColor
        
        if !coreItem.biosFiles.isEmpty {
            let missing = coreItem.missingCount
            let total = coreItem.biosFiles.count
            if missing > 0 {
                detailText += "  ·  \(missing) of \(total) system files missing"
                detailColor = .systemOrange
            } else {
                detailText += "  ·  All system files present"
                detailColor = .systemGreen
            }
        }
        
        let detailLabel = NSTextField(labelWithString: detailText)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = detailColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detailLabel)
        
        // Action button
        let button = NSButton(title: "", target: self, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        
        if core.isDownloading {
            button.title = "..."
            button.isEnabled = false
        } else if core.canBeInstalled {
            button.title = NSLocalizedString("Install", comment: "")
            button.action = #selector(updateOrInstall(_:))
        } else if core.hasUpdate {
            button.title = NSLocalizedString("Update", comment: "")
            button.action = #selector(updateOrInstall(_:))
        } else if CoreUpdater.shared.hasBackup(bundleID: core.bundleIdentifier) {
            button.title = NSLocalizedString("Revert", comment: "")
            button.action = #selector(revertCore(_:))
        } else {
            button.title = NSLocalizedString("Check", comment: "")
            button.action = #selector(updateOrInstall(_:))
        }
        
        // Layout
        let nameTop: CGFloat = isFirstCore ? 4 : 12
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: isFirstCore ? container.topAnchor : topAnchorView.bottomAnchor, constant: nameTop),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            button.centerYAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        
        return container
    }
    
    private func makeBIOSFileRowView(for file: [String: Any]) -> NSView {
        let container = NSView()
        
        let description = file["Description"] as? String ?? ""
        let name = file["Name"] as? String ?? ""
        let md5 = file["MD5"] as? String ?? ""
        let size = file["Size"] as AnyObject
        let available = BIOSFile.isBIOSFileAvailable(withFileInfo: file)
        
        // Availability indicator — simple colored dot
        let dot = NSView()
        dot.wantsLayer = true
        let dotLayer = dot.layer ?? CALayer()
        dot.layer = dotLayer
        dotLayer.cornerRadius = 4
        dotLayer.backgroundColor = (available ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dot)
        
        // Description
        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .labelColor
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(descLabel)
        
        // File name + size (right-aligned)
        let sizeString = ByteCountFormatter.string(fromByteCount: size.int64Value ?? 0, countStyle: .file)
        let fileLabel = NSTextField(labelWithString: "\(name) (\(sizeString))")
        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .tertiaryLabelColor
        fileLabel.toolTip = "MD5: \(md5)"
        fileLabel.alignment = .right
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(fileLabel)
        
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            
            descLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            descLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            
            fileLabel.leadingAnchor.constraint(greaterThanOrEqualTo: descLabel.trailingAnchor, constant: 12),
            fileLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            fileLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        
        return container
    }
}

// MARK: - NSMenuDelegate

extension PrefCoresAndSystemFilesController: NSMenuDelegate {
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0 else { return }
        
        // Only show menu for BIOS file rows
        guard let biosItem = outlineView.item(atRow: clickedRow) as? BIOSFileItem
        else { return }
        
        let file = biosItem.fileInfo
        let available = BIOSFile.isBIOSFileAvailable(withFileInfo: file)
        
        let deleteItem = NSMenuItem()
        deleteItem.title = NSLocalizedString("Delete", comment: "")
        deleteItem.action = #selector(deleteBIOSFile(_:))
        deleteItem.isEnabled = available
        menu.addItem(deleteItem)
    }
}

// MARK: - PreferencePane

extension PrefCoresAndSystemFilesController: PreferencePane {
    
    var icon: NSImage? {
        NSImage(systemSymbolName: "cpu", accessibilityDescription: "Cores & System Files")
    }
    
    var panelTitle: String { "Cores & System Files" }
    
    var viewSize: NSSize { NSSize(width: 520, height: 500) }
    
    var prefersFlexibleSize: Bool { true }
}
