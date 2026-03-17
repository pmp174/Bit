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
    private static let redirectURI = "com.openemu.bit:/oauth2callback/dropbox"
    private static let keychainService = "org.openemu.Bit.Dropbox"
    
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    
    /// Dropbox paths are relative to the app folder root.
    /// Files will appear at `/Apps/Bit/...` in the user's Dropbox.
    private let rootPath = ""
    
    private var authContinuation: CheckedContinuation<Void, Error>?
    
    var isAuthenticated: Bool {
        return accessToken != nil
    }
    
    // MARK: - Authentication
    
    func authenticate() async throws {
        // Try to restore from keychain
        if let tokens = loadTokens(), let refresh = tokens.refreshToken {
            refreshToken = refresh
            try await refreshAccessToken()
            return
        }
        
        guard !Self.appKey.isEmpty else {
            throw OEStorageProviderError.invalidConfiguration
        }
        
        status = .authenticating
        
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.appKey),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "token_access_type", value: "offline"),
        ]
        
        guard let authURL = components.url else {
            throw OEStorageProviderError.invalidConfiguration
        }
        
        NSWorkspace.shared.open(authURL)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.authContinuation = continuation
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
    
    func handleOAuthRedirect(url: URL) -> Bool {
        guard url.scheme == "com.openemu.bit",
              url.host == "oauth2callback",
              url.path == "/dropbox"
        else { return false }
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
            authContinuation?.resume(throwing: OEStorageProviderError.authenticationFailed(underlying: nil))
            authContinuation = nil
            return true
        }
        
        Task {
            do {
                try await exchangeCodeForTokens(code: code)
                authContinuation?.resume()
            } catch {
                authContinuation?.resume(throwing: error)
            }
            authContinuation = nil
        }
        
        return true
    }
    
    // MARK: - File Operations
    
    @discardableResult
    func upload(localURL: URL, toRemotePath remotePath: String) async throws -> String {
        try await ensureValidToken()
        
        let dropboxPath = "/\(remotePath)"
        let fileData = try Data(contentsOf: localURL)
        
        let url = URL(string: "https://content.dropboxapi.com/2/files/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        let args: [String: Any] = [
            "path": dropboxPath,
            "mode": "overwrite",
            "autorename": false,
            "mute": true,
        ]
        let argsJSON = try JSONSerialization.data(withJSONObject: args)
        request.setValue(String(data: argsJSON, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = fileData
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OEStorageProviderError.uploadFailed(path: remotePath, underlying: nil)
        }
        
        // Extract file ID from response
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }
        
        return remotePath
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
    
    private func exchangeCodeForTokens(code: String) async throws {
        let url = URL(string: "https://api.dropboxapi.com/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "code=\(code)",
            "grant_type=authorization_code",
            "client_id=\(Self.appKey)",
            "client_secret=\(Self.appSecret)",
            "redirect_uri=\(Self.redirectURI)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        
        let (data, _) = try await URLSession.shared.data(for: request)
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
        
        let body = [
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
            "client_id=\(Self.appKey)",
            "client_secret=\(Self.appSecret)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        try parseTokenResponse(data)
        
        status = .connected
    }
    
    private func parseTokenResponse(_ data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw OEStorageProviderError.authenticationFailed(underlying: nil)
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
