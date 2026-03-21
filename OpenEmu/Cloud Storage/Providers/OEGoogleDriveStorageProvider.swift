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
import OSLog

/// Google Drive storage provider using OAuth2 and the Drive REST API v3.
///
/// Users must provide their own Google Cloud API credentials.
/// The provider uses an "appDataFolder"-like structure under a "Bit" folder
/// in the user's Google Drive.
final class OEGoogleDriveStorageProvider: OEStorageProvider {
    
    let providerType: OEStorageProviderType = .googleDrive
    
    private(set) var status: OEStorageProviderStatus = .disconnected
    
    // OAuth2 configuration — users must set these before authenticating
    static var clientID: String = ""
    static var clientSecret: String = ""
    private static let redirectURI = "com.openemu.bit:/oauth2callback/google"
    private static let keychainService = "org.openemu.Bit.GoogleDrive"
    
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    
    /// Cache of folder IDs: path -> Google Drive folder ID
    private var folderIDCache: [String: String] = [:]
    
    /// The root folder ID for the "Bit" folder in Drive
    private var rootFolderID: String?
    
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
            try await ensureRootFolder()
            return
        }
        
        guard !Self.clientID.isEmpty else {
            throw OEStorageProviderError.invalidConfiguration
        }
        
        status = .authenticating
        
        // Build OAuth2 authorization URL
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        
        guard let authURL = components.url else {
            throw OEStorageProviderError.invalidConfiguration
        }
        
        // Open browser for auth
        NSWorkspace.shared.open(authURL)
        
        // Wait for the OAuth redirect callback
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.authContinuation = continuation
        }
        
        try await ensureRootFolder()
    }
    
    func signOut() async {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        rootFolderID = nil
        folderIDCache = [:]
        status = .disconnected
        clearTokens()
    }
    
    func handleOAuthRedirect(url: URL) -> Bool {
        guard url.scheme == "com.openemu.bit",
              url.host == "oauth2callback",
              url.path == "/google"
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
        
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        let fileName = (remotePath as NSString).lastPathComponent
        
        let parentID = try await ensureFolderPath(parentPath)
        let fileData = try Data(contentsOf: localURL)
        
        // Check if file already exists
        if let existingID = try await findFile(name: fileName, parentID: parentID) {
            // Update existing file
            try await updateFileContent(fileID: existingID, data: fileData)
            return existingID
        }
        
        // Create new file
        return try await createFile(name: fileName, parentID: parentID, data: fileData)
    }
    
    func download(remotePath: String, toLocalURL localURL: URL) async throws {
        try await ensureValidToken()
        
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        let fileName = (remotePath as NSString).lastPathComponent
        
        let parentID = try await resolveFolderPath(parentPath)
        guard let parentID else {
            throw OEStorageProviderError.fileNotFound(path: remotePath)
        }
        
        guard let fileID = try await findFile(name: fileName, parentID: parentID) else {
            throw OEStorageProviderError.fileNotFound(path: remotePath)
        }
        
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OEStorageProviderError.downloadFailed(path: remotePath, underlying: nil)
        }
        
        let localDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try data.write(to: localURL)
    }
    
    func delete(remotePath: String) async throws {
        try await ensureValidToken()
        
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        let fileName = (remotePath as NSString).lastPathComponent
        
        guard let parentID = try await resolveFolderPath(parentPath),
              let fileID = try await findFile(name: fileName, parentID: parentID) else {
            return // File doesn't exist, nothing to delete
        }
        
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
            throw OEStorageProviderError.deleteFailed(path: remotePath, underlying: nil)
        }
    }
    
    func list(remotePath: String) async throws -> [OECloudFileInfo] {
        try await ensureValidToken()
        
        guard let folderID = try await resolveFolderPath(remotePath) else {
            return []
        }
        
        let query = "'\(folderID)' in parents and trashed = false"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://www.googleapis.com/drive/v3/files?q=\(encodedQuery)&fields=files(id,name,size,modifiedTime,mimeType)")!
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            return []
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return files.compactMap { file in
            guard let id = file["id"] as? String,
                  let name = file["name"] as? String else { return nil }
            
            let size = Int64(file["size"] as? String ?? "0") ?? 0
            let mimeType = file["mimeType"] as? String ?? ""
            let isDir = mimeType == "application/vnd.google-apps.folder"
            let modifiedString = file["modifiedTime"] as? String ?? ""
            let modified = dateFormatter.date(from: modifiedString) ?? Date()
            
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
        
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        let fileName = (remotePath as NSString).lastPathComponent
        
        guard let parentID = try await resolveFolderPath(parentPath) else {
            return false
        }
        
        return try await findFile(name: fileName, parentID: parentID) != nil
    }
    
    // MARK: - OAuth2 Token Management
    
    private func exchangeCodeForTokens(code: String) async throws {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "code=\(code)",
            "client_id=\(Self.clientID)",
            "client_secret=\(Self.clientSecret)",
            "redirect_uri=\(Self.redirectURI)",
            "grant_type=authorization_code",
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
        
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "refresh_token=\(refreshToken)",
            "client_id=\(Self.clientID)",
            "client_secret=\(Self.clientSecret)",
            "grant_type=refresh_token",
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
        
        let expiresIn = json["expires_in"] as? Int ?? 3600
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
    
    // MARK: - Drive API Helpers
    
    private func ensureRootFolder() async throws {
        if let id = try await findFile(name: "Bit", parentID: "root") {
            rootFolderID = id
            folderIDCache[""] = id
        } else {
            rootFolderID = try await createFolder(name: "Bit", parentID: "root")
            folderIDCache[""] = rootFolderID
        }
    }
    
    private func findFile(name: String, parentID: String) async throws -> String? {
        let escapedName = name.replacingOccurrences(of: "'", with: "\\'")
        let query = "name = '\(escapedName)' and '\(parentID)' in parents and trashed = false"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://www.googleapis.com/drive/v3/files?q=\(encodedQuery)&fields=files(id)")!
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]],
              let first = files.first,
              let id = first["id"] as? String else {
            return nil
        }
        
        return id
    }
    
    private func createFolder(name: String, parentID: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentID],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw OEStorageProviderError.uploadFailed(path: name, underlying: nil)
        }
        
        return id
    }
    
    private func createFile(name: String, parentID: String, data: Data) async throws -> String {
        // Use multipart upload for simplicity
        let boundary = UUID().uuidString
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let metadata: [String: Any] = [
            "name": name,
            "parents": [parentID],
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJSON)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (responseData, _) = try await URLSession.shared.data(for: request)
        
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let id = json["id"] as? String else {
            throw OEStorageProviderError.uploadFailed(path: name, underlying: nil)
        }
        
        return id
    }
    
    private func updateFileContent(fileID: String, data: Data) async throws {
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileID)?uploadType=media")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OEStorageProviderError.uploadFailed(path: fileID, underlying: nil)
        }
    }
    
    /// Resolve a path like "ROMs/SNES" into a Google Drive folder ID,
    /// traversing the hierarchy from the root folder.
    private func resolveFolderPath(_ path: String) async throws -> String? {
        if path.isEmpty { return rootFolderID }
        
        if let cached = folderIDCache[path] { return cached }
        
        let components = path.split(separator: "/").map(String.init)
        var currentID = rootFolderID!
        var currentPath = ""
        
        for component in components {
            currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
            
            if let cached = folderIDCache[currentPath] {
                currentID = cached
                continue
            }
            
            guard let folderID = try await findFile(name: component, parentID: currentID) else {
                return nil
            }
            
            folderIDCache[currentPath] = folderID
            currentID = folderID
        }
        
        return currentID
    }
    
    /// Like resolveFolderPath but creates missing folders along the way.
    private func ensureFolderPath(_ path: String) async throws -> String {
        if path.isEmpty { return rootFolderID! }
        
        if let cached = folderIDCache[path] { return cached }
        
        let components = path.split(separator: "/").map(String.init)
        var currentID = rootFolderID!
        var currentPath = ""
        
        for component in components {
            currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
            
            if let cached = folderIDCache[currentPath] {
                currentID = cached
                continue
            }
            
            if let existing = try await findFile(name: component, parentID: currentID) {
                folderIDCache[currentPath] = existing
                currentID = existing
            } else {
                let newID = try await createFolder(name: component, parentID: currentID)
                folderIDCache[currentPath] = newID
                currentID = newID
            }
        }
        
        return currentID
    }
    
    // MARK: - Keychain
    
    private struct SavedTokens {
        let accessToken: String?
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
        
        return SavedTokens(accessToken: nil, refreshToken: refreshToken)
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
