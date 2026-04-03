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

// MARK: - Service Item Model

private struct ServiceItem {
    let id: String
    let name: String
    let subtitle: String
    let iconName: String
    let cloudProviderType: OEStorageProviderType?
    var isSignedIn: Bool
}

// MARK: - PrefAccountsController

final class PrefAccountsController: NSViewController {

    // Key constants
    private static let evictionDaysKey = "OECloudEvictionDays"

    // Views
    private var listContainer: NSView!
    private var detailContainer: NSView!
    private var contentStack: NSStackView!
    private var scrollView: NSScrollView!

    // Currently displayed detail service (nil = list view)
    private var activeDetailService: ServiceItem?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 560))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        showListView()

        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudStatusDidChange),
            name: OECloudStorageManager.statusDidChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func buildLayout() {
        // List container (service list)
        listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(listContainer)

        // Detail container (account detail view)
        detailContainer = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.isHidden = true
        view.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            listContainer.topAnchor.constraint(equalTo: view.topAnchor),
            listContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            detailContainer.topAnchor.constraint(equalTo: view.topAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildListView()
    }

    private func buildListView() {
        let titleLabel = NSTextField(labelWithString: NSLocalizedString("Accounts", comment: ""))
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(titleLabel)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        listContainer.addSubview(scrollView)

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let flipView = FlippedView()
        flipView.translatesAutoresizingMaskIntoConstraints = false
        flipView.addSubview(contentStack)
        scrollView.documentView = flipView

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

            flipView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            flipView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            flipView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            flipView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: flipView.topAnchor, constant: 4),
            contentStack.leadingAnchor.constraint(equalTo: flipView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: flipView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: flipView.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Navigation

    private func showListView() {
        activeDetailService = nil
        detailContainer.isHidden = true
        listContainer.isHidden = false
        refreshSections()
    }

    private func showDetailView(for service: ServiceItem) {
        activeDetailService = service
        listContainer.isHidden = true
        detailContainer.isHidden = false
        detailContainer.subviews.forEach { $0.removeFromSuperview() }

        if service.cloudProviderType != nil {
            buildCloudDetailView(service: service)
        } else if service.id == "retroachievements" {
            buildRetroAchievementsDetailView(service: service)
        } else if service.id == "screenscraper" {
            buildScreenScraperDetailView(service: service)
        }
    }

    // MARK: - Data

    private func allServices() -> [ServiceItem] {
        let cm = OECloudStorageManager.shared
        return [
            ServiceItem(id: "icloud", name: NSLocalizedString("iCloud", comment: ""),
                        subtitle: NSLocalizedString("Cloud Storage", comment: ""),
                        iconName: "icloud", cloudProviderType: .iCloud,
                        isSignedIn: cm.provider(for: .iCloud)?.isAuthenticated ?? false),
            ServiceItem(id: "screenscraper", name: NSLocalizedString("Screen Scraper.fr", comment: ""),
                        subtitle: NSLocalizedString("Game Image & Meta Data", comment: ""),
                        iconName: "photo.artframe", cloudProviderType: nil,
                        isSignedIn: ScreenScraperCredentialStore.shared.hasCredentials),
            ServiceItem(id: "googledrive", name: NSLocalizedString("Google Drive", comment: ""),
                        subtitle: NSLocalizedString("Cloud Storage", comment: ""),
                        iconName: "externaldrive.badge.icloud", cloudProviderType: .googleDrive,
                        isSignedIn: cm.provider(for: .googleDrive)?.isAuthenticated ?? false),
            ServiceItem(id: "retroachievements", name: NSLocalizedString("Retro Achievements", comment: ""),
                        subtitle: NSLocalizedString("Retroachievements & Trophies", comment: ""),
                        iconName: "trophy", cloudProviderType: nil,
                        isSignedIn: RetroAchievementsCredentialStore.shared.isLoggedIn),
            ServiceItem(id: "dropbox", name: NSLocalizedString("Drop Box", comment: ""),
                        subtitle: NSLocalizedString("Cloud Storage", comment: ""),
                        iconName: "externaldrive.badge.icloud", cloudProviderType: .dropbox,
                        isSignedIn: cm.provider(for: .dropbox)?.isAuthenticated ?? false),
            ServiceItem(id: "webdav", name: NSLocalizedString("WebDAV / NAS", comment: ""),
                        subtitle: NSLocalizedString("Network Storage", comment: ""),
                        iconName: "server.rack", cloudProviderType: .webDAV,
                        isSignedIn: cm.provider(for: .webDAV)?.isAuthenticated ?? false),
        ]
    }

    private func refreshSections() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let services = allServices()
        let signedIn = services.filter { $0.isSignedIn }
        let available = services.filter { !$0.isSignedIn }

        if !signedIn.isEmpty {
            let section = buildSection(title: NSLocalizedString("Accounts", comment: ""), services: signedIn)
            contentStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        if !available.isEmpty {
            let section = buildSection(title: NSLocalizedString("Available Services", comment: ""), services: available)
            contentStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    @objc private func cloudStatusDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.activeDetailService != nil {
                // Refresh the detail view if currently showing one
                if let svc = self.activeDetailService, let updated = self.allServices().first(where: { $0.id == svc.id }) {
                    self.showDetailView(for: updated)
                }
            } else {
                self.refreshSections()
            }
        }
    }

    // MARK: - Section Building

    private func buildSection(title: String, services: [ServiceItem]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let headerLabel = NSTextField(labelWithString: title)
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.textColor = .labelColor
        container.addArrangedSubview(headerLabel)

        let box = RoundedGroupBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: box.topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])

        for (index, service) in services.enumerated() {
            let row = ServiceRowView(service: service) { [weak self] svc in
                self?.handleRowClick(svc)
            }
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true

            if index < services.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                rowStack.addArrangedSubview(sep)
                sep.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor, constant: 56).isActive = true
                sep.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor).isActive = true
            }
        }
        return container
    }

    // MARK: - Row Click Handling

    private func handleRowClick(_ service: ServiceItem) {
        if service.isSignedIn {
            // Show detail view for signed-in accounts
            showDetailView(for: service)
        } else if service.cloudProviderType != nil {
            // Show sign-in popover for cloud services
            showCloudSignInSheet(for: service)
        } else if service.id == "retroachievements" {
            showRetroAchievementsSignInSheet()
        } else if service.id == "screenscraper" {
            showScreenScraperSheet()
        }
    }

    // MARK: - Cloud Sign-In Sheet

    private func showCloudSignInSheet(for service: ServiceItem) {
        guard let providerType = service.cloudProviderType else { return }

        if providerType == .webDAV {
            showWebDAVSignInSheet()
        } else {
            showOAuthSignInSheet(for: service, providerType: providerType)
        }
    }

    private func showOAuthSignInSheet(for service: ServiceItem, providerType: OEStorageProviderType) {
        let sheetVC = NSViewController()
        sheetVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 200))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheetVC.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sheetVC.view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: sheetVC.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sheetVC.view.trailingAnchor, constant: -20),
        ])

        let header = NSTextField(labelWithString: service.name)
        header.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(header)

        let desc = NSTextField(wrappingLabelWithString: String(format: NSLocalizedString("%@ requires completing authentication in your web browser.", comment: ""), service.name))
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(desc)

        let subtitle = NSTextField(wrappingLabelWithString: NSLocalizedString("After authentication, setup will continue in Internet Accounts.", comment: ""))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(16, after: subtitle)

        let openBrowserBtn = NSButton(title: NSLocalizedString("Open Browser", comment: ""), target: self, action: #selector(cloudSheetOpenBrowser(_:)))
        openBrowserBtn.bezelStyle = .rounded
        openBrowserBtn.controlSize = .large
        openBrowserBtn.keyEquivalent = "\r"
        openBrowserBtn.tag = OEStorageProviderType.allCases.firstIndex(of: providerType) ?? 0
        openBrowserBtn.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(openBrowserBtn)
        openBrowserBtn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let cancelBtn = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(dismissSheet(_:)))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.controlSize = .large
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(cancelBtn)
        cancelBtn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        sheetVC.preferredContentSize = NSSize(width: 280, height: 210)
        view.window?.beginSheet(makeSheetWindow(for: sheetVC))
    }

    private func showWebDAVSignInSheet() {
        let sheetVC = NSViewController()
        sheetVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheetVC.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sheetVC.view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: sheetVC.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sheetVC.view.trailingAnchor, constant: -20),
        ])

        let header = NSTextField(labelWithString: NSLocalizedString("WebDAV / NAS", comment: ""))
        header.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(header)

        let desc = NSTextField(wrappingLabelWithString: NSLocalizedString("Connect to a WebDAV server or NAS for cloud storage.", comment: ""))
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(desc)

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10

        let urlLabel = NSTextField(labelWithString: NSLocalizedString("Server URL:", comment: ""))
        urlLabel.alignment = .right
        let urlField = NSTextField()
        urlField.placeholderString = "https://nas.local/webdav"
        urlField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        urlField.identifier = NSUserInterfaceItemIdentifier("webdavURL")
        grid.addRow(with: [urlLabel, urlField])

        let userLabel = NSTextField(labelWithString: NSLocalizedString("Username:", comment: ""))
        userLabel.alignment = .right
        let userField = NSTextField()
        userField.placeholderString = NSLocalizedString("Username", comment: "")
        userField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        userField.identifier = NSUserInterfaceItemIdentifier("webdavUser")
        grid.addRow(with: [userLabel, userField])

        let passLabel = NSTextField(labelWithString: NSLocalizedString("Password:", comment: ""))
        passLabel.alignment = .right
        let passField = NSSecureTextField()
        passField.placeholderString = NSLocalizedString("Password", comment: "")
        passField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        passField.identifier = NSUserInterfaceItemIdentifier("webdavPass")
        grid.addRow(with: [passLabel, passField])

        // Load existing values
        let defaults = UserDefaults.standard
        urlField.stringValue = defaults.string(forKey: "OECloudWebDAVURL") ?? ""
        userField.stringValue = defaults.string(forKey: "OECloudWebDAVUsername") ?? ""

        stack.addArrangedSubview(grid)
        stack.setCustomSpacing(16, after: grid)

        let connectBtn = NSButton(title: NSLocalizedString("Save & Connect", comment: ""), target: self, action: #selector(webdavSheetConnect(_:)))
        connectBtn.bezelStyle = .rounded
        connectBtn.controlSize = .large
        connectBtn.keyEquivalent = "\r"
        connectBtn.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(connectBtn)
        connectBtn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let cancelBtn = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(dismissSheet(_:)))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.controlSize = .large
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(cancelBtn)
        cancelBtn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        sheetVC.preferredContentSize = NSSize(width: 360, height: 280)
        view.window?.beginSheet(makeSheetWindow(for: sheetVC))
    }

    @objc private func cloudSheetOpenBrowser(_ sender: NSButton) {
        let providerType = OEStorageProviderType.allCases[sender.tag]
        guard let provider = OECloudStorageManager.shared.provider(for: providerType) else { return }

        if let sheetWindow = sender.window {
            view.window?.endSheet(sheetWindow)
        }

        Task {
            do {
                try await provider.authenticate()
                // Pull cloud library metadata from newly connected provider
                try? await OECloudStorageManager.shared.pullCloudLibrary()
                await MainActor.run { self.refreshSections() }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Sign In Failed", comment: "")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModal()
                    self.refreshSections()
                }
            }
        }
    }

    @objc private func webdavSheetConnect(_ sender: NSButton) {
        guard let win = sender.window,
              let urlField = win.contentView?.findView(withIdentifier: "webdavURL") as? NSTextField,
              let userField = win.contentView?.findView(withIdentifier: "webdavUser") as? NSTextField,
              let passField = win.contentView?.findView(withIdentifier: "webdavPass") as? NSSecureTextField
        else { return }

        let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let pass = passField.stringValue

        guard !url.isEmpty else { return }

        UserDefaults.standard.set(url, forKey: "OECloudWebDAVURL")
        UserDefaults.standard.set(user, forKey: "OECloudWebDAVUsername")
        if !pass.isEmpty {
            UserDefaults.standard.set(pass, forKey: "OECloudWebDAVPassword")
        }

        view.window?.endSheet(win)

        Task {
            do {
                guard let provider = OECloudStorageManager.shared.provider(for: .webDAV) else { return }
                try await provider.authenticate()
                // Pull cloud library metadata from newly connected provider
                try? await OECloudStorageManager.shared.pullCloudLibrary()
                await MainActor.run { self.refreshSections() }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Connection Failed", comment: "")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Cloud Account Detail View

    private func buildCloudDetailView(service: ServiceItem) {
        guard let providerType = service.cloudProviderType else { return }
        let cm = OECloudStorageManager.shared

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        detailContainer.addSubview(scroll)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        let flip = FlippedView()
        flip.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(stack)
        scroll.documentView = flip

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),

            flip.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flip.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            flip.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            flip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: flip.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: flip.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: flip.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: flip.bottomAnchor, constant: -20),
        ])

        // Back button
        let backBtn = NSButton(title: NSLocalizedString("\u{2190} Accounts", comment: ""), target: self, action: #selector(backToList(_:)))
        backBtn.bezelStyle = .accessoryBarAction
        backBtn.isBordered = false
        backBtn.font = .systemFont(ofSize: 13)
        backBtn.contentTintColor = .controlAccentColor
        stack.addArrangedSubview(backBtn)

        // ── Account Header ──────────────────────────────────────
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: service.iconName, accessibilityDescription: service.name) {
            icon.image = img
        }
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        headerRow.addArrangedSubview(icon)

        let nameStack = NSStackView()
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 2
        let nameLabel = NSTextField(labelWithString: service.name)
        nameLabel.font = .boldSystemFont(ofSize: 15)
        nameStack.addArrangedSubview(nameLabel)
        let subtitleLabel = NSTextField(labelWithString: service.subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        nameStack.addArrangedSubview(subtitleLabel)
        headerRow.addArrangedSubview(nameStack)

        // Spacer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(spacer)

        let signOutBtn = NSButton(title: NSLocalizedString("Sign Out", comment: ""), target: self, action: #selector(cloudDetailSignOut(_:)))
        signOutBtn.bezelStyle = .rounded
        signOutBtn.tag = OEStorageProviderType.allCases.firstIndex(of: providerType) ?? 0
        headerRow.addArrangedSubview(signOutBtn)

        let syncNowBtn = NSButton(title: NSLocalizedString("Sync Now", comment: ""), target: self, action: #selector(cloudDetailSyncNow(_:)))
        syncNowBtn.bezelStyle = .rounded
        syncNowBtn.tag = OEStorageProviderType.allCases.firstIndex(of: providerType) ?? 0
        headerRow.addArrangedSubview(syncNowBtn)

        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ── Sync Options ────────────────────────────────────────
        let syncHeader = NSTextField(labelWithString: NSLocalizedString("Sync Options", comment: ""))
        syncHeader.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(syncHeader)

        let syncBox = RoundedGroupBox()
        syncBox.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(syncBox)
        syncBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let syncRows = NSStackView()
        syncRows.orientation = .vertical
        syncRows.alignment = .leading
        syncRows.spacing = 0
        syncRows.translatesAutoresizingMaskIntoConstraints = false
        syncBox.addSubview(syncRows)

        NSLayoutConstraint.activate([
            syncRows.topAnchor.constraint(equalTo: syncBox.topAnchor),
            syncRows.leadingAnchor.constraint(equalTo: syncBox.leadingAnchor),
            syncRows.trailingAnchor.constraint(equalTo: syncBox.trailingAnchor),
            syncRows.bottomAnchor.constraint(equalTo: syncBox.bottomAnchor),
        ])

        let scope = cm.syncScope
        let isActiveProvider = cm.libraryProviderType == providerType

        let savesRow = makeSyncToggleRow(
            iconName: "doc", title: NSLocalizedString("Saves", comment: ""),
            isOn: isActiveProvider && scope.contains(.saves), tag: 0, providerTag: providerType)
        syncRows.addArrangedSubview(savesRow)
        savesRow.widthAnchor.constraint(equalTo: syncRows.widthAnchor).isActive = true

        let sep1 = makeSeparator()
        syncRows.addArrangedSubview(sep1)
        sep1.leadingAnchor.constraint(equalTo: syncRows.leadingAnchor, constant: 56).isActive = true
        sep1.trailingAnchor.constraint(equalTo: syncRows.trailingAnchor).isActive = true

        let gamesRow = makeSyncToggleRow(
            iconName: "gamecontroller", title: NSLocalizedString("Games", comment: ""),
            isOn: isActiveProvider && scope.contains(.library), tag: 1, providerTag: providerType)
        syncRows.addArrangedSubview(gamesRow)
        gamesRow.widthAnchor.constraint(equalTo: syncRows.widthAnchor).isActive = true

        let sep2 = makeSeparator()
        syncRows.addArrangedSubview(sep2)
        sep2.leadingAnchor.constraint(equalTo: syncRows.leadingAnchor, constant: 56).isActive = true
        sep2.trailingAnchor.constraint(equalTo: syncRows.trailingAnchor).isActive = true

        let screenshotsRow = makeSyncToggleRow(
            iconName: "photo", title: NSLocalizedString("Screenshots", comment: ""),
            isOn: isActiveProvider && scope.contains(.screenshots), tag: 2, providerTag: providerType)
        syncRows.addArrangedSubview(screenshotsRow)
        screenshotsRow.widthAnchor.constraint(equalTo: syncRows.widthAnchor).isActive = true

        // ── Storage Management ──────────────────────────────────
        let storageHeader = NSTextField(labelWithString: NSLocalizedString("Storage Management", comment: ""))
        storageHeader.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(storageHeader)

        let storageBox = RoundedGroupBox()
        storageBox.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(storageBox)
        storageBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let storageRows = NSStackView()
        storageRows.orientation = .vertical
        storageRows.alignment = .leading
        storageRows.spacing = 0
        storageRows.translatesAutoresizingMaskIntoConstraints = false
        storageBox.addSubview(storageRows)

        NSLayoutConstraint.activate([
            storageRows.topAnchor.constraint(equalTo: storageBox.topAnchor),
            storageRows.leadingAnchor.constraint(equalTo: storageBox.leadingAnchor),
            storageRows.trailingAnchor.constraint(equalTo: storageBox.trailingAnchor),
            storageRows.bottomAnchor.constraint(equalTo: storageBox.bottomAnchor),
        ])

        let evictionDays = UserDefaults.standard.integer(forKey: Self.evictionDaysKey)
        let days = evictionDays > 0 ? evictionDays : 30
        let offloadRow = makeSyncToggleRow(
            iconName: "clock.arrow.circlepath",
            title: String(format: NSLocalizedString("Offload Games After %d Days", comment: ""), days),
            isOn: evictionDays > 0, tag: 10, providerTag: providerType)
        storageRows.addArrangedSubview(offloadRow)
        offloadRow.widthAnchor.constraint(equalTo: storageRows.widthAnchor).isActive = true

        // ── Download All / Offload All ──────────────────────────
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let downloadAllBtn = NSButton(title: NSLocalizedString("Download All", comment: ""), target: self, action: #selector(detailDownloadAll(_:)))
        downloadAllBtn.bezelStyle = .rounded
        buttonRow.addArrangedSubview(downloadAllBtn)

        let offloadAllBtn = NSButton(title: NSLocalizedString("Offload All", comment: ""), target: self, action: #selector(detailOffloadAll(_:)))
        offloadAllBtn.bezelStyle = .rounded
        buttonRow.addArrangedSubview(offloadAllBtn)

        stack.addArrangedSubview(buttonRow)
    }

    private func makeSyncToggleRow(iconName: String, title: String, isOn: Bool, tag: Int, providerTag: OEStorageProviderType) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: title)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.target = self
        toggle.action = #selector(syncToggleChanged(_:))
        // Encode both toggle type (tag) and provider type (via identifier)
        toggle.tag = tag
        toggle.identifier = NSUserInterfaceItemIdentifier(providerTag.rawValue)
        row.addSubview(toggle)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    private func makeSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        return sep
    }

    // MARK: - Sync Toggle Actions

    @objc private func syncToggleChanged(_ sender: NSSwitch) {
        guard let providerRaw = sender.identifier?.rawValue,
              let providerType = OEStorageProviderType(rawValue: providerRaw) else { return }

        let cm = OECloudStorageManager.shared
        let tag = sender.tag

        // Tag 10 = offload toggle (not a sync scope toggle)
        if tag == 10 {
            if sender.state == .on {
                UserDefaults.standard.set(30, forKey: Self.evictionDaysKey)
            } else {
                UserDefaults.standard.set(0, forKey: Self.evictionDaysKey)
            }
            return
        }

        let isEnabling = sender.state == .on

        // If enabling sync and this provider is not the active provider, warn about switching
        if isEnabling && cm.libraryProviderType != providerType && cm.libraryProviderType != .local {
            let currentName = cm.libraryProviderType.displayName
            let newName = providerType.displayName

            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("Switch sync to %@?", comment: ""), newName)
            alert.informativeText = String(format: NSLocalizedString("Enabling sync on %@ will disable sync on %@. Your files on %@ will remain there but will no longer sync automatically.", comment: ""), newName, currentName, currentName)
            alert.addButton(withTitle: String(format: NSLocalizedString("Switch to %@", comment: ""), newName))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.alertStyle = .warning

            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                sender.state = .off
                return
            }

            // Switch provider
            cm.setProvider(providerType)
        } else if isEnabling && cm.libraryProviderType == .local {
            // Switching from local to this provider
            cm.setProvider(providerType)
        }

        // Update sync scope
        var scope = cm.syncScope
        let scopeFlag: OESyncScope
        switch tag {
        case 0: scopeFlag = .saves
        case 1: scopeFlag = .library
        case 2: scopeFlag = .screenshots
        default: return
        }

        if isEnabling {
            scope.insert(scopeFlag)
        } else {
            scope.remove(scopeFlag)
        }
        cm.syncScope = scope

        // If all sync options are off, revert to local
        if scope.isEmpty {
            cm.setProvider(.local)
        }
    }

    // MARK: - Cloud Detail Actions

    @objc private func backToList(_ sender: Any?) {
        showListView()
    }

    @objc private func cloudDetailSignOut(_ sender: NSButton) {
        let providerType = OEStorageProviderType.allCases[sender.tag]
        let name = providerType.displayName

        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Sign out of %@?", comment: ""), name)
        alert.informativeText = String(format: NSLocalizedString("Your files on %@ will remain there but will no longer sync.", comment: ""), name)
        alert.addButton(withTitle: NSLocalizedString("Sign Out", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cm = OECloudStorageManager.shared
        if cm.libraryProviderType == providerType {
            cm.setProvider(.local)
        }

        Task {
            await cm.provider(for: providerType)?.signOut()
            await MainActor.run { self.showListView() }
        }
    }

    @objc private func cloudDetailSyncNow(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = NSLocalizedString("Syncing\u{2026}", comment: "")
        let cm = OECloudStorageManager.shared

        Task {
            do {
                try await cm.authenticate()
                try await cm.pullCloudLibrary()     // Pull first (new games from other machines)
                try await cm.syncExistingLibrary()  // Push second (upload local games)
            } catch { }
            await MainActor.run {
                sender.isEnabled = true
                sender.title = NSLocalizedString("Sync Now", comment: "")
            }
        }
    }

    @objc private func detailDownloadAll(_ sender: NSButton) {
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("Download all games from the cloud?", comment: "")
        alert.informativeText = NSLocalizedString("This will download all cloud-backed games to your Mac. This may take a while depending on your library size and internet speed.", comment: "")
        alert.defaultButtonTitle = NSLocalizedString("Download All", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        sender.isEnabled = false
        sender.title = NSLocalizedString("Downloading\u{2026}", comment: "")

        Task {
            let result = await OECloudStorageManager.shared.downloadEntireLibrary { completed, total, _ in
                DispatchQueue.main.async {
                    sender.title = String(format: NSLocalizedString("Downloading %d of %d\u{2026}", comment: ""), completed, total)
                }
            }
            await MainActor.run {
                sender.isEnabled = true
                sender.title = NSLocalizedString("Download All", comment: "")
                let done = OEAlert()
                done.messageText = result.failed > 0
                    ? String(format: NSLocalizedString("Downloaded %d games. %d failed.", comment: ""), result.downloaded, result.failed)
                    : String(format: NSLocalizedString("Downloaded %d games.", comment: ""), result.downloaded)
                done.defaultButtonTitle = NSLocalizedString("OK", comment: "")
                done.runModal()
            }
        }
    }

    @objc private func detailOffloadAll(_ sender: NSButton) {
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("Offload all uploaded games?", comment: "")
        alert.informativeText = NSLocalizedString("This will remove local copies of all games that have been uploaded to the cloud. You can re-download them anytime.", comment: "")
        alert.defaultButtonTitle = NSLocalizedString("Offload All", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let database = OELibraryDatabase.default else { return }
        let context = database.mainThreadContext

        sender.isEnabled = false
        sender.title = NSLocalizedString("Offloading\u{2026}", comment: "")

        Task {
            var offloadedCount = 0
            let roms: [OEDBRom] = context.performAndWait {
                let req = OEDBRom.fetchRequest()
                req.predicate = NSPredicate(format: "cloudIdentifier != nil")
                return (try? context.fetch(req) as? [OEDBRom]) ?? []
            }
            for rom in roms {
                guard let url = rom.url, (try? url.checkResourceIsReachable()) == true else { continue }
                do {
                    try await OECloudStorageManager.shared.evictROM(localURL: url)
                    await MainActor.run { rom.setDownloaded(false) }
                    offloadedCount += 1
                } catch { }
            }
            await MainActor.run {
                sender.isEnabled = true
                sender.title = NSLocalizedString("Offload All", comment: "")
                let done = OEAlert()
                done.messageText = String(format: NSLocalizedString("Offloaded %d games.", comment: ""), offloadedCount)
                done.defaultButtonTitle = NSLocalizedString("OK", comment: "")
                done.runModal()
            }
        }
    }

    // MARK: - RetroAchievements Detail View

    private func buildRetroAchievementsDetailView(service: ServiceItem) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
        ])

        let backBtn = NSButton(title: NSLocalizedString("\u{2190} Accounts", comment: ""), target: self, action: #selector(backToList(_:)))
        backBtn.bezelStyle = .accessoryBarAction
        backBtn.isBordered = false
        backBtn.font = .systemFont(ofSize: 13)
        backBtn.contentTintColor = .controlAccentColor
        stack.addArrangedSubview(backBtn)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "trophy", accessibilityDescription: "RetroAchievements")
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        headerRow.addArrangedSubview(icon)

        let username = RetroAchievementsCredentialStore.shared.username ?? ""
        let nameLabel = NSTextField(labelWithString: username)
        nameLabel.font = .boldSystemFont(ofSize: 15)
        headerRow.addArrangedSubview(nameLabel)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(headerSpacer)

        let signOutBtn = NSButton(title: NSLocalizedString("Sign Out", comment: ""), target: self, action: #selector(raDetailSignOut(_:)))
        signOutBtn.bezelStyle = .rounded
        headerRow.addArrangedSubview(signOutBtn)

        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let desc = NSTextField(wrappingLabelWithString: NSLocalizedString("Track achievements while playing retro games. Achievements are automatically synced when you play.", comment: ""))
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(desc)
    }

    @objc private func raDetailSignOut(_ sender: NSButton) {
        RetroAchievementsCredentialStore.shared.clear()
        showListView()
    }

    // MARK: - ScreenScraper Detail View

    private func buildScreenScraperDetailView(service: ServiceItem) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
        ])

        let backBtn = NSButton(title: NSLocalizedString("\u{2190} Accounts", comment: ""), target: self, action: #selector(backToList(_:)))
        backBtn.bezelStyle = .accessoryBarAction
        backBtn.isBordered = false
        backBtn.font = .systemFont(ofSize: 13)
        backBtn.contentTintColor = .controlAccentColor
        stack.addArrangedSubview(backBtn)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "photo.artframe", accessibilityDescription: "ScreenScraper")
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        headerRow.addArrangedSubview(icon)

        let nameLabel = NSTextField(labelWithString: ScreenScraperCredentialStore.shared.username ?? "Screen Scraper.fr")
        nameLabel.font = .boldSystemFont(ofSize: 15)
        headerRow.addArrangedSubview(nameLabel)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(headerSpacer)

        let clearBtn = NSButton(title: NSLocalizedString("Sign Out", comment: ""), target: self, action: #selector(ssDetailClear(_:)))
        clearBtn.bezelStyle = .rounded
        headerRow.addArrangedSubview(clearBtn)

        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let enableCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Enable ScreenScraper artwork fallback", comment: ""), target: self, action: #selector(ssDetailEnableChanged(_:)))
        enableCheckbox.state = UserDefaults.standard.bool(forKey: GameInfoHelper.useScreenScraperKey) ? .on : .off
        stack.addArrangedSubview(enableCheckbox)

        let desc = NSTextField(wrappingLabelWithString: NSLocalizedString("ScreenScraper.fr provides box art and descriptions for games not found in the local database.", comment: ""))
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(desc)
    }

    @objc private func ssDetailClear(_ sender: NSButton) {
        ScreenScraperCredentialStore.shared.clear()
        UserDefaults.standard.set(false, forKey: GameInfoHelper.useScreenScraperKey)
        showListView()
    }

    @objc private func ssDetailEnableChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: GameInfoHelper.useScreenScraperKey)
    }

    // MARK: - RetroAchievements Sign-In Sheet

    private func showRetroAchievementsSignInSheet() {
        let sheetVC = NSViewController()
        sheetVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheetVC.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sheetVC.view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: sheetVC.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sheetVC.view.trailingAnchor, constant: -20),
        ])

        let header = NSTextField(labelWithString: NSLocalizedString("Retro Achievements", comment: ""))
        header.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(header)

        let desc = NSTextField(wrappingLabelWithString: NSLocalizedString("Sign in with your RetroAchievements account to track achievements while playing games.", comment: ""))
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(desc)

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10

        let usernameLabel = NSTextField(labelWithString: NSLocalizedString("Username:", comment: ""))
        usernameLabel.alignment = .right
        let usernameField = NSTextField()
        usernameField.placeholderString = NSLocalizedString("RetroAchievements username", comment: "")
        usernameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        usernameField.identifier = NSUserInterfaceItemIdentifier("raUsername")
        grid.addRow(with: [usernameLabel, usernameField])

        let passwordLabel = NSTextField(labelWithString: NSLocalizedString("Password:", comment: ""))
        passwordLabel.alignment = .right
        let passwordField = NSSecureTextField()
        passwordField.placeholderString = NSLocalizedString("Password", comment: "")
        passwordField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        passwordField.identifier = NSUserInterfaceItemIdentifier("raPassword")
        grid.addRow(with: [passwordLabel, passwordField])
        stack.addArrangedSubview(grid)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true
        statusLabel.identifier = NSUserInterfaceItemIdentifier("raStatus")
        stack.addArrangedSubview(statusLabel)
        stack.setCustomSpacing(16, after: statusLabel)

        let signInBtn = NSButton(title: NSLocalizedString("Sign In", comment: ""), target: self, action: #selector(raSheetSignIn(_:)))
        signInBtn.bezelStyle = .rounded
        signInBtn.controlSize = .large
        signInBtn.keyEquivalent = "\r"
        signInBtn.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(signInBtn)
        signInBtn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let closeBtn = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(dismissSheet(_:)))
        closeBtn.bezelStyle = .rounded
        closeBtn.controlSize = .large
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(closeBtn)
        closeBtn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        sheetVC.preferredContentSize = NSSize(width: 360, height: 280)
        view.window?.beginSheet(makeSheetWindow(for: sheetVC))
    }

    @objc private func raSheetSignIn(_ sender: NSButton) {
        guard let win = sender.window,
              let usernameField = win.contentView?.findView(withIdentifier: "raUsername") as? NSTextField,
              let passwordField = win.contentView?.findView(withIdentifier: "raPassword") as? NSSecureTextField,
              let statusLabel = win.contentView?.findView(withIdentifier: "raStatus") as? NSTextField
        else { return }

        let username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        guard !username.isEmpty, !password.isEmpty else {
            statusLabel.stringValue = NSLocalizedString("Please enter your username and password.", comment: "")
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
            return
        }

        sender.isEnabled = false
        statusLabel.isHidden = true

        performRetroAchievementsLogin(username: username, password: password) { [weak self] success, errorMessage in
            DispatchQueue.main.async {
                sender.isEnabled = true
                if success {
                    self?.view.window?.endSheet(win)
                    self?.refreshSections()
                } else {
                    statusLabel.stringValue = errorMessage ?? NSLocalizedString("Login failed.", comment: "")
                    statusLabel.textColor = .systemRed
                    statusLabel.isHidden = false
                }
            }
        }
    }

    // MARK: - ScreenScraper Sign-In Sheet

    private func showScreenScraperSheet() {
        let sheetVC = NSViewController()
        sheetVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheetVC.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sheetVC.view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: sheetVC.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sheetVC.view.trailingAnchor, constant: -20),
        ])

        let header = NSTextField(labelWithString: NSLocalizedString("Screen Scraper.fr", comment: ""))
        header.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(header)

        let desc = NSTextField(wrappingLabelWithString: NSLocalizedString("ScreenScraper.fr provides box art and descriptions for games not found in the local database. Sign in for higher rate limits.", comment: ""))
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(desc)

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10

        let usernameLabel = NSTextField(labelWithString: NSLocalizedString("Username:", comment: ""))
        usernameLabel.alignment = .right
        let usernameField = NSTextField()
        usernameField.placeholderString = NSLocalizedString("ScreenScraper username", comment: "")
        usernameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        usernameField.identifier = NSUserInterfaceItemIdentifier("ssUsername")
        grid.addRow(with: [usernameLabel, usernameField])

        let passwordLabel = NSTextField(labelWithString: NSLocalizedString("Password:", comment: ""))
        passwordLabel.alignment = .right
        let passwordField = NSSecureTextField()
        passwordField.placeholderString = NSLocalizedString("Password", comment: "")
        passwordField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        passwordField.identifier = NSUserInterfaceItemIdentifier("ssPassword")
        grid.addRow(with: [passwordLabel, passwordField])
        stack.addArrangedSubview(grid)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.isHidden = true
        statusLabel.identifier = NSUserInterfaceItemIdentifier("ssStatus")
        stack.addArrangedSubview(statusLabel)
        stack.setCustomSpacing(16, after: statusLabel)

        let saveBtn = NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(ssSheetSave(_:)))
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .large
        saveBtn.keyEquivalent = "\r"
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(saveBtn)
        saveBtn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let closeBtn = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(dismissSheet(_:)))
        closeBtn.bezelStyle = .rounded
        closeBtn.controlSize = .large
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(closeBtn)
        closeBtn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        sheetVC.preferredContentSize = NSSize(width: 360, height: 320)
        view.window?.beginSheet(makeSheetWindow(for: sheetVC))
    }

    @objc private func ssSheetSave(_ sender: NSButton) {
        guard let win = sender.window,
              let usernameField = win.contentView?.findView(withIdentifier: "ssUsername") as? NSTextField,
              let passwordField = win.contentView?.findView(withIdentifier: "ssPassword") as? NSSecureTextField,
              let statusLabel = win.contentView?.findView(withIdentifier: "ssStatus") as? NSTextField
        else { return }

        let username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        guard !username.isEmpty, !password.isEmpty else {
            statusLabel.stringValue = NSLocalizedString("Please enter username and password.", comment: "")
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
            return
        }

        ScreenScraperCredentialStore.shared.save(username: username, password: password)
        UserDefaults.standard.set(true, forKey: GameInfoHelper.useScreenScraperKey)
        view.window?.endSheet(win)
        refreshSections()
    }

    // MARK: - RetroAchievements Login API

    private func performRetroAchievementsLogin(username: String, password: String, completion: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: "https://retroachievements.org/dorequest.php") else {
            completion(false, NSLocalizedString("Invalid URL.", comment: ""))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "r", value: "login"),
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "p", value: password),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { completion(false, error.localizedDescription); return }
            guard let data else { completion(false, NSLocalizedString("No response.", comment: "")); return }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(false, NSLocalizedString("Unexpected response.", comment: "")); return
                }
                guard json["Success"] as? Bool == true,
                      let token = json["Token"] as? String, !token.isEmpty else {
                    completion(false, json["Error"] as? String ?? NSLocalizedString("Login failed.", comment: ""))
                    return
                }
                let correctedUsername = json["User"] as? String ?? username
                RetroAchievementsCredentialStore.shared.save(username: correctedUsername, token: token)
                completion(true, nil)
            } catch {
                completion(false, NSLocalizedString("Failed to parse response.", comment: ""))
            }
        }.resume()
    }

    // MARK: - Sheet Helpers

    @objc private func dismissSheet(_ sender: NSButton) {
        guard let sheetWindow = sender.window else { return }
        view.window?.endSheet(sheetWindow)
    }

    private func makeSheetWindow(for vc: NSViewController) -> NSWindow {
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: vc.preferredContentSize),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = vc
        window.isReleasedWhenClosed = false
        return window
    }
}

