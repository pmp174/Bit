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

final class PrefAppearanceController: NSViewController {
    
    private var appearancePopup: NSPopUpButton!
    private var tintButtons = [NSButton]()
    private var noneButton: NSButton!
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 423, height: 210))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
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
        
        // Set the current selection
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
        
        // "None" button
        noneButton = makeCircleButton(color: nil, tag: 0)
        noneButton.toolTip = NSLocalizedString("None", comment: "")
        tintContainer.addArrangedSubview(noneButton)
        tintButtons.append(noneButton)
        
        // Color buttons
        let tintCases: [OEAppearance.TintColor] = [.blue, .purple, .red, .orange, .yellow, .green]
        for (index, tint) in tintCases.enumerated() {
            let button = makeCircleButton(color: tint.color, tag: index + 1)
            button.toolTip = tint.displayName
            tintContainer.addArrangedSubview(button)
            tintButtons.append(button)
        }
        
        gridView.addRow(with: [tintLabel, tintContainer])
        
        // Update selection state
        updateTintSelection()
        
        gridView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gridView)
        
        NSLayoutConstraint.activate([
            gridView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gridView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
        ])
    }
    
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
            // "None" - a circle with a diagonal line through it
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
            
            // Draw a diagonal line
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
}

// MARK: - PreferencePane

extension PrefAppearanceController: PreferencePane {
    
    var icon: NSImage? { NSImage(named: NSImage.colorPanelName) }
    
    var panelTitle: String { "Appearance" }
    
    var viewSize: NSSize { NSSize(width: 423, height: 210) }
}
