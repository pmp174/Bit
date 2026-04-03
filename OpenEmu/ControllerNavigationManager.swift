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
import Quartz
import OpenEmuSystem

/// Manages game controller navigation for the library UI and in-game HUD bar.
///
/// Uses two different OEDeviceManager monitor types depending on context:
/// - Library mode: Global event monitor (safe because no game core is running)
/// - In-game mode: Unhandled event monitor (doesn't affect `hasEventMonitor`,
///   so game core input continues to flow normally)
final class ControllerNavigationManager {
    
    static let shared = ControllerNavigationManager()
    
    // MARK: - Mode
    
    enum Mode {
        case inactive
        case library
        case inGame
        case hudBar
    }
    
    private(set) var mode: Mode = .inactive
    
    /// Set by OEAlert when a dialog is visible, to prevent other handlers from
    /// processing controller events that the alert should consume.
    var alertVisible = false
    
    // MARK: - Monitor References
    
    private var libraryMonitor: AnyObject?
    private var inGameMonitor: AnyObject?
    
    // MARK: - Library State
    
    private enum LibraryFocus {
        case sidebar
        case gameGrid
    }
    
    private var libraryFocus: LibraryFocus = .gameGrid
    
    // MARK: - HUD Bar State
    
    private var hudButtonIndex: Int = 0
    
    // MARK: - Start+Select Combo
    
    private var startPressed = false
    private var selectPressed = false
    private var wasEmulationPausedBeforeHUD = false
    
    // MARK: - Button Numbers
    //
    // Face button layout differs between controllers:
    //   Xbox/Generic: A(South)=1, B(East)=2
    //   PlayStation:  Cross(South)=2, Circle(East)=3
    // Bumpers, Start, and Select are consistent across both.
    
    private let sonyVendorID: UInt = 0x054C
    
    private let buttonLBumper: UInt = 5
    private let buttonRBumper: UInt = 6
    private let buttonStart: UInt = 9
    private let buttonSelect: UInt = 10
    
    private func confirmButton(for handler: OEDeviceHandler?) -> UInt {
        if handler?.vendorID == sonyVendorID { return 2 }  // Cross
        return 1  // A
    }
    
    private func cancelButton(for handler: OEDeviceHandler?) -> UInt {
        if handler?.vendorID == sonyVendorID { return 3 }  // Circle
        return 2  // B
    }
    
    // MARK: - Debounce
    
    private var lastNavigationTime: Date = .distantPast
    private let navigationDebounceInterval: TimeInterval = 0.2
    
    // MARK: - Menu Tracking
    
    private var menuControllerMonitor: AnyObject?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    private var menuVisible = false
    private var lastMenuNavTime: Date = .distantPast
    private let menuNavDebounce: TimeInterval = 0.15
    
    private init() {
        setupMenuObservers()
    }
    
    // MARK: - Mode Activation
    
    func activateLibraryMode() {
        guard mode == .inactive else { return }
        deactivateCurrentMode()
        
        mode = .library
        libraryFocus = .gameGrid
        
        libraryMonitor = OEDeviceManager.shared.addGlobalEventMonitorHandler { [weak self] handler, event in
            self?.handleLibraryEvent(event, handler: handler)
            return true
        } as AnyObject
    }
    
    func deactivateLibraryMode() {
        if let monitor = libraryMonitor {
            OEDeviceManager.shared.removeMonitor(monitor)
            libraryMonitor = nil
        }
        if mode == .library {
            mode = .inactive
        }
    }
    
    func activateInGameMode() {
        deactivateCurrentMode()
        
        mode = .inGame
        startPressed = false
        selectPressed = false
        
        inGameMonitor = OEDeviceManager.shared.addUnhandledEventMonitorHandler { [weak self] handler, event in
            self?.handleInGameEvent(event, handler: handler)
        } as AnyObject
    }
    
    func deactivateInGameMode() {
        if mode == .hudBar {
            dismissHUDBar()
        }
        if let monitor = inGameMonitor {
            OEDeviceManager.shared.removeMonitor(monitor)
            inGameMonitor = nil
        }
        if mode == .inGame || mode == .hudBar {
            mode = .inactive
        }
    }
    
    func deactivateCurrentMode() {
        deactivateLibraryMode()
        deactivateInGameMode()
        mode = .inactive
    }
    
    // MARK: - Debounce
    
    private func shouldProcessNavigation() -> Bool {
        Date().timeIntervalSince(lastNavigationTime) >= navigationDebounceInterval
    }
    
    private func markNavigationTime() {
        lastNavigationTime = Date()
    }
    
    // MARK: - Library Event Handling
    