// MARK: - PreferencePane

extension PrefAccountsController: PreferencePane {
    var icon: NSImage? { NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Accounts") }
    var panelTitle: String { "Accounts" }
    var viewSize: NSSize { NSSize(width: 468, height: 560) }
}

// MARK: - Rounded Group Box

private class RoundedGroupBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        let bgColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(white: 1.0, alpha: 0.06)
            } else {
                return NSColor.white
            }
        }
        layer?.backgroundColor = bgColor.cgColor
    }
    override var isFlipped: Bool { true }
}

// MARK: - Service Row View

private class ServiceRowView: NSView {
    private let service: ServiceItem
    private let action: (ServiceItem) -> Void
    private var trackingArea: NSTrackingArea?

    init(service: ServiceItem, action: @escaping (ServiceItem) -> Void) {
        self.service = service
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        setupSubviews()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: service.iconName, accessibilityDescription: service.name) {
            iconView.image = img
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: service.name)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail

        let subtitleLabel = NSTextField(labelWithString: service.subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(trackingArea!)
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { action(service) }
    }
}

// MARK: - Flipped View

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - NSView Helper

private extension NSView {
    func findView(withIdentifier id: String) -> NSView? {
        if self.identifier?.rawValue == id { return self }
        for sub in subviews {
            if let found = sub.findView(withIdentifier: id) { return found }
        }
        return nil
    }
}
