// Copyright (c) 2025, OpenEmu Team
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

final class PrefDeveloperController: NSViewController {
    
    private static let keyDescriptions: [Any] = [
        Group(label: "Gameplay"),
        Checkbox(key: "OEShowFPSOverlay", label: "Show FPS overlay during gameplay"),
    ]
    
    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 120))
        view = containerView
        
        let gridView = NSGridView(numberOfColumns: 2, rows: 0)
        gridView.column(at: 0).xPlacement = .trailing
        gridView.rowAlignment = .firstBaseline
        
        for item in Self.keyDescriptions {
            createRow(for: gridView, item: item)
        }
        
        gridView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(gridView)
        
        NSLayoutConstraint.activate([
            gridView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 30),
            gridView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
        ])
    }
    
    private func createRow(for gridView: NSGridView, item: Any) {
        if let item = item as? Group {
            let field = NSTextField(labelWithString: NSLocalizedString(item.label, comment: ""))
            field.font = NSFont.boldSystemFont(ofSize: 0)
            
            let row = gridView.addRow(with: [NSGridCell.emptyContentView, field])
            row.bottomPadding = 4
        }
        else if let item = item as? Checkbox {
            let label = NSLocalizedString(item.label, comment: "")
            let checkbox = NSButton(checkboxWithTitle: label, target: nil, action: nil)
            checkbox.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.\(item.key)", options: [.continuouslyUpdatesValue: true as NSNumber])
            
            gridView.addRow(with: [NSGridCell.emptyContentView, checkbox])
        }
    }
}

// MARK: - DSL Structs

private extension PrefDeveloperController {
    
    struct Group {
        let label: String
    }
    
    struct Checkbox {
        let key: String
        let label: String
    }
}

// MARK: - PreferencePane

extension PrefDeveloperController: PreferencePane {
    
    var icon: NSImage? { NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Developer") }
    
    var panelTitle: String { "Developer" }
    
    var viewSize: NSSize { NSSize(width: 468, height: 120) }
}
