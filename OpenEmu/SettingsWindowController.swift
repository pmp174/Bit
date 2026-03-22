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
import AudioToolbox.AudioServices

// Backward compatibility: existing code references PreferencesWindowController.staticProperty
typealias PreferencesWindowController = SettingsWindowController

final class SettingsWindowController: NSWindowController {
    
    // MARK: - Constants (backward compatible with PreferencesWindowController)
    
    static let debugModeKey = "debug"
    static let selectedPreferencesTabKey = "selectedPreferencesTab"
    
    static let openPaneNotificationName = Notification.Name("OEPrefOpenPane")
    static let userInfoPanelNameKey = "panelName"
    static let userInfoSystemIdentifierKey = "systemIdentifier"
    
    // MARK: - Konami Code
    
    private let konamiCode = [
        NSEvent.SpecialKey.upArrow.rawValue,
        NSEvent.SpecialKey.upArrow.rawValue,
        NSEvent.SpecialKey.downArrow.rawValue,
        NSEvent.SpecialKey.downArrow.rawValue,
        NSEvent.SpecialKey.leftArrow.rawValue,
        NSEvent.SpecialKey.rightArrow.rawValue,
        NSEvent.SpecialKey.leftArrow.rawValue,
        NSEvent.SpecialKey.rightArrow.rawValue,
        98, // 'b'
        97  // 'a'
    ]
    private var konamiCodeIndex = 0
    private var konamiCodeMonitor: AnyObject?
    
    // MARK: - Child Controllers
    
    private var splitViewController: NSSplitViewController!
    private var sidebarController: SettingsSidebarViewController!
    private var contentContainerController: SettingsContentContainerViewController!
    
    // MARK: - Panes
    
    private var panes: [PreferencePane] = []
    private var debugPane: PreferencePane?
    private var isDebugVisible = false
    
