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

// MARK: - FlashpointGame Model

struct FlashpointGame: Decodable {
    let id: String
    let title: String
    let developer: String
    let publisher: String
    let platform: String
    let releaseDate: String
    let originalDescription: String
    let launchCommand: String
    let applicationPath: String
    let tags: [String]
    let library: String
    let status: String
    
    enum CodingKeys: String, CodingKey {
        case id, title, developer, publisher, platform, releaseDate
        case originalDescription, launchCommand, applicationPath
        case tags, library, status
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        developer = (try? container.decode(String.self, forKey: .developer)) ?? ""
        publisher = (try? container.decode(String.self, forKey: .publisher)) ?? ""
        platform = (try? container.decode(String.self, forKey: .platform)) ?? ""
        releaseDate = (try? container.decode(String.self, forKey: .releaseDate)) ?? ""
        originalDescription = (try? container.decode(String.self, forKey: .originalDescription)) ?? ""
        launchCommand = (try? container.decode(String.self, forKey: .launchCommand)) ?? ""
        applicationPath = (try? container.decode(String.self, forKey: .applicationPath)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        library = (try? container.decode(String.self, forKey: .library)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
    }
}

// MARK: - Flashpoint API Client

private enum FlashpointAPI {
    static let baseURL = "https://db-api.unstable.life"
    
    static func searchGames(title: String? = nil, platform: String = "Flash", library: String = "arcade") async throws -> [FlashpointGame] {
        var components = URLComponents(string: "\(baseURL)/search")!
        var queryItems = [
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "library", value: library),
        ]
        if let title = title, !title.isEmpty {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode([FlashpointGame].self, from: data)
    }
}

// MARK: - Unified row model for the table view

private enum FlashLibraryRow {
    case sectionHeader(String)
    case localGame(OEDBGame)
    case flashpointGame(FlashpointGame)
}

// MARK: - FlashpointViewController

final class FlashpointViewController: NSViewController {
    
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var blankSlate: BlankSlateView?
    var database: OELibraryDatabase?
    
    private var allRows: [FlashLibraryRow] = []
    private var filteredRows: [FlashLibraryRow] = []
    
    private var localFlashGames: [OEDBGame] = []
    private var flashpointGames: [FlashpointGame] = []
    private var isLoaded = false
    
    // MARK: - View Setup
    
    override func loadView() {
        let mainView = NSView()
        
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(tableViewDoubleClick(_:))
        tableView.target = self
        tableView.style = .fullWidth
        
        // Title column
        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = NSLocalizedString("Title", comment: "Flash game title column")
        titleColumn.width = 300
        titleColumn.minWidth = 150
        titleColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(titleColumn)
        
        // Developer column
        let developerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("developer"))
        developerColumn.title = NSLocalizedString("Developer", comment: "Flash game developer column")
        developerColumn.width = 200
        developerColumn.minWidth = 100
        developerColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(developerColumn)
        
        // Source column (shows "Local" or "Flashpoint")
        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = NSLocalizedString("Source", comment: "Flash game source column")
        sourceColumn.width = 100
        sourceColumn.minWidth = 60
        sourceColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(sourceColumn)
        
        // Year column
        let yearColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("year"))
        yearColumn.title = NSLocalizedString("Year", comment: "Flash game year column")
        yearColumn.width = 80
        yearColumn.minWidth = 50
        yearColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(yearColumn)
        
        tableView.delegate = self
        tableView.dataSource = self
        