    private func handleLibraryEvent(_ event: OEHIDEvent, handler: OEDeviceHandler?) {
        guard mode == .library, !alertVisible, !menuVisible else { return }
        
        switch event.type {
        case .hatSwitch:
            guard shouldProcessNavigation() else { return }
            handleLibraryHatSwitch(event)
            markNavigationTime()
        case .axis:
            guard event.direction != .null, shouldProcessNavigation() else { return }
            handleLibraryAxis(event)
            markNavigationTime()
        case .button:
            handleLibraryButton(event, handler: handler)
        default:
            break
        }
    }
    
    private func handleLibraryHatSwitch(_ event: OEHIDEvent) {
        let dir = event.hatDirection
        
        switch libraryFocus {
        case .sidebar:
            if dir.contains(.north) {
                moveSidebarSelection(by: -1)
            } else if dir.contains(.south) {
                moveSidebarSelection(by: 1)
            } else if dir.contains(.east) {
                libraryFocus = .gameGrid
            }
            
        case .gameGrid:
            if dir.contains(.west) {
                libraryFocus = .sidebar
            } else if dir.contains(.north) {
                moveGridSelectionByRow(positive: false)
            } else if dir.contains(.south) {
                moveGridSelectionByRow(positive: true)
            } else if dir.contains(.east) {
                moveGridSelection(by: 1)
            }
        }
    }
    
    private func handleLibraryAxis(_ event: OEHIDEvent) {
        switch libraryFocus {
        case .sidebar:
            if event.axis == OEHIDEventAxis(rawValue: 0x31) {
                moveSidebarSelection(by: event.direction == .positive ? 1 : -1)
            } else if event.axis == OEHIDEventAxis(rawValue: 0x30), event.direction == .positive {
                libraryFocus = .gameGrid
            }
            
        case .gameGrid:
            if event.axis == OEHIDEventAxis(rawValue: 0x30) {
                if event.direction == .negative {
                    libraryFocus = .sidebar
                } else {
                    moveGridSelection(by: 1)
                }
            } else if event.axis == OEHIDEventAxis(rawValue: 0x31) {
                moveGridSelectionByRow(positive: event.direction == .positive)
            }
        }
    }
    
    private func handleLibraryButton(_ event: OEHIDEvent, handler: OEDeviceHandler?) {
        guard event.state == .on else { return }
        
        let btn = event.buttonNumber
        if btn == confirmButton(for: handler) {
            if libraryFocus == .gameGrid {
                launchSelectedGame()
            }
        } else if btn == buttonLBumper {
            libraryFocus = .sidebar
            moveSidebarSelection(by: -1)
        } else if btn == buttonRBumper {
            libraryFocus = .sidebar
            moveSidebarSelection(by: 1)
        }
    }
    
    // MARK: - Library Navigation Helpers
    
    private func moveSidebarSelection(by offset: Int) {
        DispatchQueue.main.async {
            guard let sidebarController = self.findSidebarController() else { return }
            guard let outlineView = sidebarController.sidebarView else { return }
            
            let currentRow = outlineView.selectedRow
            var newRow = currentRow + offset
            
            // Skip group header rows
            while newRow >= 0 && newRow < outlineView.numberOfRows {
                if let item = outlineView.item(atRow: newRow), item is SidebarGroupItem {
                    newRow += offset > 0 ? 1 : -1
                } else {
                    break
                }
            }
            
            guard newRow >= 0 && newRow < outlineView.numberOfRows else { return }
            outlineView.selectRowIndexes([newRow], byExtendingSelection: false)
            outlineView.scrollRowToVisible(newRow)
        }
    }
    
    private func moveGridSelection(by offset: Int) {
        DispatchQueue.main.async {
            guard let collectionController = self.findCollectionController() else { return }
            guard let gridView = collectionController.gridView else { return }

            let totalCount = (gridView.dataSource?.numberOfItems?(inImageBrowser: gridView)) ?? 0
            guard totalCount > 0 else { return }

            let currentIndexes = collectionController.selectionIndexes
            let currentIndex = currentIndexes.first ?? 0

            var newIndex = currentIndex + offset
            newIndex = max(0, min(newIndex, totalCount - 1))

            collectionController.selectionIndexes = IndexSet(integer: newIndex)
            gridView.scrollIndexToVisible(newIndex)
        }
    }

    private func moveGridSelectionByRow(positive: Bool) {
        DispatchQueue.main.async {
            guard let collectionController = self.findCollectionController() else { return }
            guard let gridView = collectionController.gridView else { return }

            // Estimate items per row from cell size and view width
            let cellWidth = gridView.cellSize().width
            let viewWidth = gridView.frame.width
            let itemsPerRow = cellWidth > 0 ? max(1, Int(viewWidth / cellWidth)) : 1
            let offset = positive ? itemsPerRow : -itemsPerRow

            let totalCount = (gridView.dataSource?.numberOfItems?(inImageBrowser: gridView)) ?? 0
            guard totalCount > 0 else { return }

            let currentIndexes = collectionController.selectionIndexes
            let currentIndex = currentIndexes.first ?? 0

            var newIndex = currentIndex + offset
            newIndex = max(0, min(newIndex, totalCount - 1))

            collectionController.selectionIndexes = IndexSet(integer: newIndex)
            gridView.scrollIndexToVisible(newIndex)
        }
    }
    
