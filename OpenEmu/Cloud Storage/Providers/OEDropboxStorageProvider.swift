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

import AppKit
import CryptoKit
import Foundation

/// Dropbox storage provider using OAuth2 and the Dropbox HTTP API v2.
///
/// All files are stored under `/Apps/Bit/` in the user's Dropbox (app folder access).
/// Users must provide their own Dropbox App credentials.
final class OEDropboxStorageProvider: OEStorageProvider {
    
    let providerType: OEStorageProviderType = .dropbox
    
    private(set) var status: OEStorageProviderStatus = .disconnected
    
    // OAuth2 configuration
    static var appKey: String = ""
    static var appSecret: String = ""
    private static let keychainService = "org.openemu.Bit.Dropbox"

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    /// Dropbox paths are relative to the app folder root.
    /// Files will appear at `/Apps/Bit/...` in the user's Dropbox.
    private let rootPath = ""

    
    var isAuthenticated: Bool {
        return accessToken != nil
    }
    
    // MARK: - Authentication
    
    func authenticate() async throws {
        // Try to restore from keychain
        if let tokens = loadTokens(), let refresh = tokens.refreshToken {
            refreshToken = refresh
            do {
                try await refreshAccessToken()
                return
            } catch {
                // Refresh failed — clear stale tokens and fall through to fresh OAuth
                NSLog("[Dropbox] Token refresh failed: %@. Starting fresh OAuth flow.", "\(error)")
                clearTokens()
                accessToken = nil
                refreshToken = nil
                tokenExpiry = nil
            }
        }

        guard !Self.appKey.isEmpty else {
            throw OEStorageProviderError.authenticationFailed(
                underlying: NSError(
                    domain: "org.openemu.CloudStorage",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Dropbox is not yet available. API credentials have not been configured."]
                )
            )
        }

        status = .authenticating

        // Generate PKCE code verifier and challenge (RFC 7636).
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)

        // Use the code display flow (no redirect_uri). Dropbox shows the
        // authorization code on screen and the user pastes it into our dialog.
        // This avoids all redirect URI registration issues for desktop apps.
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url else {
            throw OEStorageProviderError.invalidConfiguration
        }

        NSLog("[Dropbox] Opening auth URL (code display flow): %@", authURL.absoluteString)
        NSWorkspace.shared.open(authURL)

