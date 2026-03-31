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

final class SystemInfoPopoverViewController: NSViewController {
    
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 450))
        
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        
        let clipView = scrollView.contentView
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView
        
        container.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            
            stackView.topAnchor.constraint(equalTo: clipView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])
        
        self.view = container
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        buildContent()
    }
    
    // MARK: - Content
    
    private func buildContent() {
        // Title
        let title = makeLabel(NSLocalizedString("System Info", comment: ""), bold: true, size: NSFont.systemFontSize + 2)
        stackView.addArrangedSubview(title)
        stackView.setCustomSpacing(12, after: title)
        
        // Per-system sections
        let systems = OESystemPlugin.allPlugins.sorted { $0.systemName.localizedCaseInsensitiveCompare($1.systemName) == .orderedAscending }
        
        for plugin in systems {
            addSystemSection(plugin)
        }
        
        // Separator
        let sep1 = makeSeparator()
        stackView.addArrangedSubview(sep1)
        stackView.setCustomSpacing(8, after: sep1)
        NSLayoutConstraint.activate([
            sep1.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
        ])
        
        // CD-Based Games section
        addCDBasedGamesSection()
        
        // Separator
        let sep2 = makeSeparator()
        stackView.addArrangedSubview(sep2)
        stackView.setCustomSpacing(8, after: sep2)
        NSLayoutConstraint.activate([
            sep2.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
        ])
        
        // Multi-Disc Games section
        addMultiDiscSection()
    }
    
    private func addSystemSection(_ plugin: OESystemPlugin) {
        let systemName = makeLabel(plugin.systemName, bold: true, size: NSFont.systemFontSize)
        stackView.addArrangedSubview(systemName)
        
        // File formats
        let extensions = plugin.supportedTypeExtensions.sorted()
        if !extensions.isEmpty {
            let formatsText = extensions.map { ".\($0)" }.joined(separator: ", ")
            let formatsLabel = makeLabel(
                NSLocalizedString("Formats: ", comment: "") + formatsText,
                bold: false,
                size: NSFont.smallSystemFontSize
            )
            formatsLabel.textColor = .secondaryLabelColor
            stackView.addArrangedSubview(formatsLabel)
        }
        
        // BIOS requirements
        let cores = OECorePlugin.corePlugins(forSystemIdentifier: plugin.systemIdentifier)
        var biosFiles: [[String: Any]] = []
        for core in cores {
            if let files = core.requiredFiles(forSystemIdentifier: plugin.systemIdentifier) {
                biosFiles.append(contentsOf: files)
            }
        }
        
        // Deduplicate by Name
        var seenNames = Set<String>()
        var uniqueBIOS: [[String: Any]] = []
        for file in biosFiles {
            if let name = file["Name"] as? String, !seenNames.contains(name) {
                seenNames.insert(name)
                uniqueBIOS.append(file)
            }
        }
        
        if !uniqueBIOS.isEmpty {
            let biosHeader = makeLabel(
                NSLocalizedString("BIOS Required:", comment: ""),
                bold: false,
                size: NSFont.smallSystemFontSize
            )
            biosHeader.textColor = .secondaryLabelColor
            stackView.addArrangedSubview(biosHeader)
            
            for file in uniqueBIOS {
                let name = file["Name"] as? String ?? ""
                let desc = file["Description"] as? String ?? ""
                let available = BIOSFile.isBIOSFileAvailable(withFileInfo: file)
                let indicator = available ? "\u{25CF}" : "\u{25CF}" // filled circle
                let color: NSColor = available ? .systemGreen : .systemRed
                
                let displayText = "\(name)"
                let descText = desc.isEmpty ? "" : " - \(desc)"
                
                let attrString = NSMutableAttributedString()
                
                let indicatorAttr = NSAttributedString(
                    string: "\(indicator) ",
                    attributes: [
                        .foregroundColor: color,
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                    ]
                )
                attrString.append(indicatorAttr)
                
                let nameAttr = NSAttributedString(
                    string: displayText,
                    attributes: [
                        .foregroundColor: NSColor.labelColor,
                        .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
                    ]
                )
                attrString.append(nameAttr)
                
                let descAttr = NSAttributedString(
                    string: descText,
                    attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
                    ]
                )
                attrString.append(descAttr)
                
                let biosLabel = NSTextField(labelWithAttributedString: attrString)
                biosLabel.lineBreakMode = .byTruncatingTail
                stackView.addArrangedSubview(biosLabel)
            }
        }
        
        stackView.setCustomSpacing(10, after: stackView.arrangedSubviews.last!)
    }
    
    private func addCDBasedGamesSection() {
        let header = makeLabel(NSLocalizedString("CD-Based Games", comment: ""), bold: true, size: NSFont.systemFontSize)
        stackView.addArrangedSubview(header)
        
        let instructions = makeLabel(
            NSLocalizedString("CD-based games require .cue/.bin pairs. Import the .cue file, not the .bin file. For games with multiple .bin tracks, ensure all files are in the same folder.", comment: ""),
            bold: false,
            size: NSFont.smallSystemFontSize
        )
        instructions.textColor = .secondaryLabelColor
        instructions.preferredMaxLayoutWidth = 318
        stackView.addArrangedSubview(instructions)
        
        let linkButton = makeLinkButton(
            NSLocalizedString("View CD Guide in Browser", comment: ""),
            action: #selector(openCDGuide)
        )
        stackView.addArrangedSubview(linkButton)
        stackView.setCustomSpacing(10, after: linkButton)
    }
    
    private func addMultiDiscSection() {
        let header = makeLabel(NSLocalizedString("Multi-Disc Games", comment: ""), bold: true, size: NSFont.systemFontSize)
        stackView.addArrangedSubview(header)
        
        let instructions = makeLabel(
            NSLocalizedString("For multi-disc games, create an .m3u playlist file listing each disc's .cue file (one per line). Import the .m3u file into your library.", comment: ""),
            bold: false,
            size: NSFont.smallSystemFontSize
        )
        instructions.textColor = .secondaryLabelColor
        instructions.preferredMaxLayoutWidth = 318
        stackView.addArrangedSubview(instructions)
        
        let linkButton = makeLinkButton(
            NSLocalizedString("View Disc Guide in Browser", comment: ""),
            action: #selector(openDiscGuide)
        )
        stackView.addArrangedSubview(linkButton)
    }
    
    // MARK: - Actions
    
    @objc private func openCDGuide() {
        NSWorkspace.shared.open(.userGuideCDBasedGames)
    }
    
    @objc private func openDiscGuide() {
        NSWorkspace.shared.open(.userGuideCDBasedGames)
    }
    
    // MARK: - Helpers
    
    private func makeLabel(_ text: String, bold: Bool, size: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        return label
    }
    
    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }
    
    private func makeLinkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }
}