    // MARK: - Initialization
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.setFrameAutosaveName("SettingsWindow")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 650, height: 450)
        
        // Transparent titlebar lets the sidebar material extend behind
        // the traffic lights for a seamless Xcode-style appearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        
        // Make the green button zoom (expand) instead of entering full-screen mode
        window.collectionBehavior = .fullScreenNone
        
        self.init(window: window)
        
        window.delegate = self
        
        setupPanes()
        setupSplitView()
        
        // Toolbar with .unified style extends the sidebar behind the titlebar.
        // Must be configured after the split view is installed so the tracking
        // separator can reference the split view.
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        
        // Restore previously selected tab
        let savedIndex = UserDefaults.standard.integer(forKey: Self.selectedPreferencesTabKey)
        let validIndex = (0..<panes.count).contains(savedIndex) ? savedIndex : 0
        selectPane(at: validIndex, animated: false)
        
        window.center()
    }
    
    // MARK: - Setup
    
    private func setupPanes() {
        panes = [
            PrefGeneralController(),
            PrefLibraryController(),
            PrefGameplayController(),
            PrefControlsController(),
            PrefCoresAndSystemFilesController(),
        ]
        
        // Check if debug pane should be visible
        if UserDefaults.standard.bool(forKey: Self.debugModeKey) {
            debugPane = PrefDebugController()
            isDebugVisible = true
        }
    }
    
    private func setupSplitView() {
        splitViewController = NSSplitViewController()
        
        sidebarController = SettingsSidebarViewController()
        sidebarController.panes = panes
        sidebarController.debugPane = isDebugVisible ? debugPane : nil
        sidebarController.delegate = self
        
        contentContainerController = SettingsContentContainerViewController()
        
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 200
        sidebarItem.canCollapse = false
        sidebarItem.titlebarSeparatorStyle = .none
        
        let contentItem = NSSplitViewItem(viewController: contentContainerController)
        contentItem.minimumThickness = 400
        contentItem.titlebarSeparatorStyle = .line
        
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.isVertical = true
        
        window?.contentViewController = splitViewController
    }
    
    // MARK: - Pane Selection
    
    func selectPane(at index: Int, animated: Bool) {
        let allPanes = allVisiblePanes()
        guard index < allPanes.count else { return }
        
        let pane = allPanes[index]
        
        contentContainerController.showPane(pane, animated: animated)
        sidebarController.selectRow(at: index)
        
        window?.title = NSLocalizedString(pane.panelTitle, comment: "")
        updateWindowFrame(for: pane, animated: animated)
        
        // Save selection
        UserDefaults.standard.set(index, forKey: Self.selectedPreferencesTabKey)
    }
    
    func selectPaneWithTabViewIdentifier(_ identifier: String) {
        let allPanes = allVisiblePanes()
        if let index = allPanes.firstIndex(where: { $0.panelTitle == identifier }) {
            selectPane(at: index, animated: true)
        }
    }
    
    private func allVisiblePanes() -> [PreferencePane] {
        if isDebugVisible, let debug = debugPane {
            return panes + [debug]
        }
        return panes
    }
    
    // MARK: - Window Frame
    
    private func updateWindowFrame(for pane: PreferencePane, animated: Bool) {
        guard let window = window else { return }
        
        // Flexible panes fill whatever space is available — don't resize the window
        if pane.prefersFlexibleSize {
            // Just ensure the window is at least the minimum size
            var frame = window.frame
            let needsResize = frame.width < window.minSize.width || frame.height < window.minSize.height
            if needsResize {
                frame.size.width = max(frame.width, window.minSize.width)
                let newHeight = max(frame.height, window.minSize.height)
                frame.origin.y += frame.height - newHeight
                frame.size.height = newHeight
                window.setFrame(frame, display: false)
            }
            return
        }
        
        let sidebarWidth: CGFloat = 200
        let dividerWidth: CGFloat = 1
        let contentSize = pane.viewSize
        
        let contentWidth = sidebarWidth + dividerWidth + contentSize.width
        let contentHeight = contentSize.height
        
        // Convert content dimensions to window frame dimensions
        let candidateFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: contentWidth, height: contentHeight)))
        
        let newWidth = max(candidateFrame.width, window.minSize.width)
        let newHeight = max(candidateFrame.height, window.minSize.height)
        
        var frame = window.frame
        frame.origin.y += frame.height - newHeight  // Pin top edge
        frame.size.width = newWidth
        frame.size.height = newHeight
        
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduceMotion {
            window.animator().setFrame(frame, display: false)
        } else {
            window.setFrame(frame, display: false)
        }
    }
    
    // MARK: - Notification-Based Navigation
    
    func showWindow(with notification: Notification) {
        showWindow(nil)
        
        guard let identifier = (notification as NSNotification).userInfo?[Self.userInfoPanelNameKey] as? String else {
            return
        }
        
        selectPaneWithTabViewIdentifier(identifier)
        
        // If the controls pane was selected, let it handle the notification
        let allPanes = allVisiblePanes()
        if let selectedIdx = sidebarController.selectedIndex,
           selectedIdx < allPanes.count,
           let controlsPane = allPanes[selectedIdx] as? PrefControlsController {
            controlsPane.preparePane(with: notification)
        }
    }
    
    // MARK: - Debug Pane Toggle
    
    private func toggleDebugPaneVisibility() {
        if isDebugVisible {
            // Hide debug pane
            isDebugVisible = false
            sidebarController.debugPane = nil
            
            // If debug was selected, switch to first pane
            if let selectedIndex = sidebarController.selectedIndex,
               selectedIndex >= panes.count {
                selectPane(at: 0, animated: true)
            }
        } else {
            // Show debug pane
            if debugPane == nil {
                debugPane = PrefDebugController()
            }
            isDebugVisible = true
            sidebarController.debugPane = debugPane
        }
    }
}

// MARK: - NSWindowDelegate

extension SettingsWindowController: NSWindowDelegate {
    
