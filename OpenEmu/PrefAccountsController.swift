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

final class PrefAccountsController: NSViewController {

    // MARK: - UI Elements

    // Logged-out state
    private var usernameField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var signInButton: NSButton!
    private var statusLabel: NSTextField!
    private var loginContainer: NSView!

    // Logged-in state
    private var loggedInContainer: NSView!
    private var loggedInLabel: NSTextField!
    private var signOutButton: NSButton!

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        buildLoginView()
        buildLoggedInView()
        updateUI()
    }

    // MARK: - Build Login View

    private func buildLoginView() {
        loginContainer = NSView()
        loginContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loginContainer)

        let header = NSTextField(labelWithString: "RetroAchievements")
        header.font = .boldSystemFont(ofSize: 13)
        header.translatesAutoresizingMaskIntoConstraints = false
        loginContainer.addSubview(header)

        let description = NSTextField(wrappingLabelWithString: "Sign in with your RetroAchievements account to track achievements while playing games.")
        description.font = .systemFont(ofSize: 11)
        description.textColor = .secondaryLabelColor
        description.translatesAutoresizingMaskIntoConstraints = false
        loginContainer.addSubview(description)

        let gridView = NSGridView(numberOfColumns: 2, rows: 0)
        gridView.column(at: 0).xPlacement = .trailing
        gridView.rowAlignment = .firstBaseline
        gridView.columnSpacing = 8
        gridView.rowSpacing = 10
        gridView.translatesAutoresizingMaskIntoConstraints = false
        loginContainer.addSubview(gridView)

        let usernameLabel = NSTextField(labelWithString: "Username:")
        usernameLabel.alignment = .right
        usernameField = NSTextField()
        usernameField.placeholderString = "RetroAchievements username"
        usernameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        gridView.addRow(with: [usernameLabel, usernameField])

        let passwordLabel = NSTextField(labelWithString: "Password:")
        passwordLabel.alignment = .right
        passwordField = NSSecureTextField()
        passwordField.placeholderString = "Password"
        passwordField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        gridView.addRow(with: [passwordLabel, passwordField])

        signInButton = NSButton(title: "Sign In", target: self, action: #selector(signIn(_:)))
        signInButton.bezelStyle = .rounded
        signInButton.keyEquivalent = "\r"
        signInButton.translatesAutoresizingMaskIntoConstraints = false
        loginContainer.addSubview(signInButton)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        loginContainer.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            loginContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            loginContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            loginContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            header.topAnchor.constraint(equalTo: loginContainer.topAnchor),
            header.leadingAnchor.constraint(equalTo: loginContainer.leadingAnchor),

            description.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            description.leadingAnchor.constraint(equalTo: loginContainer.leadingAnchor),
            description.trailingAnchor.constraint(equalTo: loginContainer.trailingAnchor),

            gridView.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 16),
            gridView.leadingAnchor.constraint(equalTo: loginContainer.leadingAnchor),

            signInButton.topAnchor.constraint(equalTo: gridView.bottomAnchor, constant: 14),
            signInButton.trailingAnchor.constraint(equalTo: gridView.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: signInButton.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: loginContainer.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: loginContainer.trailingAnchor),

            signInButton.bottomAnchor.constraint(equalTo: loginContainer.bottomAnchor),
        ])
    }

    // MARK: - Build Logged-In View

    private func buildLoggedInView() {
        loggedInContainer = NSView()
        loggedInContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loggedInContainer)

        let header = NSTextField(labelWithString: "RetroAchievements")
        header.font = .boldSystemFont(ofSize: 13)
        header.translatesAutoresizingMaskIntoConstraints = false
        loggedInContainer.addSubview(header)

        let checkmark = NSImageView()
        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Signed in")
        checkmark.contentTintColor = .systemGreen
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        loggedInContainer.addSubview(checkmark)

        loggedInLabel = NSTextField(labelWithString: "")
        loggedInLabel.font = .systemFont(ofSize: 13)
        loggedInLabel.translatesAutoresizingMaskIntoConstraints = false
        loggedInContainer.addSubview(loggedInLabel)

        signOutButton = NSButton(title: "Sign Out", target: self, action: #selector(signOut(_:)))
        signOutButton.bezelStyle = .rounded
        signOutButton.translatesAutoresizingMaskIntoConstraints = false
        loggedInContainer.addSubview(signOutButton)

        NSLayoutConstraint.activate([
            loggedInContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            loggedInContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            loggedInContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            header.topAnchor.constraint(equalTo: loggedInContainer.topAnchor),
            header.leadingAnchor.constraint(equalTo: loggedInContainer.leadingAnchor),

            checkmark.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            checkmark.leadingAnchor.constraint(equalTo: loggedInContainer.leadingAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 20),
            checkmark.heightAnchor.constraint(equalToConstant: 20),

            loggedInLabel.centerYAnchor.constraint(equalTo: checkmark.centerYAnchor),
            loggedInLabel.leadingAnchor.constraint(equalTo: checkmark.trailingAnchor, constant: 6),

            signOutButton.topAnchor.constraint(equalTo: checkmark.bottomAnchor, constant: 14),
            signOutButton.leadingAnchor.constraint(equalTo: loggedInContainer.leadingAnchor),
            signOutButton.bottomAnchor.constraint(equalTo: loggedInContainer.bottomAnchor),
        ])
    }

    // MARK: - UI State

    private func updateUI() {
        let store = RetroAchievementsCredentialStore.shared
        let loggedIn = store.isLoggedIn

        loginContainer.isHidden = loggedIn
        loggedInContainer.isHidden = !loggedIn

        if loggedIn, let username = store.username {
            loggedInLabel.stringValue = "Signed in as \(username)"
        }
    }

    // MARK: - Actions

    @objc private func signIn(_ sender: NSButton) {
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue

        guard !username.isEmpty, !password.isEmpty else {
            showStatus("Please enter your username and password.", isError: true)
            return
        }

        signInButton.isEnabled = false
        statusLabel.isHidden = true

        // Call RetroAchievements login API
        performLogin(username: username, password: password)
    }

    @objc private func signOut(_ sender: NSButton) {
        RetroAchievementsCredentialStore.shared.clear()
        passwordField.stringValue = ""
        usernameField.stringValue = ""
        statusLabel.isHidden = true
        updateUI()
    }

    // MARK: - Login API

    private func performLogin(username: String, password: String) {
        let urlString = "https://retroachievements.org/dorequest.php"
        guard let url = URL(string: urlString) else {
            showStatus("Invalid URL.", isError: true)
            signInButton.isEnabled = true
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Build POST body: r=login&u=<username>&p=<password>
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "r", value: "login"),
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "p", value: password),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleLoginResponse(data: data, response: response, error: error, username: username)
            }
        }
        task.resume()
    }

    private func handleLoginResponse(data: Data?, response: URLResponse?, error: Error?, username: String) {
        signInButton.isEnabled = true

        if let error = error {
            showStatus("Connection error: \(error.localizedDescription)", isError: true)
            return
        }

        guard let data = data else {
            showStatus("No response from server.", isError: true)
            return
        }

        // Parse JSON response
        // Expected: {"Success": true, "User": "...", "Token": "...", "Score": ..., ...}
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                showStatus("Unexpected response format.", isError: true)
                return
            }

            let success = json["Success"] as? Bool ?? false
            if !success {
                let errorMsg = json["Error"] as? String ?? "Login failed. Check your credentials."
                showStatus(errorMsg, isError: true)
                return
            }

            guard let token = json["Token"] as? String, !token.isEmpty else {
                showStatus("No API token received.", isError: true)
                return
            }

            // Use the case-corrected username from the server if available
            let correctedUsername = json["User"] as? String ?? username

            RetroAchievementsCredentialStore.shared.save(username: correctedUsername, token: token)
            passwordField.stringValue = ""
            updateUI()
        } catch {
            showStatus("Failed to parse response.", isError: true)
        }
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = false
    }
}

// MARK: - PreferencePane

extension PrefAccountsController: PreferencePane {

    var icon: NSImage? {
        NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Accounts")
    }

    var panelTitle: String { "Accounts" }

    var viewSize: NSSize { NSSize(width: 468, height: 300) }
}