    private func launchSelectedGame() {
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(LibraryController.startSelectedGame(_:)), to: nil, from: nil)
        }
    }
    
    // MARK: - In-Game Event Handling
    
    private func handleInGameEvent(_ event: OEHIDEvent, handler: OEDeviceHandler?) {
        guard !alertVisible, !menuVisible else { return }
        
        if event.type == .button {
            // Track Start+Select combo
            if event.buttonNumber == buttonStart {
                startPressed = (event.state == .on)
            }
            if event.buttonNumber == buttonSelect {
                selectPressed = (event.state == .on)
            }
            
            if startPressed && selectPressed {
                startPressed = false
                selectPressed = false
                DispatchQueue.main.async {
                    self.toggleHUDBar()
                }
                return
            }
            
            if mode == .hudBar {
                handleHUDBarButton(event, handler: handler)
            }
        } else if mode == .hudBar {
            handleHUDBarNavigation(event)
        }
    }
    
    // MARK: - HUD Bar Navigation
    
    private func toggleHUDBar() {
        guard let gameVC = findGameViewController() else { return }
        let controlsBar = gameVC.controlsWindow!
        
        if mode == .hudBar {
            dismissHUDBar()
        } else if mode == .inGame {
            showHUDBar(controlsBar: controlsBar, gameVC: gameVC)
        }
    }
    
    private func showHUDBar(controlsBar: GameControlsBar, gameVC: GameViewController) {
        wasEmulationPausedBeforeHUD = gameVC.document.isEmulationPaused
        if !wasEmulationPausedBeforeHUD {
            gameVC.document.isEmulationPaused = true
        }
        
        controlsBar.show()
        controlsBar.holdVisible()
        
        mode = .hudBar
        hudButtonIndex = 0
        updateHUDFocusHighlight()
    }
    
    private func dismissHUDBar() {
        guard let gameVC = findGameViewController() else {
            mode = .inGame
            return
        }
        let controlsBar = gameVC.controlsWindow!
        
        controlsBar.controlsView?.setControllerFocusIndex(nil)
        controlsBar.resumeAutoHide()
        controlsBar.hide()
        
        if !wasEmulationPausedBeforeHUD {
            gameVC.document.isEmulationPaused = false
        }
        
        mode = .inGame
        startPressed = false
        selectPressed = false
    }
    
    private func handleHUDBarNavigation(_ event: OEHIDEvent) {
        guard mode == .hudBar, shouldProcessNavigation() else { return }
        
        switch event.type {
        case .hatSwitch:
            let dir = event.hatDirection
            if dir.contains(.east) {
                moveHUDSelection(by: 1)
            } else if dir.contains(.west) {
                moveHUDSelection(by: -1)
            }
            markNavigationTime()
            
        case .axis:
            guard event.axis == OEHIDEventAxis(rawValue: 0x30), event.direction != .null else { return }
            moveHUDSelection(by: event.direction == .positive ? 1 : -1)
            markNavigationTime()
            
        default:
            break
        }
    }
    
    private func handleHUDBarButton(_ event: OEHIDEvent, handler: OEDeviceHandler?) {
        guard event.state == .on, mode == .hudBar else { return }
        
        let btn = event.buttonNumber
        if btn == confirmButton(for: handler) {
            activateCurrentHUDButton()
        } else if btn == cancelButton(for: handler) {
            DispatchQueue.main.async {
                self.dismissHUDBar()
            }
        }
    }
    
    private func moveHUDSelection(by offset: Int) {
        guard let controls = findHUDBarControls() else { return }
        guard !controls.isEmpty else { return }
        
        hudButtonIndex = max(0, min(hudButtonIndex + offset, controls.count - 1))
        updateHUDFocusHighlight()
    }
    
    private func updateHUDFocusHighlight() {
        DispatchQueue.main.async {
            guard let gameVC = self.findGameViewController() else { return }
            gameVC.controlsWindow?.controlsView?.setControllerFocusIndex(self.hudButtonIndex)
        }
    }
    
    private func activateCurrentHUDButton() {
        DispatchQueue.main.async {
            guard let controls = self.findHUDBarControls() else { return }
            guard self.hudButtonIndex < controls.count else { return }
            
            let control = controls[self.hudButtonIndex]
            if let button = control as? NSButton {
                button.performClick(nil)
            }
        }
    }
    
    // MARK: - Finding UI Components

    private func findGamesViewController() -> LibraryGamesViewController? {
        guard let window = NSApp.mainWindow else { return nil }
        // Walk the view hierarchy to find a view owned by LibraryGamesViewController
        return findViewController(ofType: LibraryGamesViewController.self, in: window.contentView)
    }

    private func findViewController<T: NSViewController>(ofType type: T.Type, in view: NSView?) -> T? {
        guard let view = view else { return nil }
        if let vc = view.nextResponder as? T {
            return vc
        }
        for subview in view.subviews {
            if let found = findViewController(ofType: type, in: subview) {
                return found
            }
        }
        return nil
    }

    private func findSidebarController() -> SidebarController? {
        return findGamesViewController()?.sidebarController
    }

    private func findCollectionController() -> OEGameCollectionViewController? {
        return findGamesViewController()?.collectionController
    }
    
    private func findGameViewController() -> GameViewController? {
        let docs = NSApp.orderedDocuments.compactMap { $0 as? OEGameDocument }
        return docs.first?.gameViewController
    }
    
    private func findHUDBarControls() -> [NSView]? {
        guard let gameVC = findGameViewController() else { return nil }
        return gameVC.controlsWindow?.controlsView?.orderedControls
    }
    
    // MARK: - Menu Controller Navigation
    
    private func setupMenuObservers() {
        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.menuDidBeginTracking()
        }
        
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.menuDidEndTracking()
        }
    }
    
    private func menuDidBeginTracking() {
        menuVisible = true
        
        menuControllerMonitor = OEDeviceManager.shared.addGlobalEventMonitorHandler { [weak self] handler, event in
            guard let self = self else { return false }
            return self.handleMenuEvent(event, handler: handler)
        } as AnyObject
    }
    
    private func menuDidEndTracking() {
        menuVisible = false
        
        if let monitor = menuControllerMonitor {
            OEDeviceManager.shared.removeMonitor(monitor)
            menuControllerMonitor = nil
        }
    }
    
    private func handleMenuEvent(_ event: OEHIDEvent, handler: OEDeviceHandler?) -> Bool {
        switch event.type {
        case .hatSwitch:
            let dir = event.hatDirection
            guard Date().timeIntervalSince(lastMenuNavTime) >= menuNavDebounce else { return true }
            if dir.contains(.north) {
                synthesizeKeyPress(0x7E) // Up arrow
            } else if dir.contains(.south) {
                synthesizeKeyPress(0x7D) // Down arrow
            } else if dir.contains(.east) {
                synthesizeKeyPress(0x7C) // Right arrow (open submenu)
            } else if dir.contains(.west) {
                synthesizeKeyPress(0x7B) // Left arrow (close submenu)
            }
            lastMenuNavTime = Date()
            return true
            
        case .axis:
            guard event.direction != .null else { return true }
            guard Date().timeIntervalSince(lastMenuNavTime) >= menuNavDebounce else { return true }
            
            if event.axis == OEHIDEventAxis(rawValue: 0x31) {
                // Y axis (vertical)
                synthesizeKeyPress(event.direction == .positive ? 0x7D : 0x7E) // Down / Up
            } else if event.axis == OEHIDEventAxis(rawValue: 0x30) {
                // X axis (horizontal)
                synthesizeKeyPress(event.direction == .positive ? 0x7C : 0x7B) // Right / Left
            }
            lastMenuNavTime = Date()
            return true
            
        case .button:
            guard event.state == .on else { return true }
            let confirmBtn = confirmButton(for: handler)
            let cancelBtn = cancelButton(for: handler)
            
            if event.buttonNumber == confirmBtn {
                synthesizeKeyPress(0x24) // Return
            } else if event.buttonNumber == cancelBtn {
                synthesizeKeyPress(0x35) // Escape
            }
            return true
            
        default:
            return true
        }
    }
    
    /// Synthesizes a keyboard key press event so that NSMenu responds to
    /// controller input as if it were arrow keys / Return / Escape.
    private func synthesizeKeyPress(_ keyCode: UInt16) {
        // Map key codes to their character representations
        let chars: String
        var modifierFlags: NSEvent.ModifierFlags = []
        switch keyCode {
        case 0x7E: chars = String(Unicode.Scalar(NSUpArrowFunctionKey)!);    modifierFlags = .function
        case 0x7D: chars = String(Unicode.Scalar(NSDownArrowFunctionKey)!);  modifierFlags = .function
        case 0x7B: chars = String(Unicode.Scalar(NSLeftArrowFunctionKey)!);  modifierFlags = .function
        case 0x7C: chars = String(Unicode.Scalar(NSRightArrowFunctionKey)!); modifierFlags = .function
        case 0x24: chars = "\r"
        case 0x35: chars = "\u{1B}"
        default: return
        }
        
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        
        NSApp.postEvent(keyDown, atStart: false)
    }
}