        // Show a dialog for the user to paste the authorization code from Dropbox
        let code = try await promptForAuthorizationCode()

        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
    }

    /// Present a modal dialog asking the user to paste the authorization code from Dropbox.
    @MainActor
    private func promptForAuthorizationCode() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Dropbox Authorization"
            alert.informativeText = "After signing in on the Dropbox website, copy the authorization code shown and paste it below."
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .informational

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            textField.placeholderString = "Paste authorization code here"
            alert.accessoryView = textField
            alert.window.initialFirstResponder = textField

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let code = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if code.isEmpty {
                    continuation.resume(throwing: OEStorageProviderError.authenticationFailed(
                        underlying: NSError(domain: "org.openemu.CloudStorage", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "No authorization code entered."])
                    ))
                } else {
                    continuation.resume(returning: code)
                }
            } else {
                self.status = .disconnected
                continuation.resume(throwing: OEStorageProviderError.authenticationFailed(
                    underlying: NSError(domain: "org.openemu.CloudStorage", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Authorization cancelled."])
                ))
            }
        }
    }

    func signOut() async {
        // Revoke token
        if let token = accessToken {
            var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }

        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        status = .disconnected
        clearTokens()
    }
    
    // MARK: - File Operations
    
    /// Maximum number of retry attempts for rate-limited requests.
    private static let maxRetries = 5

    @discardableResult
    func upload(localURL: URL, toRemotePath remotePath: String) async throws -> String {
        try await ensureValidToken()

        let dropboxPath = "/\(remotePath)"
        let fileData = try Data(contentsOf: localURL)

        // Dropbox /2/files/upload has a 150 MB limit. Use upload sessions for larger files.
        if fileData.count > 150 * 1024 * 1024 {
            return try await uploadLargeFile(localURL: localURL, remotePath: remotePath, fileData: fileData)
        }

        // Dropbox-API-Arg header: escape non-ASCII characters as \uXXXX per Dropbox requirements
        let args: [String: Any] = [
            "path": dropboxPath,
            "mode": "overwrite",
            "autorename": false,
            "mute": true,
        ]
        let argsJSON = try JSONSerialization.data(withJSONObject: args)
        let argsString = Self.escapeNonASCII(String(data: argsJSON, encoding: .utf8) ?? "")

        // Retry loop for Dropbox rate limiting (HTTP 429)
        for attempt in 0..<Self.maxRetries {
            let url = URL(string: "https://content.dropboxapi.com/2/files/upload")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(argsString, forHTTPHeaderField: "Dropbox-API-Arg")
            request.httpBody = fileData

            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OEStorageProviderError.uploadFailed(path: remotePath, underlying: nil)
            }

            if (200...299).contains(httpResponse.statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let id = json["id"] as? String {
                    return id
                }
                return remotePath
            }

            // Handle rate limiting: wait and retry
            if httpResponse.statusCode == 429 {
                let retryAfter = Self.parseRetryAfter(from: responseData) ?? (attempt + 1)
                let delay = UInt64(retryAfter) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                continue
            }

            // Non-retryable error
            let responseBody = String(data: responseData, encoding: .utf8) ?? "no body"
            NSLog("[Dropbox] Upload failed for %@ (HTTP %d): %@", remotePath, httpResponse.statusCode, responseBody)

            let errorMessage = Self.parseDropboxError(from: responseData) ?? "HTTP \(httpResponse.statusCode)"
            throw OEStorageProviderError.uploadFailed(path: remotePath, underlying: NSError(
                domain: "org.openemu.CloudStorage", code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            ))
        }

        // Exhausted all retries
        throw OEStorageProviderError.uploadFailed(path: remotePath, underlying: NSError(
            domain: "org.openemu.CloudStorage", code: 429,
            userInfo: [NSLocalizedDescriptionKey: "Rate limited after \(Self.maxRetries) retries"]
        ))
    }

    /// Upload files larger than 150 MB using Dropbox upload sessions.
    private func uploadLargeFile(localURL: URL, remotePath: String, fileData: Data) async throws -> String {
        let dropboxPath = "/\(remotePath)"
        let chunkSize = 8 * 1024 * 1024 // 8 MB chunks

        // Step 1: Start upload session
        let startURL = URL(string: "https://content.dropboxapi.com/2/files/upload_session/start")!
        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        startRequest.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        startRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        startRequest.setValue("{\"close\":false}", forHTTPHeaderField: "Dropbox-API-Arg")

        let firstChunk = fileData.prefix(chunkSize)
        startRequest.httpBody = firstChunk

        let (startData, _) = try await URLSession.shared.data(for: startRequest)
        guard let startJSON = try? JSONSerialization.jsonObject(with: startData) as? [String: Any],
              let sessionId = startJSON["session_id"] as? String else {
            throw OEStorageProviderError.uploadFailed(path: remotePath, underlying: nil)
        }

        // Step 2: Append remaining chunks
        var offset = firstChunk.count
        while offset < fileData.count - chunkSize {
            let chunk = fileData[offset..<min(offset + chunkSize, fileData.count)]

            let appendURL = URL(string: "https://content.dropboxapi.com/2/files/upload_session/append_v2")!
            var appendRequest = URLRequest(url: appendURL)
            appendRequest.httpMethod = "POST"
            appendRequest.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
            appendRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

            let appendArgs: [String: Any] = [
                "cursor": ["session_id": sessionId, "offset": offset],
                "close": false,
            ]
            let appendJSON = try JSONSerialization.data(withJSONObject: appendArgs)
            appendRequest.setValue(String(data: appendJSON, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
            appendRequest.httpBody = chunk

            _ = try await URLSession.shared.data(for: appendRequest)
            offset += chunk.count
        }

        // Step 3: Finish with the last chunk
        let lastChunk = fileData[offset...]
        let finishURL = URL(string: "https://content.dropboxapi.com/2/files/upload_session/finish")!
        var finishRequest = URLRequest(url: finishURL)
        finishRequest.httpMethod = "POST"
        finishRequest.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        finishRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let finishArgs: [String: Any] = [
            "cursor": ["session_id": sessionId, "offset": offset],
            "commit": [
                "path": dropboxPath,
                "mode": "overwrite",
                "autorename": false,
                "mute": true,
            ],
        ]
        let finishJSON = try JSONSerialization.data(withJSONObject: finishArgs)
        finishRequest.setValue(String(data: finishJSON, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
        finishRequest.httpBody = lastChunk

        let (finishData, _) = try await URLSession.shared.data(for: finishRequest)

        if let json = try? JSONSerialization.jsonObject(with: finishData) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }

        return remotePath
    }

    /// Escape non-ASCII characters in a string as \uXXXX for the Dropbox-API-Arg header.
    private static func escapeNonASCII(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            if scalar.value > 127 {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                result += String(scalar)
            }
        }
        return result
    }

    /// Parse a Dropbox error response body to extract a human-readable message.
    private static func parseDropboxError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let summary = json["error_summary"] as? String { return summary }
        if let error = json["error"] as? [String: Any], let tag = error[".tag"] as? String { return tag }
        return nil
    }

    /// Parse the retry_after field from a Dropbox 429 response (in seconds).
    private static func parseRetryAfter(from data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let retryAfter = error["retry_after"] as? Int else { return nil }
        return retryAfter
    }
    
    func download(remotePath: String, toLocalURL localURL: URL) async throws {
        try await ensureValidToken()
        
        let dropboxPath = "/\(remotePath)"
        
        let url = URL(string: "https://content.dropboxapi.com/2/files/download")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        
        let args: [String: Any] = ["path": dropboxPath]
        let argsJSON = try JSONSerialization.data(withJSONObject: args)
        request.setValue(String(data: argsJSON, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OEStorageProviderError.downloadFailed(path: remotePath, underlying: nil)
        }
        
        if httpResponse.statusCode == 409 {
            throw OEStorageProviderError.fileNotFound(path: remotePath)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OEStorageProviderError.downloadFailed(path: remotePath, underlying: nil)
        }
        
        let localDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try data.write(to: localURL)
    }
    
    func delete(remotePath: String) async throws {
        try await ensureValidToken()
        
        let dropboxPath = "/\(remotePath)"
        
        let url = URL(string: "https://api.dropboxapi.com/2/files/delete_v2")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["path": dropboxPath]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        // 409 means path not found, which is fine for delete
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 409 else {
            throw OEStorageProviderError.deleteFailed(path: remotePath, underlying: nil)
        }
    }
    
    func list(remotePath: String) async throws -> [OECloudFileInfo] {
        try await ensureValidToken()
        
        let dropboxPath = remotePath.isEmpty ? "" : "/\(remotePath)"
        
        let url = URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "path": dropboxPath,
            "recursive": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return []
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else {
            return []
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            
            let tag = entry[".tag"] as? String ?? ""
            let isDir = tag == "folder"
            let size = entry["size"] as? Int64 ?? 0
            let modifiedString = entry["server_modified"] as? String ?? ""
            let modified = dateFormatter.date(from: modifiedString) ?? Date()
            let id = entry["id"] as? String ?? name
            
            return OECloudFileInfo(
                identifier: id,
                name: name,
                path: remotePath.isEmpty ? name : remotePath + "/" + name,
                size: size,
                modifiedDate: modified,
                isDirectory: isDir
            )
        }
    }
    
    func listRecursive(remotePath: String) async throws -> [OECloudFileInfo] {
        try await ensureValidToken()

        let dropboxPath = remotePath.isEmpty ? "" : "/\(remotePath)"

        let url = URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": dropboxPath,
            "recursive": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var allFiles: [OECloudFileInfo] = []
        let dateFormatter = ISO8601DateFormatter()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return []
        }

        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        func parseEntries(_ entries: [[String: Any]]) {
            for entry in entries {
                guard let name = entry["name"] as? String else { continue }
                let tag = entry[".tag"] as? String ?? ""
                guard tag == "file" else { continue }
                let pathDisplay = entry["path_display"] as? String ?? name
                // Strip leading "/" to get relative path
                let relativePath = pathDisplay.hasPrefix("/") ? String(pathDisplay.dropFirst()) : pathDisplay
                let size = entry["size"] as? Int64 ?? 0
                let modifiedString = entry["server_modified"] as? String ?? ""
                let modified = dateFormatter.date(from: modifiedString) ?? Date()
                let id = entry["id"] as? String ?? name

                allFiles.append(OECloudFileInfo(
                    identifier: id,
                    name: name,
                    path: relativePath,
                    size: size,
                    modifiedDate: modified,
                    isDirectory: false
                ))
            }
        }

        if let entries = json["entries"] as? [[String: Any]] {
            parseEntries(entries)
        }

        // Handle pagination
        while json["has_more"] as? Bool == true, let cursor = json["cursor"] as? String {
            let continueURL = URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!
            var continueRequest = URLRequest(url: continueURL)
            continueRequest.httpMethod = "POST"
            continueRequest.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
            continueRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            continueRequest.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": cursor])

            let (continueData, continueResponse) = try await URLSession.shared.data(for: continueRequest)
            guard let continueHTTP = continueResponse as? HTTPURLResponse,
                  (200...299).contains(continueHTTP.statusCode),
                  let continueJSON = try? JSONSerialization.jsonObject(with: continueData) as? [String: Any] else {
                break
            }
            json = continueJSON
            if let entries = continueJSON["entries"] as? [[String: Any]] {
                parseEntries(entries)
            }
        }

        return allFiles
    }

    func fileExists(remotePath: String) async throws -> Bool {
        try await ensureValidToken()

        let dropboxPath = "/\(remotePath)"
        
        let url = URL(string: "https://api.dropboxapi.com/2/files/get_metadata")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["path": dropboxPath]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        return (200...299).contains(httpResponse?.statusCode ?? 0)
    }
    
    // MARK: - OAuth2 Token Management
    
    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        let url = URL(string: "https://api.dropboxapi.com/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Use PKCE code_verifier instead of client_secret for public/native clients.
        // No redirect_uri since we use the code display flow.
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: Self.appKey),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
        ]
        let bodyString = components.percentEncodedQuery ?? ""
        request.httpBody = bodyString.data(using: .utf8)

        NSLog("[Dropbox] Token exchange request to %@", url.absoluteString)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            NSLog("[Dropbox] Token exchange failed (HTTP %d): %@", httpResponse.statusCode, responseBody)
        }

        try parseTokenResponse(data)
        status = .connected
    }
    
    private func refreshAccessToken() async throws {
        guard let refreshToken else {
            throw OEStorageProviderError.notAuthenticated
        }

        let url = URL(string: "https://api.dropboxapi.com/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // For PKCE public clients, use client_id only (no client_secret).
        // If client_secret is available (confidential client), include it.
        var components = URLComponents()
        var items = [
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: Self.appKey),
        ]
        if !Self.appSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: Self.appSecret))
        }
        components.queryItems = items
        let bodyString = components.percentEncodedQuery ?? ""
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            NSLog("[Dropbox] Token refresh failed (HTTP %d): %@", httpResponse.statusCode, responseBody)
        }

        try parseTokenResponse(data)
        status = .connected
    }
    
    private func parseTokenResponse(_ data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            // Parse and surface Dropbox's error message
            var errorMessage = "Invalid token response"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                errorMessage = json["error_description"] as? String ?? json["error"] as? String ?? errorMessage
            }
            NSLog("[Dropbox] Token parse failed: %@", errorMessage)
            throw OEStorageProviderError.authenticationFailed(
                underlying: NSError(domain: "org.openemu.CloudStorage", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: errorMessage])
            )
        }
        
        accessToken = token
        if let refresh = json["refresh_token"] as? String {
            refreshToken = refresh
        }
        
        let expiresIn = json["expires_in"] as? Int ?? 14400
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
        
        saveTokens()
    }
    
    private func ensureValidToken() async throws {
        guard accessToken != nil else {
            throw OEStorageProviderError.notAuthenticated
        }
        
        if let expiry = tokenExpiry, Date() >= expiry {
            try await refreshAccessToken()
        }
    }
    
    // MARK: - PKCE (RFC 7636)

    /// Generate a random code verifier for PKCE (43-128 URL-safe characters).
    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compute the S256 code challenge from a code verifier.
    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain
    
    private struct SavedTokens {
        let refreshToken: String?
    }
    
    private func saveTokens() {
        guard let refreshToken else { return }
        let data = refreshToken.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "tokens",
        ]
        SecItemDelete(query as CFDictionary)
        
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    
    private func loadTokens() -> SavedTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "tokens",
            kSecReturnData as String: true,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let refreshToken = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return SavedTokens(refreshToken: refreshToken)
    }
    
    private func clearTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "tokens",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
