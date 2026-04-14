// Copyright (c) 2021, OpenEmu Team
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
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKit

final class GameControlsBar: NSWindow {
    
    static let showsAutoSaveStateKey = "HUDBarShowAutosaveState"
    static let showsQuickSaveStateKey = "HUDBarShowQuicksaveState"
    static let showsAudioOutputKey = "HUDBarShowAudioOutput"
    private static let fadeOutDelayKey = "fadeoutdelay"
    private static let initializeDefaults: Void = {
        UserDefaults.standard.register(defaults: [
            // Time until hud controls bar fades out
            fadeOutDelayKey : 1.5,
            showsAutoSaveStateKey : false,
            showsQuickSaveStateKey : false,
            showsAudioOutputKey : false,
        ])
    }()
    
    @objc var canShow = true
    private var eventMonitor: Any?
    private var fadeTimer: Timer?
    var controlsView: GameControlsBarView!
    weak var gameViewController: GameViewController!
    private var lastGameWindowFrame = NSRect.zero
    /// Systems where mouse is used for gameplay (Flash, DS touch, Wii pointer)
    private var usesMouseForGameplay = false
    private(set) var isCollapsed = false
    private var isAnimating = false
    private var collapsedWindow: NSWindow?
    private var expandedBarSize = NSSize.zero
    private static let collapsedSize: CGFloat = 36
    private var lastMouseMovement: Date! {
        willSet {
            if fadeTimer == nil {
                let interval = TimeInterval(UserDefaults.standard.double(forKey: Self.fadeOutDelayKey))
                fadeTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(timerDidFire(_:)), userInfo: nil, repeats: true)
            }
        }
    }
    
    var gameWindow: NSWindow? {
        willSet {
            // un-register notifications for parent window
            if parent != nil {
                let nc = NotificationCenter.default
                nc.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: gameWindow)
                nc.removeObserver(self, name: NSWindow.willExitFullScreenNotification, object: gameWindow)
                nc.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: gameWindow)
            }
            // remove from parent window if there was one, and attach to to the new game window
            if (gameWindow == nil || parent != nil) && newValue != parent {
                parent?.removeChildWindow(self)
                newValue?.addChildWindow(self, ordered: .above)
            }
        }
        didSet {
            // register notifications and update state of the fullscreen button
            if let gameWindow = gameWindow {
                let nc = NotificationCenter.default
                nc.addObserver(self, selector: #selector(gameWindowDidEnterFullScreen(_:)), name: NSWindow.didEnterFullScreenNotification, object: gameWindow)
                nc.addObserver(self, selector: #selector(gameWindowWillExitFullScreen(_:)), name: NSWindow.willExitFullScreenNotification, object: gameWindow)
                
                controlsView.reflectFullScreen(gameWindow.isFullScreen)
            }
        }
    }
    
    init(gameViewController controller: GameViewController) {
        let mouseGameplaySystems = [
            "openemu.system.flash",
            "openemu.system.nds",
            "openemu.system.wii"
        ]
        let mouseMode = mouseGameplaySystems.contains(controller.systemIdentifier)
        let barWidth: CGFloat
        var barRect: NSRect

        if #available(macOS 26, *) {
            barWidth = 444
            barRect = NSRect(x: 0, y: 0, width: barWidth, height: 42)
            super.init(contentRect: barRect, styleMask: .borderless, backing: .buffered, defer: true)
        } else {
            barWidth = 490
            let useNew = OEAppearance.hudBar == .vibrant
            barRect = NSRect(x: 0, y: 0, width: barWidth, height: useNew ? 42 : 45)
            super.init(contentRect: barRect, styleMask: useNew ? .titled : .borderless, backing: .buffered, defer: true)
        }

        isMovableByWindowBackground = true
        animationBehavior = .none

        gameViewController = controller
        usesMouseForGameplay = mouseMode
        expandedBarSize = barRect.size

        if #available(macOS 26, *) {
            backgroundColor = .clear
            isOpaque = false
            hasShadow = false

            let glassView = NSGlassEffectView(frame: barRect)
            glassView.style = .clear
            glassView.cornerRadius = 21
            glassView.tintColor = .clear
            contentView = glassView

            let barView = GameControlsBarView(frame: barRect)
            controlsView = barView
            glassView.contentView = barView
        } else {
            let useNew = OEAppearance.hudBar == .vibrant
            if useNew {
                titlebarAppearsTransparent = true
                titleVisibility = .hidden
                styleMask.insert(.fullSizeContentView)
                appearance = NSAppearance(named: .vibrantDark)

                let veView = NSVisualEffectView()
                veView.material = .hudWindow
                veView.state = .active
                contentView = veView
            } else {
                backgroundColor = .clear
            }

            let barView = GameControlsBarView(frame: barRect)
            contentView?.addSubview(barView)
            controlsView = barView
        }

        alphaValue = 0

        controlsView.onCollapse = { [weak self] in self?.collapse() }
        setupCollapsedWindow()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            if NSApp.isActive, let self = self, let gameWindow = self.gameWindow, gameWindow.isMainWindow {
                self.performSelector(onMainThread: #selector(self.mouseMoved(with:)), with: event, waitUntilDone: false)
            }
            return event
        }

        if !usesMouseForGameplay {
            NSCursor.setHiddenUntilMouseMoves(true)
        }

        let nc = NotificationCenter.default
        // Show HUD when switching back from other applications
        nc.addObserver(self, selector: #selector(mouseMoved(with:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(willMove(_:)), name: NSWindow.willMoveNotification, object: self)
        nc.addObserver(self, selector: #selector(didMove(_:)), name: NSWindow.didMoveNotification, object: self)

        Self.initializeDefaults
    }
    
    /// Immediately hide and detach all windows (bar + collapsed circle).
    /// Called during game close to prevent orphaned windows.
    func tearDown() {
        fadeTimer?.invalidate()
        fadeTimer = nil

        // Hide and detach the collapsed circle window
        if let cw = collapsedWindow {
            cw.parent?.removeChildWindow(cw)
            cw.orderOut(nil)
        }

        // Hide the main bar
        alphaValue = 0
        isCollapsed = false
    }

    deinit {
        fadeTimer?.invalidate()
        fadeTimer = nil
        gameViewController = nil

        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }

        if let cw = collapsedWindow {
            cw.parent?.removeChildWindow(cw)
            cw.orderOut(nil)
            collapsedWindow = nil
        }

        gameWindow = nil
    }
    
    override var canBecomeKey: Bool {
        return false
    }
    
    override var canBecomeMain: Bool {
        return false
    }
    
    private var bounds: NSRect {
        var bounds = frame
        bounds.origin = NSPoint(x: 0, y: 0)
        return bounds
    }
    
    // MARK: - Manage Visibility
    
    func show() {
        if isCollapsed {
            expand()
            return
        }
        if canShow {
            animator().alphaValue = 1
        }
    }

    /// Prevents the HUD bar from auto-hiding. Used during controller navigation.
    func holdVisible() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        if canShow {
            animator().alphaValue = 1
        }
    }

    /// Resumes normal auto-hide behavior after controller navigation ends.
    func resumeAutoHide() {
        lastMouseMovement = Date()
    }

    func hide(animated: Bool = true, hideCursor: Bool = true) {
        // All cores collapse into circle button instead of fading away
        collapse()
        fadeTimer?.invalidate()
        fadeTimer = nil

        if !usesMouseForGameplay {
            NSCursor.setHiddenUntilMouseMoves(hideCursor)
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        performMouseMoved()
    }
    
    private func performMouseMoved() {
        guard let gameWindow = gameWindow else { return }

        // In Flash mode, don't auto-expand from collapsed state on mouse movement
        // since Flash games use the mouse for gameplay input
        if usesMouseForGameplay && isCollapsed {
            return
        }

        let gameView = gameViewController.view
        let viewFrame = gameView.frame
        let mouseLoc = NSEvent.mouseLocation

        let viewFrameOnScreen = gameWindow.convertToScreen(viewFrame)
        if !viewFrameOnScreen.contains(mouseLoc) {
            return
        }

        // For non-Flash cores, auto-expand from collapsed state on mouse movement
        if !usesMouseForGameplay && isCollapsed {
            expand()
        }

        if alphaValue == 0 {
            lastMouseMovement = Date()
            show()
        }

        lastMouseMovement = Date()
    }
    
    @objc private func timerDidFire(_ timer: Timer) {
        let interval = TimeInterval(UserDefaults.standard.double(forKey: Self.fadeOutDelayKey))
        let hideDate = lastMouseMovement.addingTimeInterval(interval)
        
        if hideDate.timeIntervalSinceNow <= 0 {
            if canFadeOut {
                fadeTimer?.invalidate()
                fadeTimer = nil
                
                hide()
            } else {
                let interval = TimeInterval(UserDefaults.standard.double(forKey: Self.fadeOutDelayKey))
                let nextTime = Date(timeIntervalSinceNow: interval)
                
                fadeTimer?.fireDate = nextTime
            }
        } else {
            fadeTimer?.fireDate = hideDate
        }
    }
    
    private var canFadeOut: Bool {
        return !bounds.contains(mouseLocationOutsideOfEventStream)
    }
    
    func repositionOnGameWindow() {
        guard let gameWindow = gameWindow, parent != nil else { return }

        if isCollapsed {
            let margin: CGFloat = 19
            let size = Self.collapsedSize
            let gameViewFrame = gameViewController.view.frame
            let gameViewFrameInWindow = gameViewController.view.convert(gameViewFrame, to: nil)
            let screenOrigin = gameWindow.convertToScreen(gameViewFrameInWindow).origin
            let origin = NSPoint(
                x: screenOrigin.x + gameViewFrame.width - size - margin,
                y: screenOrigin.y + margin
            )
            collapsedWindow?.setFrameOrigin(origin)
            return
        }

        let controlsMargin: CGFloat = 19
        let gameView = gameViewController.view
        let gameViewFrame = gameView.frame
        let gameViewFrameInWindow = gameView.convert(gameViewFrame, to: nil)
        var origin = gameWindow.convertToScreen(gameViewFrameInWindow).origin
        
        origin.x += (gameViewFrame.width - frame.width) / 2
        
        // If the controls bar fits, it sits over the window
        if gameViewFrame.width >= frame.width {
            origin.y += controlsMargin
        } else {
            // Otherwise, it sits below the window
            origin.y -= (frame.height + controlsMargin)
            
            // Unless below the window means it being off-screen, in which case it sits above the window
            if origin.y < gameWindow.screen?.visibleFrame.minY ?? 0 {
                origin.y = gameWindow.frame.maxY + controlsMargin
            }
        }
        
        setFrameOrigin(origin)
    }
    
    // MARK: - Collapsible Bar (Flash Mode)

    private func setupCollapsedWindow() {
        let size = Self.collapsedSize
        let rect = NSRect(x: 0, y: 0, width: size, height: size)

        let win = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: true)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.animationBehavior = .none
        win.level = level
        win.isMovableByWindowBackground = false

        let clickView = CollapsedClickView(frame: rect)
        clickView.onClick = { [weak self] in self?.expand() }

        if #available(macOS 26, *) {
            let glassView = NSGlassEffectView(frame: rect)
            glassView.style = .clear
            glassView.cornerRadius = size / 2
            glassView.tintColor = .clear

            let iconView = NSImageView(frame: rect.insetBy(dx: 6, dy: 6))
            iconView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Show Controls")
            iconView.contentTintColor = .white
            iconView.imageAlignment = .alignCenter
            iconView.imageScaling = .scaleProportionallyDown
            clickView.addSubview(iconView)

            glassView.contentView = clickView
            win.contentView = glassView
        } else {
            clickView.wantsLayer = true
            clickView.layer?.cornerRadius = size / 2
            clickView.layer?.masksToBounds = true
            clickView.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.85).cgColor
            clickView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            clickView.layer?.borderWidth = 1

            let iconView = NSImageView(frame: rect.insetBy(dx: 6, dy: 6))
            iconView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Show Controls")
            iconView.contentTintColor = .white
            iconView.imageAlignment = .alignCenter
            iconView.imageScaling = .scaleProportionallyDown
            clickView.addSubview(iconView)

            win.contentView = clickView
        }

        collapsedWindow = win
    }

    func collapse() {
        guard !isCollapsed, !isAnimating else { return }
        isCollapsed = true
        isAnimating = true

        guard let gameWindow = gameWindow, let cw = collapsedWindow else {
            isAnimating = false
            return
        }

        let size = Self.collapsedSize
        let margin: CGFloat = 19
        let gameViewFrame = gameViewController.view.frame
        let gameViewFrameInWindow = gameViewController.view.convert(gameViewFrame, to: nil)
        let screenOrigin = gameWindow.convertToScreen(gameViewFrameInWindow).origin
        let targetOrigin = NSPoint(
            x: screenOrigin.x + gameViewFrame.width - size - margin,
            y: screenOrigin.y + margin
        )

        if #available(macOS 26, *), let glassView = contentView as? NSGlassEffectView {
            // Liquid glass morph: shrink bar into circle
            controlsView.isHidden = true
            let targetFrame = NSRect(origin: targetOrigin, size: NSSize(width: size, height: size))

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(targetFrame, display: true)
                glassView.animator().cornerRadius = size / 2
            }, completionHandler: { [weak self] in
                guard let self = self else { return }
                self.alphaValue = 0
                // Reset bar to expanded state for later use
                self.setFrame(NSRect(origin: self.frame.origin, size: self.expandedBarSize), display: false)
                glassView.cornerRadius = 21
                self.controlsView.isHidden = false

                cw.setFrameOrigin(targetOrigin)
                cw.alphaValue = 1
                gameWindow.addChildWindow(cw, ordered: .above)
                cw.orderFront(nil)
                self.isAnimating = false
            })
        } else {
            cw.setFrameOrigin(targetOrigin)
            cw.alphaValue = 0
            gameWindow.addChildWindow(cw, ordered: .above)
            cw.orderFront(nil)

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                self.animator().alphaValue = 0
                cw.animator().alphaValue = 0.7
            }, completionHandler: { [weak self] in
                self?.isAnimating = false
            })
        }

        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    func expand() {
        guard isCollapsed, !isAnimating else { return }
        isCollapsed = false
        isAnimating = true

        if #available(macOS 26, *), let glassView = contentView as? NSGlassEffectView,
           let gameWindow = gameWindow {
            let size = Self.collapsedSize
            let collapsedFrame = collapsedWindow?.frame ?? NSRect(origin: frame.origin, size: NSSize(width: size, height: size))

            // Calculate expanded position
            let controlsMargin: CGFloat = 19
            let gameViewFrame = gameViewController.view.frame
            let gameViewFrameInWindow = gameViewController.view.convert(gameViewFrame, to: nil)
            var expandedOrigin = gameWindow.convertToScreen(gameViewFrameInWindow).origin
            expandedOrigin.x += (gameViewFrame.width - expandedBarSize.width) / 2
            if gameViewFrame.width >= expandedBarSize.width {
                expandedOrigin.y += controlsMargin
            } else {
                expandedOrigin.y -= (expandedBarSize.height + controlsMargin)
                if expandedOrigin.y < gameWindow.screen?.visibleFrame.minY ?? 0 {
                    expandedOrigin.y = gameWindow.frame.maxY + controlsMargin
                }
            }
            let expandedFrame = NSRect(origin: expandedOrigin, size: expandedBarSize)

            // Start at collapsed state (still invisible)
            setFrame(collapsedFrame, display: false)
            glassView.cornerRadius = size / 2
            controlsView.isHidden = true
            alphaValue = 1

            // Remove collapsed window (main bar is now visible in its place)
            if let cw = collapsedWindow {
                gameWindow.removeChildWindow(cw)
                cw.orderOut(nil)
            }

            // Liquid glass morph: grow circle into bar
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(expandedFrame, display: true)
                glassView.animator().cornerRadius = 21
            }, completionHandler: { [weak self] in
                self?.controlsView.isHidden = false
                self?.isAnimating = false
            })
        } else {
            if let cw = collapsedWindow {
                gameWindow?.removeChildWindow(cw)
                cw.orderOut(nil)
            }

            repositionOnGameWindow()

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                self.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                self?.isAnimating = false
            })
        }

        lastMouseMovement = Date()
    }

    // MARK: -

    @objc private func willMove(_ notification: Notification) {
        if let parentWindow = parent {
            lastGameWindowFrame = parentWindow.frame
        }
    }
    
    @objc private func didMove(_ notification: Notification) {
        var userMoved = false
        if let parentWindow = parent {
            userMoved = parentWindow.frame.equalTo(lastGameWindowFrame)
        } else {
            userMoved = true
        }
        adjustWindowAttachment(userMoved)
    }
    
    private func adjustWindowAttachment(_ userMovesGameWindow: Bool) {
        let barScreen = screen
        let gameScreen = gameWindow?.screen
        let screensDiffer = barScreen != gameScreen
        
        if userMovesGameWindow && screensDiffer && parent != nil && barScreen != nil {
            let frame = frame
            orderOut(nil)
            setFrame(.zero, display: false)
            setFrame(frame, display: false)
            orderFront(self)
        }
        else if !screensDiffer && parent == nil {
            // attach to window and center the controls bar
            gameWindow?.addChildWindow(self, ordered: .above)
            repositionOnGameWindow()
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        adjustWindowAttachment(false)
    }
    
    // MARK: - Updating UI States
    
    func reflectVolume(_ volume: Float) {
        controlsView.reflectVolume(volume)
    }
    
    func reflectEmulationPaused(_ isPaused: Bool) {
        controlsView.reflectEmulationPaused(isPaused)
    }
    
    @objc private func gameWindowDidEnterFullScreen(_ notification: Notification) {
        controlsView.reflectFullScreen(true)
        // Show HUD because fullscreen animation makes the cursor appear
        performMouseMoved()
    }
    
    @objc private func gameWindowWillExitFullScreen(_ notification: Notification) {
        controlsView.reflectFullScreen(false)
    }
    
    // MARK: - Menus
    
    var optionsMenu: NSMenu {
        let menu = NSMenu()
        
        var item = NSMenuItem(title: NSLocalizedString("Edit Game Controls…", comment: ""), action: #selector(OEGameDocument.editControls(_:)), keyEquivalent: "")
        menu.addItem(item)
        
        // insert cart/disk/tape
        if gameViewController.supportsFileInsertion {
            item = NSMenuItem(title: NSLocalizedString("Insert Cart/Disk/Tape…", comment: ""), action: #selector(OEGameDocument.insertFile(_:)), keyEquivalent: "")
            menu.addItem(item)
        }
        
        // cheats
        if gameViewController.supportsCheats {
            item = NSMenuItem()
            item.title = NSLocalizedString("Select Cheat", comment: "")
            item.submenu = cheatsMenu
            menu.addItem(item)
        }
        
        // core selection
        if let coresMenu = coresMenu {
            item = NSMenuItem()
            item.title = NSLocalizedString("Select Core", comment: "")
            item.submenu = coresMenu
            menu.addItem(item)
        }
        
        // disc selection
        if gameViewController.supportsMultipleDiscs {
            let maxDiscs = gameViewController.document.discCount
            item = NSMenuItem()
            item.title = NSLocalizedString("Select Disc", comment: "")
            item.submenu = maxDiscs > 1 ? discsMenu : nil
            item.isEnabled = maxDiscs > 1 ? true : false
            menu.addItem(item)
        }
        
        // display mode
        if gameViewController.supportsDisplayModeChange,
           !gameViewController.document.displayModes.isEmpty {
            item = NSMenuItem()
            item.title = NSLocalizedString("Select Display Mode", comment: "")
            item.submenu = displayModesMenu
            menu.addItem(item)
        }

        // peripheral devices (controller ports)
        if gameViewController.supportsPeripheralDeviceChange,
           !gameViewController.document.peripheralDevices.isEmpty {
            item = NSMenuItem()
            item.title = NSLocalizedString("Controller Ports", comment: "")
            item.submenu = peripheralDevicesMenu
            menu.addItem(item)
        }

        // joystick port swap (for computer systems like C64, Amiga)
        if gameViewController.document.supportsJoystickPortSwap {
            item = NSMenuItem(title: NSLocalizedString("Swap Joystick Ports", comment: ""),
                              action: #selector(OEGameDocument.swapJoystickPorts(_:)),
                              keyEquivalent: "")
            item.state = gameViewController.document.joystickPortsSwapped ? .on : .off
            menu.addItem(item)
        }

        // video shader
        item = NSMenuItem()
        item.title = NSLocalizedString("Select Shader", comment: "")
        item.submenu = shadersMenu
        menu.addItem(item)
        
        // integral scaling
        item = NSMenuItem()
        item.title = NSLocalizedString("Select Scale", comment: "")
        if let scaleMenu = scaleMenu {
            item.submenu = scaleMenu
        } else {
            item.isEnabled = false
        }
        menu.addItem(item)
        
        // audio output
        if UserDefaults.standard.bool(forKey: Self.showsAudioOutputKey) {
            item = NSMenuItem()
            item.title = NSLocalizedString("Select Audio Output Device", comment: "")
            if let audioOutputMenu = audioOutputMenu {
                item.submenu = audioOutputMenu
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        
        return menu
    }
    
    var cheatsMenu: NSMenu {
        let menu = NSMenu()
        
        let item = NSMenuItem(title: NSLocalizedString("Add Cheat…", comment: ""), action: #selector(OEGameDocument.addCheat(_:)), keyEquivalent: "")
        menu.addItem(item)
        
        let cheats = gameViewController.document.cheats
        if !cheats.isEmpty {
            menu.addItem(.separator())
            
            for cheat in cheats {
                let item = NSMenuItem(title: cheat.name, action: #selector(OEGameDocument.toggleCheat(_:)), keyEquivalent: "")
                item.representedObject = cheat
                item.state = cheat.isEnabled ? .on : .off
                
                menu.addItem(item)
            }
        }
        
        return menu
    }
    
    var coresMenu: NSMenu? {
        let systemIdentifier = gameViewController.systemIdentifier
        var corePlugins = OECorePlugin.corePlugins(forSystemIdentifier: systemIdentifier)
        guard corePlugins.count > 1
        else { return nil }
        
        let menu = NSMenu()
        
        corePlugins.sort { ($0.displayName).localizedStandardCompare($1.displayName) == .orderedAscending }
        
        for plugin in corePlugins {
            let item = NSMenuItem(title: plugin.displayName, action: #selector(OEGameDocument.switchCore(_:)), keyEquivalent: "")
            item.representedObject = plugin
            
            if plugin.bundleIdentifier == gameViewController.coreIdentifier {
                item.state = .on
            }
            
            menu.addItem(item)
        }
        
        return menu
    }
    
    var discsMenu: NSMenu {
        let menu = NSMenu()
        
        let maxDiscs = gameViewController.document.discCount
        for disc in 1...maxDiscs {
            let title = String(format: NSLocalizedString("Disc %u", comment: "Disc selection menu item title"), disc)
            let item = NSMenuItem(title: title, action: #selector(OEGameDocument.setDisc(_:)), keyEquivalent: "")
            item.representedObject = disc
            
            menu.addItem(item)
        }
        
        return menu
    }
    
    var displayModesMenu: NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        var mode: String
        var selected: Bool
        var enabled: Bool
        var indentationLevel: Int
        
        for modeDict in gameViewController.document.displayModes {
            if modeDict[OEGameCoreDisplayModeSeparatorItemKey] != nil {
                menu.addItem(.separator())
                continue
            }
            
            mode             = modeDict[OEGameCoreDisplayModeNameKey] as? String ??
                               modeDict[OEGameCoreDisplayModeLabelKey] as? String ?? ""
            selected         = modeDict[OEGameCoreDisplayModeStateKey] as? Bool ?? false
            enabled          = modeDict[OEGameCoreDisplayModeLabelKey] != nil ? false : true
            indentationLevel = modeDict[OEGameCoreDisplayModeIndentationLevelKey] as? Int ?? 0
            
            // Submenu group
            if modeDict[OEGameCoreDisplayModeGroupNameKey] != nil {
                // Setup Submenu
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                
                let item = NSMenuItem()
                item.title = modeDict[OEGameCoreDisplayModeGroupNameKey] as? String ?? ""
                item.submenu = submenu
                menu.addItem(item)
                
                // Submenu items
                for subModeDict in modeDict[OEGameCoreDisplayModeGroupItemsKey] as? [[String : AnyObject]] ?? [] {
                    // Disallow deeper submenus
                    if subModeDict[OEGameCoreDisplayModeGroupNameKey] != nil {
                        continue
                    }
                    
                    if subModeDict[OEGameCoreDisplayModeSeparatorItemKey] != nil {
                        submenu.addItem(.separator())
                        continue
                    }
                    
                    mode             = subModeDict[OEGameCoreDisplayModeNameKey] as? String ??
                                       subModeDict[OEGameCoreDisplayModeLabelKey] as? String ?? ""
                    selected         = subModeDict[OEGameCoreDisplayModeStateKey] as? Bool ?? false
                    enabled          = subModeDict[OEGameCoreDisplayModeLabelKey] != nil ? false : true
                    indentationLevel = subModeDict[OEGameCoreDisplayModeIndentationLevelKey] as? Int ?? 0
                    
                    let submenuItem = NSMenuItem(title: mode, action: #selector(OEGameDocument.changeDisplayMode(_:)), keyEquivalent: "")
                    submenuItem.representedObject = subModeDict
                    submenuItem.state = selected ? .on : .off
                    submenuItem.isEnabled = enabled
                    submenuItem.indentationLevel = indentationLevel
                    submenu.addItem(submenuItem)
                }
                
                continue
            }
            
            let item = NSMenuItem(title: mode, action: #selector(OEGameDocument.changeDisplayMode(_:)), keyEquivalent: "")
            item.representedObject = modeDict
            item.state = selected ? .on : .off
            item.isEnabled = enabled
            item.indentationLevel = indentationLevel
            menu.addItem(item)
        }
        
        return menu
    }
    
    var peripheralDevicesMenu: NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for portDict in gameViewController.document.peripheralDevices {
            let portName = portDict["OEPeripheralPortNameKey"] as? String ?? ""
            let portId = portDict["OEPeripheralPortIdentifierKey"] as? String ?? ""
            let devices = portDict["OEPeripheralPortDevicesKey"] as? [[String: Any]] ?? []

            let portSubmenu = NSMenu()
            portSubmenu.autoenablesItems = false

            for deviceDict in devices {
                let deviceName = deviceDict["OEPeripheralDeviceNameKey"] as? String ?? ""
                let deviceId = deviceDict["OEPeripheralDeviceIdentifierKey"] as? String ?? ""
                let selected = deviceDict["OEPeripheralDeviceSelectedKey"] as? Bool ?? false

                let deviceItem = NSMenuItem(
                    title: deviceName,
                    action: #selector(OEGameDocument.changePeripheralDevice(_:)),
                    keyEquivalent: ""
                )
                deviceItem.representedObject = ["portIdentifier": portId, "deviceIdentifier": deviceId]
                deviceItem.state = selected ? .on : .off
                portSubmenu.addItem(deviceItem)
            }

            // Expansion sub-ports
            if let expansions = portDict["OEPeripheralPortExpansionsKey"] as? [[String: Any]], !expansions.isEmpty {
                portSubmenu.addItem(.separator())
                for expDict in expansions {
                    let expName = expDict["OEPeripheralPortNameKey"] as? String ?? ""
                    let expPortId = expDict["OEPeripheralPortIdentifierKey"] as? String ?? ""
                    let expDevices = expDict["OEPeripheralPortDevicesKey"] as? [[String: Any]] ?? []

                    let expSubmenu = NSMenu()
                    expSubmenu.autoenablesItems = false

                    for expDeviceDict in expDevices {
                        let expDeviceName = expDeviceDict["OEPeripheralDeviceNameKey"] as? String ?? ""
                        let expDeviceId = expDeviceDict["OEPeripheralDeviceIdentifierKey"] as? String ?? ""
                        let expSelected = expDeviceDict["OEPeripheralDeviceSelectedKey"] as? Bool ?? false

                        let expDeviceItem = NSMenuItem(
                            title: expDeviceName,
                            action: #selector(OEGameDocument.changePeripheralDevice(_:)),
                            keyEquivalent: ""
                        )
                        expDeviceItem.representedObject = ["portIdentifier": expPortId, "deviceIdentifier": expDeviceId]
                        expDeviceItem.state = expSelected ? .on : .off
                        expSubmenu.addItem(expDeviceItem)
                    }

                    let expItem = NSMenuItem()
                    expItem.title = expName
                    expItem.submenu = expSubmenu
                    portSubmenu.addItem(expItem)
                }
            }

            let portItem = NSMenuItem()
            portItem.title = portName
            portItem.submenu = portSubmenu
            menu.addItem(portItem)
        }

        menu.addItem(.separator())
        let resetItem = NSMenuItem(
            title: NSLocalizedString("Reset to Default", comment: ""),
            action: #selector(OEGameDocument.resetPeripheralDevices(_:)),
            keyEquivalent: ""
        )
        menu.addItem(resetItem)

        return menu
    }

    var shadersMenu: NSMenu {
        let menu = NSMenu()
        
        let item = NSMenuItem(title: NSLocalizedString("Configure Shader…", comment: ""), action: #selector(GameViewController.configureShader(_:)), keyEquivalent: "")
        menu.addItem(item)
        menu.addItem(.separator())
        
        let selectedShader = gameViewController.shaderControl.preset.shader.name
        
        // add system shaders first
        let sortedSystemShaders = OEShaderStore.shared.sortedSystemShaderNames
        for shaderName in sortedSystemShaders {
            let item = NSMenuItem(title: shaderName, action: #selector(GameViewController.selectShader(_:)), keyEquivalent: "")
            
            if shaderName == selectedShader {
                item.state = .on
            }
            
            menu.addItem(item)
        }
        
        // add custom shaders
        let sortedCustomShaders = OEShaderStore.shared.sortedCustomShaderNames
        if !sortedCustomShaders.isEmpty {
            menu.addItem(.separator())
            
            for shaderName in sortedCustomShaders {
                let item = NSMenuItem(title: shaderName, action: #selector(GameViewController.selectShader(_:)), keyEquivalent: "")
                
                if shaderName == selectedShader {
                    item.state = .on
                }
                
                menu.addItem(item)
            }
        }
        
        return menu
    }
    
    var scaleMenu: NSMenu? {
        guard let delegate = gameViewController.integralScalingDelegate,
              delegate.shouldAllowIntegralScaling
        else { return nil }
        
        let maxScale = delegate.maximumIntegralScale
        let currentScale = delegate.currentIntegralScale
        
        let menu = NSMenu()
        
        for scale in 1...maxScale {
            let title = String(format: NSLocalizedString("%ux", comment: "Integral scale menu item title"), scale)
            let item = NSMenuItem(title: title, action: #selector(GameWindowController.changeIntegralScale(_:)), keyEquivalent: "")
            item.representedObject = scale
            item.state = scale == currentScale ? .on : .off
            menu.addItem(item)
        }
        
        if gameWindow?.isFullScreen ?? false {
            let item = NSMenuItem(title: NSLocalizedString("Fill Screen", comment: "Integral scale menu item title"), action: #selector(GameWindowController.changeIntegralScale), keyEquivalent: "")
            item.representedObject = 0
            item.state = currentScale == 0 ? .on : .off
            menu.addItem(item)
        }
        
        return menu
    }
    
    var audioOutputMenu: NSMenu? {
        let menu = NSMenu()
        
        let audioOutputDevices = OEAudioDeviceManager.shared.audioDevices.filter { $0.numberOfOutputChannels > 0 }
        
        if audioOutputDevices.isEmpty {
            return nil
        }
        
        let item = NSMenuItem(title: NSLocalizedString("System Default", comment: "Default audio device setting"), action: #selector(OEGameDocument.changeAudioOutputDeviceToSystemDefault(_:)), keyEquivalent: "")
        menu.addItem(item)
        
        menu.addItem(.separator())
        
        for device in audioOutputDevices {
            let item = NSMenuItem(title: device.deviceName, action: #selector(OEGameDocument.changeAudioOutputDevice(_:)), keyEquivalent: "")
            item.representedObject = device
            menu.addItem(item)
        }
        
        return menu
    }
    
    var saveMenu: NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        let item = NSMenuItem(title: NSLocalizedString("Save Current Game…", comment: ""), action: #selector(OEGlobalEventsHandler.saveState(_:)), keyEquivalent: "")
        item.isEnabled = gameViewController.supportsSaveStates
        menu.addItem(item)
        
        guard gameViewController.supportsSaveStates,
              let rom = gameViewController.document.rom
        else { return menu }
        rom.removeMissingStates()
        
        let includeAutoSaveState = UserDefaults.standard.bool(forKey: Self.showsAutoSaveStateKey)
        let includeQuickSaveState = UserDefaults.standard.bool(forKey: Self.showsQuickSaveStateKey)
        let useQuickSaveSlots = UserDefaults.standard.bool(forKey: OEDBSaveState.useQuickSaveSlotsKey)
        var saveStates = rom.normalSaveStatesByTimestamp(ascending: true)
        
        if includeQuickSaveState && !useQuickSaveSlots, let quickSaveState = rom.quickSaveState(inSlot: 0) {
            saveStates.insert(quickSaveState, at: 0)
        }
        
        if includeAutoSaveState, let autosaveState = rom.autosaveState {
            saveStates.insert(autosaveState, at: 0)
        }
        
        if !saveStates.isEmpty || (includeQuickSaveState && useQuickSaveSlots) {
            menu.addItem(.separator())
            
            var item = NSMenuItem(title: NSLocalizedString("Load", comment: ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            
            item = NSMenuItem(title: NSLocalizedString("Delete", comment: ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isAlternate = true
            item.keyEquivalentModifierMask = .option
            menu.addItem(item)
            
            // Build Quck Load item with submenu
            if includeQuickSaveState && useQuickSaveSlots {
                let title = NSLocalizedString("Quick Load", comment: "Quick load menu title")
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                
                let submenu = NSMenu(title: title)
                for i in 1...9 {
                    let state = rom.quickSaveState(inSlot: i)
                    
                    let title = String(format: NSLocalizedString("Slot %ld", comment: "Quick load menu item title"), i)
                    let item = NSMenuItem(title: title, action: #selector(OEGlobalEventsHandler.quickLoad(_:)), keyEquivalent: "")
                    item.isEnabled = state != nil
                    item.representedObject = i
                    submenu.addItem(item)
                }
                
                item.submenu = submenu
                menu.addItem(item)
            }
            
            // Add 'normal' save states
            for saveState in saveStates {
                let itemTitle = saveState.displayName
                
                var item = NSMenuItem(title: itemTitle, action: #selector(OEGlobalEventsHandler.loadState(_:)), keyEquivalent: "")
                item.representedObject = saveState
                item.indentationLevel = 1
                menu.addItem(item)
                
                item = NSMenuItem(title: itemTitle, action: #selector(OEGameDocument.deleteSaveState(_:)), keyEquivalent: "")
                item.representedObject = saveState
                item.isAlternate = true
                item.keyEquivalentModifierMask = .option
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }
        
        return menu
    }
}

// MARK: - Collapsed Click View

private class CollapsedClickView: NSView {
    var onClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