    func windowDidBecomeKey(_ notification: Notification) {
        konamiCodeIndex = 0
        
        konamiCodeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let char = event.characters?.unicodeScalars.first,
               char.value == self.konamiCode[self.konamiCodeIndex] {
                self.konamiCodeIndex += 1
                
                if self.konamiCodeIndex == self.konamiCode.count {
                    let defaults = UserDefaults.standard
                    let debugModeActivated = !defaults.bool(forKey: SettingsWindowController.debugModeKey)
                    defaults.set(debugModeActivated, forKey: SettingsWindowController.debugModeKey)
                    
                    var soundID: SystemSoundID = 0
                    let soundURL = Bundle.main.url(forResource: "secret", withExtension: "mp3")!
                    AudioServicesCreateSystemSoundID(soundURL as CFURL, &soundID)
                    AudioServicesPlaySystemSoundWithCompletion(soundID) {
                        AudioServicesDisposeSystemSoundID(soundID)
                    }
                    
                    self.toggleDebugPaneVisibility()
                    self.konamiCodeIndex = 0
                }
                
                return nil
            }
            
            self.konamiCodeIndex = 0
            return event
        } as AnyObject?
    }
    
    func windowDidResignKey(_ notification: Notification) {
        if let konamiCodeMonitor = konamiCodeMonitor {
            NSEvent.removeMonitor(konamiCodeMonitor)
        }
        konamiCodeIndex = 0
        konamiCodeMonitor = nil
    }
}

// MARK: - SettingsSidebarDelegate

extension SettingsWindowController: SettingsSidebarDelegate {
    
    func sidebarDidSelectPane(at index: Int) {
        selectPane(at: index, animated: true)
    }
}

// MARK: - NSToolbarDelegate

extension SettingsWindowController: NSToolbarDelegate {
    
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == .sidebarTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier,
                                                  splitView: splitViewController.splitView,
                                                  dividerIndex: 0)
        }
        return nil
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }
}

// MARK: - Content Container

final class SettingsContentContainerViewController: NSViewController {
    
    private var currentPane: NSViewController?
    private var currentPaneSize: NSSize = .zero
    private var isFlexible = false
    private var scrollView: NSScrollView!
    private var documentView: NSView!
    private var flexibleConstraints: [NSLayoutConstraint] = []
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        
        documentView = FlippedView(frame: .zero)
        scrollView.documentView = documentView
        
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    func showPane(_ pane: PreferencePane, animated: Bool) {
        let newVC = pane as NSViewController
        
        if currentPane === newVC { return }
        
        // Remove old pane
        NSLayoutConstraint.deactivate(flexibleConstraints)
        flexibleConstraints = []
        if let old = currentPane {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        
        // Remove all subviews from document view
        documentView.subviews.forEach { $0.removeFromSuperview() }
        
        addChild(newVC)
        let paneView = newVC.view
        let paneSize = pane.viewSize
        isFlexible = pane.prefersFlexibleSize
        
        if isFlexible {
            // Flexible pane: fill the entire content area using Auto Layout
            paneView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(paneView)
            
            // Hide the scroll view — flexible panes manage their own scrolling
            scrollView.isHidden = true
            
            flexibleConstraints = [
                paneView.topAnchor.constraint(equalTo: view.topAnchor),
                paneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                paneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                paneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
            NSLayoutConstraint.activate(flexibleConstraints)
        } else {
            // Fixed-size pane: center in scroll view at declared size
            scrollView.isHidden = false
            
            paneView.translatesAutoresizingMaskIntoConstraints = true
            paneView.autoresizingMask = [.minXMargin, .maxXMargin]
            paneView.frame = NSRect(x: 0, y: 0, width: paneSize.width, height: paneSize.height)
            
            documentView.addSubview(paneView)
            
            let containerWidth = scrollView.contentSize.width
            let docWidth = max(containerWidth, paneSize.width)
            documentView.frame = NSRect(x: 0, y: 0, width: docWidth, height: paneSize.height)
            
            let xOffset = max(0, (docWidth - paneSize.width) / 2)
            paneView.frame.origin.x = xOffset
            
            DispatchQueue.main.async {
                self.scrollView.contentView.scroll(to: .zero)
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
        
        currentPane = newVC
        currentPaneSize = paneSize
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        
        // Re-center fixed-size pane views when the container resizes
        guard !isFlexible, let paneView = currentPane?.view, currentPaneSize.width > 0 else { return }
        
        let containerWidth = scrollView.contentSize.width
        let docWidth = max(containerWidth, currentPaneSize.width)
        documentView.frame.size.width = docWidth
        
        let xOffset = max(0, (docWidth - currentPaneSize.width) / 2)
        paneView.frame.origin.x = xOffset
    }
}

/// A flipped NSView so that content pins to the top of the scroll view.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