        scrollView.documentView = tableView
        mainView.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: mainView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
        ])
        
        self.view = mainView
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        validateToolbarItems()
        
        if !isLoaded {
            loadGames()
        }
    }
    
    private var toolbar: LibraryToolbar? {
        view.window?.toolbar as? LibraryToolbar
    }
    
    func validateToolbarItems() {
        guard let toolbar = toolbar else { return }
        
        toolbar.viewModeSelector.isEnabled = false
        toolbar.viewModeSelector.selectedSegment = -1
        
        toolbar.gridSizeSlider.isEnabled = false
        toolbar.decreaseGridSizeButton.isEnabled = false
        toolbar.increaseGridSizeButton.isEnabled = false
        
        // Enable search for Flash library
        toolbar.searchField.isEnabled = true
        toolbar.searchField.searchMenuTemplate = nil
        toolbar.searchField.stringValue = ""
        
        // Enable add button to allow importing .swf files
        toolbar.addButton.isEnabled = true
        toolbar.addButton.target = self
        toolbar.addButton.action = #selector(addFlashGame(_:))
        
        if #available(macOS 11.0, *) {
            for item in toolbar.items {
                if item.itemIdentifier == .oeSearch {
                    item.isEnabled = true
                }
            }
        }
    }
    
    // MARK: - Data Loading
    
    private var currentSearchTask: Task<Void, Never>?
    
    private func loadGames() {
        displayLoading()
        
        currentSearchTask?.cancel()
        currentSearchTask = Task { [weak self] in
            // Load local Flash games from Core Data
            let localGames = self?.loadLocalFlashGames() ?? []
            
            // Load Flashpoint archive games from API
            var fpGames: [FlashpointGame] = []
            do {
                fpGames = try await FlashpointAPI.searchGames()
            } catch {
                NSLog("[FlashpointViewController] Failed to load Flashpoint API: %@", error.localizedDescription)
            }
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self?.localFlashGames = localGames
                self?.flashpointGames = fpGames
                self?.isLoaded = true
                self?.rebuildRows()
                
                if localGames.isEmpty && fpGames.isEmpty {
                    self?.displayEmpty()
                } else {
                    self?.displayResults()
                }
            }
        }
    }
    
    private func loadLocalFlashGames() -> [OEDBGame] {
        guard let database = database else { return [] }
        
        let context = database.mainThreadContext
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "Game")
        fetchRequest.predicate = NSPredicate(format: "system.systemIdentifier == %@", "openemu.system.flash")
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        
        return (try? context.fetch(fetchRequest)) as? [OEDBGame] ?? []
    }
    
    private func searchFlashpointGames(title: String?) {
        currentSearchTask?.cancel()
        currentSearchTask = Task { [weak self] in
            do {
                let results = try await FlashpointAPI.searchGames(title: title)
                
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    self?.flashpointGames = results
                    self?.rebuildRows(searchQuery: title)
                    self?.tableView.reloadData()
                    
                    if (self?.filteredRows.isEmpty ?? true) {
                        self?.displayEmpty()
                    } else {
                        self?.displayResults()
                    }
                }
            } catch {
                NSLog("[FlashpointViewController] Search failed: %@", error.localizedDescription)
            }
        }
    }
    
    private func rebuildRows(searchQuery: String? = nil) {
        var rows: [FlashLibraryRow] = []
        let query = searchQuery?.lowercased()
        
        // Section: My Flash Games
        let filteredLocal: [OEDBGame]
        if let query = query, !query.isEmpty {
            filteredLocal = localFlashGames.filter {
                ($0.name ?? "").lowercased().contains(query)
            }
        } else {
            filteredLocal = localFlashGames
        }
        
        if !filteredLocal.isEmpty {
            rows.append(.sectionHeader(NSLocalizedString("My Flash Games", comment: "Flash library section header")))
            rows.append(contentsOf: filteredLocal.map { .localGame($0) })
        }
        
        // Section: Flashpoint Archive
        let filteredFP: [FlashpointGame]
        if let query = query, !query.isEmpty {
            filteredFP = flashpointGames.filter {
                $0.title.lowercased().contains(query) ||
                $0.developer.lowercased().contains(query)
            }
        } else {
            filteredFP = flashpointGames
        }
        
        if !filteredFP.isEmpty {
            rows.append(.sectionHeader(NSLocalizedString("Flashpoint Archive", comment: "Flashpoint library section header")))
            rows.append(contentsOf: filteredFP.map { .flashpointGame($0) })
        }
        
        filteredRows = rows
    }
    
    func reloadLocalGames() {
        localFlashGames = loadLocalFlashGames()
        rebuildRows()
        tableView.reloadData()
    }
    
    // MARK: - Search
    
    private var searchDebounceTask: Task<Void, Never>?
    
    @objc func search(_ sender: Any?) {
        guard let searchField = sender as? NSSearchField else { return }
        let query = searchField.stringValue
        
        // Always filter local games client-side immediately
        rebuildRows(searchQuery: query.isEmpty ? nil : query)
        tableView.reloadData()
        
        // Debounce the API search
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            searchFlashpointGames(title: query.isEmpty ? nil : query)
        }
    }
    
    // MARK: - View Management
    
    private func displayLoading() {
        let blankSlate = BlankSlateView()
        blankSlate.representedObject = BlankSlateView.Mode.flashpointLoading
        displayBlankSlate(blankSlate)
    }
    
    private func displayError(_ error: Error) {
        guard view.window != nil else { return }
        let blankSlate = BlankSlateView()
        blankSlate.representedObject = BlankSlateView.Mode.flashpointError(error)
        displayBlankSlate(blankSlate)
    }
    
    private func displayEmpty() {
        let blankSlate = BlankSlateView()
        blankSlate.representedObject = BlankSlateView.Mode.flashpointNotConfigured
        displayBlankSlate(blankSlate)
    }
    
    private func displayResults() {
        displayBlankSlate(nil)
    }
    
    private func displayBlankSlate(_ newBlankSlate: BlankSlateView?) {
        guard blankSlate != newBlankSlate else { return }
        
        let firstResponder = view.window?.firstResponder
        let makeFirstResponder = (firstResponder as? NSView)?.isDescendant(of: view) ?? false
        
        blankSlate?.removeFromSuperview()
        blankSlate = newBlankSlate
        
        if let blankSlate = blankSlate, let window = view.window {
            blankSlate.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
            blankSlate.autoresizingMask = [.height, .width]
            view.addSubview(blankSlate)
            
            scrollView.isHidden = true
        } else {
            tableView.reloadData()
            scrollView.isHidden = false
        }
        
        if makeFirstResponder {
            if blankSlate != nil {
                view.window?.makeFirstResponder(blankSlate)
            } else {
                view.window?.makeFirstResponder(tableView)
            }
        }
    }
    
    // MARK: - Actions
    
    @objc func addFlashGame(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["swf"]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.title = NSLocalizedString("Add Flash Games", comment: "Open panel title for adding Flash games")
        openPanel.prompt = NSLocalizedString("Add", comment: "Open panel button for adding Flash games")
        
        openPanel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, !openPanel.urls.isEmpty else { return }
            self?.importSWFFiles(openPanel.urls)
        }
    }
    
    private func importSWFFiles(_ urls: [URL]) {
        guard let database = database else { return }
        let context = database.mainThreadContext
        
        for url in urls {
            let gameName = url.deletingPathExtension().lastPathComponent
            
            // Check if already imported
            let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "Game")
            fetchRequest.predicate = NSPredicate(
                format: "name == %@ AND system.systemIdentifier == %@",
                gameName, "openemu.system.flash"
            )
            if let existing = try? context.fetch(fetchRequest), !existing.isEmpty {
                continue
            }
            
            // Copy to Flash ROMs directory
            let flashDir = database.romsFolderURL!.appendingPathComponent("Flash")
            try? FileManager.default.createDirectory(at: flashDir, withIntermediateDirectories: true)
            let destURL = flashDir.appendingPathComponent(url.lastPathComponent)
            
            if !FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.copyItem(at: url, to: destURL)
            }
            
            let romDescription = OEDBRom.entityDescription(in: context)
            let gameDescription = OEDBGame.entityDescription(in: context)
            
            let rom = OEDBRom(entity: romDescription, insertInto: context)
            rom.url = destURL
            rom.fileName = url.lastPathComponent
            
            let game = OEDBGame(entity: gameDescription, insertInto: context)
            game.roms = Set<OEDBRom>([rom])
            game.name = gameName
            game.system = OEDBSystem.system(for: "openemu.system.flash", in: context)
        }
        
        try? context.save()
        
        // Reload the local games section
        reloadLocalGames()
        
        // If blank slate was showing, switch to results
        if blankSlate != nil {
            displayResults()
        }
    }
    
    @objc private func tableViewDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredRows.count else { return }
        
        switch filteredRows[row] {
        case .sectionHeader:
            break
        case .localGame(let game):
            NSApp.sendAction(#selector(MainWindowController.startGame(_:)), to: nil, from: game)
        case .flashpointGame(let fpGame):
            importAndLaunch(flashpointGame: fpGame)
        }
    }
    
    private func importAndLaunch(flashpointGame: FlashpointGame) {
        guard let database = database else { return }
        let context = database.mainThreadContext
        
        // Check if already imported
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "Game")
        fetchRequest.predicate = NSPredicate(
            format: "name == %@ AND system.systemIdentifier == %@",
            flashpointGame.title, "openemu.system.flash"
        )
        
        if let existingGames = try? context.fetch(fetchRequest),
           let existingGame = existingGames.first as? OEDBGame {
            // Already imported, just launch
            NSApp.sendAction(#selector(MainWindowController.startGame(_:)), to: nil, from: existingGame)
            return
        }
        
        // Download the SWF from the launchCommand URL
        guard flashpointGame.launchCommand.hasPrefix("http"),
              let downloadURL = URL(string: flashpointGame.launchCommand) else {
            NSLog("[FlashpointViewController] Cannot download: launchCommand is not an HTTP URL: %@", flashpointGame.launchCommand)
            return
        }
        
        // Show a downloading indicator
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Downloading Flash Game", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Downloading \"%@\"...", comment: ""), flashpointGame.title)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .informational
        
        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.startAnimation(nil)
        progressIndicator.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        alert.accessoryView = progressIndicator
        
        let window = view.window!
        alert.beginSheetModal(for: window) { _ in }
        
        Task {
            do {
                let (tempFileURL, _) = try await URLSession.shared.download(from: downloadURL)
                
                // Determine filename from URL
                let filename = downloadURL.lastPathComponent.isEmpty ? "\(flashpointGame.id).swf" : downloadURL.lastPathComponent
                let sanitizedFilename = filename.hasSuffix(".swf") ? filename : "\(filename).swf"
                
                // Copy to Flash ROMs directory
                let flashDir = database.romsFolderURL!.appendingPathComponent("Flash")
                try? FileManager.default.createDirectory(at: flashDir, withIntermediateDirectories: true)
                let destURL = flashDir.appendingPathComponent(sanitizedFilename)
                
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try? FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempFileURL, to: destURL)
                
                // Create database entries
                await MainActor.run {
                    window.endSheet(window.attachedSheet!)
                    
                    let romDescription = OEDBRom.entityDescription(in: context)
                    let gameDescription = OEDBGame.entityDescription(in: context)
                    
                    let rom = OEDBRom(entity: romDescription, insertInto: context)
                    rom.url = destURL
                    rom.fileName = sanitizedFilename
                    
                    let game = OEDBGame(entity: gameDescription, insertInto: context)
                    game.roms = Set<OEDBRom>([rom])
                    game.name = flashpointGame.title
                    game.system = OEDBSystem.system(for: "openemu.system.flash", in: context)
                    game.save()
                    
                    // Refresh local games list
                    reloadLocalGames()
                    
                    // Launch the game
                    NSApp.sendAction(#selector(MainWindowController.startGame(_:)), to: nil, from: game)
                }
            } catch {
                await MainActor.run {
                    window.endSheet(window.attachedSheet!)
                    
                    let errorAlert = NSAlert()
                    errorAlert.messageText = NSLocalizedString("Download Failed", comment: "")
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.alertStyle = .warning
                    errorAlert.beginSheetModal(for: window)
                }
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension FlashpointViewController: NSTableViewDataSource {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredRows.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < filteredRows.count else { return nil }
        
        switch filteredRows[row] {
        case .sectionHeader(let title):
            if tableColumn?.identifier.rawValue == "title" {
                return title
            }
            return nil
        case .localGame(let game):
            switch tableColumn?.identifier.rawValue {
            case "title": return game.name ?? ""
            case "developer": return ""
            case "source": return "Local"
            case "year": return ""
            default: return nil
            }
        case .flashpointGame(let game):
            switch tableColumn?.identifier.rawValue {
            case "title": return game.title
            case "developer": return game.developer
            case "source": return "Flashpoint"
            case "year":
                let dateStr = game.releaseDate
                return dateStr.count >= 4 ? String(dateStr.prefix(4)) : dateStr
            default: return nil
            }
        }
    }
}

// MARK: - NSTableViewDelegate

extension FlashpointViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnIdentifier = tableColumn?.identifier else { return nil }
        guard row >= 0, row < filteredRows.count else { return nil }
        
        let rowItem = filteredRows[row]
        
        // Section header row
        if case .sectionHeader(let title) = rowItem {
            if columnIdentifier.rawValue == "title" {
                let headerID = NSUserInterfaceItemIdentifier("sectionHeader")
                var cellView = tableView.makeView(withIdentifier: headerID, owner: self) as? NSTableCellView
                
                if cellView == nil {
                    cellView = NSTableCellView()
                    let textField = NSTextField(labelWithString: "")
                    textField.translatesAutoresizingMaskIntoConstraints = false
                    textField.font = .boldSystemFont(ofSize: 13)
                    textField.textColor = .secondaryLabelColor
                    cellView?.addSubview(textField)
                    cellView?.textField = textField
                    cellView?.identifier = headerID
                    
                    NSLayoutConstraint.activate([
                        textField.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 4),
                        textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -2),
                        textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                    ])
                }
                
                cellView?.textField?.stringValue = title
                return cellView
            }
            // Return empty view for non-title columns on header rows
            let emptyID = NSUserInterfaceItemIdentifier("emptyCell")
            return tableView.makeView(withIdentifier: emptyID, owner: self) ?? NSTableCellView()
        }
        
        // Regular game row
        var cellView = tableView.makeView(withIdentifier: columnIdentifier, owner: self) as? NSTableCellView
        
        if cellView == nil {
            cellView = NSTableCellView()
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cellView?.addSubview(textField)
            cellView?.textField = textField
            cellView?.identifier = columnIdentifier
            
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
            ])
        }
        
        switch rowItem {
        case .localGame(let game):
            switch columnIdentifier.rawValue {
            case "title": cellView?.textField?.stringValue = game.name ?? ""
            case "developer": cellView?.textField?.stringValue = ""
            case "source": cellView?.textField?.stringValue = "Local"
            case "year": cellView?.textField?.stringValue = ""
            default: break
            }
        case .flashpointGame(let game):
            switch columnIdentifier.rawValue {
            case "title": cellView?.textField?.stringValue = game.title
            case "developer": cellView?.textField?.stringValue = game.developer
            case "source": cellView?.textField?.stringValue = "Flashpoint"
            case "year":
                let dateStr = game.releaseDate
                cellView?.textField?.stringValue = dateStr.count >= 4 ? String(dateStr.prefix(4)) : dateStr
            default: break
            }
        case .sectionHeader:
            break
        }
        
        return cellView
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < filteredRows.count else { return 24 }
        if case .sectionHeader = filteredRows[row] {
            return 32
        }
        return 24
    }
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < filteredRows.count else { return false }
        if case .sectionHeader = filteredRows[row] {
            return false
        }
        return true
    }
    
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row >= 0, row < filteredRows.count else { return false }
        if case .sectionHeader = filteredRows[row] {
            return true
        }
        return false
    }
}
