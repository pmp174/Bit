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

protocol SettingsSidebarDelegate: AnyObject {
    func sidebarDidSelectPane(at index: Int)
}

final class SettingsSidebarViewController: NSViewController {
    
    weak var delegate: SettingsSidebarDelegate?
    
    var panes: [PreferencePane] = [] {
        didSet { reloadRows() }
    }
    
    var debugPane: PreferencePane? {
        didSet { reloadRows() }
    }
    
    private(set) var selectedIndex: Int?
    
    private var tableView: NSTableView!
    
    // Each row is either a pane or a separator
    private enum Row {
        case pane(PreferencePane)
        case separator
    }
    private var rows: [Row] = []
    
    // MARK: - Sidebar Icon Mapping
    
    private func sfSymbolName(for pane: PreferencePane) -> String {
        switch pane.panelTitle {
        case "Appearance":            return "paintbrush"
        case "Library":               return "books.vertical"
        case "Gameplay":              return "gamecontroller"
        case "Controls":              return "keyboard"
        case "Cores & System Files":  return "cpu"
        case "Secrets":               return "ladybug"
        default:                      return "gearshape"
        }
    }
    
    // MARK: - Lifecycle
    
    override func loadView() {
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        view = visualEffect
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        // NSSplitViewItem(sidebarWithViewController:) wraps our view in a
        // system-provided NSVisualEffectView with followsWindowActiveState.
        // Walk up the hierarchy and force all VE views to .active so the
        // sidebar stays opaque when the window loses focus.
        var ancestor = view.superview
        while let v = ancestor {
            if let ve = v as? NSVisualEffectView {
                ve.state = .active
            }
            ancestor = v.superview
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView = NSTableView()
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .sourceList
        tableView.delegate = self
        tableView.dataSource = self
        tableView.floatsGroupRows = false
        
        // Use inset style on macOS 12+ for rounded selection highlights
        if #available(macOS 12.0, *) {
            tableView.style = .inset
        }
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = true
        
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        reloadRows()
    }
    
    // MARK: - Row Management
    
    private func reloadRows() {
        var newRows: [Row] = panes.map { .pane($0) }
        if let debug = debugPane {
            newRows.append(.separator)
            newRows.append(.pane(debug))
        }
        rows = newRows
        tableView?.reloadData()
        
        // Restore selection if valid
        if let idx = selectedIndex, idx < paneCount() {
            tableView?.selectRowIndexes(IndexSet(integer: paneRowIndex(for: idx)), byExtendingSelection: false)
        }
    }
    
    // MARK: - Selection
    
    func selectRow(at paneIndex: Int) {
        selectedIndex = paneIndex
        let rowIndex = paneRowIndex(for: paneIndex)
        tableView?.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
    }
    
    private func paneCount() -> Int {
        var count = panes.count
        if debugPane != nil { count += 1 }
        return count
    }
    
    /// Convert a pane index (0-based among panes) to a table row index (accounting for separators)
    private func paneRowIndex(for paneIndex: Int) -> Int {
        // Panes before debug are at their own indices
        // Debug pane (if present) is after a separator row
        if paneIndex < panes.count {
            return paneIndex
        }
        // Debug pane: skip the separator
        return panes.count + 1
    }
    
    /// Convert a table row index to a pane index, or nil if it's a separator
    private func paneIndex(for rowIndex: Int) -> Int? {
        guard rowIndex < rows.count else { return nil }
        switch rows[rowIndex] {
        case .pane:
            if rowIndex <= panes.count - 1 {
                return rowIndex
            }
            // Must be the debug pane
            return panes.count
        case .separator:
            return nil
        }
    }
}

// MARK: - NSTableViewDataSource

extension SettingsSidebarViewController: NSTableViewDataSource {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }
}

// MARK: - NSTableViewDelegate

extension SettingsSidebarViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        
        switch rows[row] {
        case .separator:
            let separator = NSBox()
            separator.boxType = .separator
            return separator
            
        case .pane(let pane):
            let cellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell: NSTableCellView
            
            if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = cellIdentifier
                
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                cell.addSubview(imageView)
                cell.imageView = imageView
                
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.font = .systemFont(ofSize: 13)
                textField.lineBreakMode = .byTruncatingTail
                cell.addSubview(textField)
                cell.textField = textField
                
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 20),
                    imageView.heightAnchor.constraint(equalToConstant: 20),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            
            let symbolName = sfSymbolName(for: pane)
            cell.imageView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: pane.panelTitle)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            cell.textField?.stringValue = NSLocalizedString(pane.panelTitle, comment: "")
            
            return cell
        }
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 28 }
        switch rows[row] {
        case .separator: return 12
        case .pane: return 28
        }
    }
    
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        return false
    }
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        switch rows[row] {
        case .separator: return false
        case .pane: return true
        }
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, let index = paneIndex(for: selectedRow) else { return }
        
        selectedIndex = index
        delegate?.sidebarDidSelectPane(at: index)
    }
}
