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

/// WebDAV storage provider for NAS/self-hosted servers.
/// Uses standard HTTP methods: PUT (upload), GET (download), DELETE, MKCOL (mkdir), PROPFIND (list).
/// Compatible with `rclone serve webdav`, Nextcloud, Synology, and other WebDAV servers.
final class OEWebDAVStorageProvider: OEStorageProvider {
    
    let providerType: OEStorageProviderType = .webDAV
    
    private(set) var status: OEStorageProviderStatus = .disconnected
    
    private var serverURL: URL?
    private var session: URLSession?
    
    private static let keychainService = "org.openemu.Bit.WebDAV"
    
    var isAuthenticated: Bool {
        return serverURL != nil && session != nil && status.isConnected
    }
    
    // MARK: - Configuration
    
    /// Configure the WebDAV server URL and credentials.
    func configure(serverURL: URL, username: String, password: String) {
        self.serverURL = serverURL.appendingPathComponent("Bit/", isDirectory: true)
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        
        // Set basic auth header
        let loginString = "\(username):\(password)"
        if let loginData = loginString.data(using: .utf8) {
            let base64LoginString = loginData.base64EncodedString()
            config.httpAdditionalHeaders = ["Authorization": "Basic \(base64LoginString)"]
        }
        
        session = URLSession(configuration: config)
        
        // Store credentials in keychain
        saveCredentials(url: serverURL.absoluteString, username: username, password: password)
    }
    
    func authenticate() async throws {
        // Try to load saved credentials
        if serverURL == nil, let saved = loadCredentials() {
            guard let url = URL(string: saved.url) else {
                throw OEStorageProviderError.invalidConfiguration
            }
            configure(serverURL: url, username: saved.username, password: saved.password)
        }
        
        guard let serverURL, let session else {
            throw OEStorageProviderError.invalidConfiguration
        }
        
        status = .authenticating
        
        // Test connection with PROPFIND on root
        var request = URLRequest(url: serverURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        
        do {
            let (_, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            
            if let code = httpResponse?.statusCode, (200...299).contains(code) || code == 207 {
                status = .connected
                
                // Ensure Bit root directory exists
                try await ensureDirectory(at: "")
            } else if httpResponse?.statusCode == 401 {
                status = .error(OEStorageProviderError.notAuthenticated)
                throw OEStorageProviderError.authenticationFailed(underlying: nil)
            } else {
                status = .error(OEStorageProviderError.providerUnavailable)
                throw OEStorageProviderError.providerUnavailable
            }
        } catch let error as OEStorageProviderError {
            throw error
        } catch {
            status = .error(error)
            throw OEStorageProviderError.authenticationFailed(underlying: error)
        }
    }
    
    func signOut() async {
        serverURL = nil
        session = nil
        status = .disconnected
        clearCredentials()
    }
    
    // MARK: - File Operations
    
    @discardableResult
    func upload(localURL: URL, toRemotePath remotePath: String) async throws -> String {
        guard let url = resolveURL(for: remotePath), let session else {
            throw OEStorageProviderError.notAuthenticated
        }
        
        // Ensure parent directory exists
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        if !parentPath.isEmpty {
            try await ensureDirectory(at: parentPath)
        }
        
        let fileData = try Data(contentsOf: localURL)
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = fileData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OEStorageProviderError.uploadFailed(path: remotePath, underlying: nil)
        }
        
        return remotePath
    }
    
    func download(remotePath: String, toLocalURL localURL: URL) async throws {
        guard let url = resolveURL(for: remotePath), let session else {
            throw OEStorageProviderError.notAuthenticated
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                throw OEStorageProviderError.fileNotFound(path: remotePath)
            }
            throw OEStorageProviderError.downloadFailed(path: remotePath, underlying: nil)
        }
        
        let localDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try data.write(to: localURL)
    }
    
    func delete(remotePath: String) async throws {
        guard let url = resolveURL(for: remotePath), let session else {
            throw OEStorageProviderError.notAuthenticated
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
            throw OEStorageProviderError.deleteFailed(path: remotePath, underlying: nil)
        }
    }
    
    func list(remotePath: String) async throws -> [OECloudFileInfo] {
        guard let url = resolveURL(for: remotePath), let session else {
            throw OEStorageProviderError.notAuthenticated
        }
        
        var request = URLRequest(url: url.appendingPathComponent("/"))
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        
        let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
            <D:prop>
                <D:displayname/>
                <D:getcontentlength/>
                <D:getlastmodified/>
                <D:resourcetype/>
            </D:prop>
        </D:propfind>
        """
        request.httpBody = propfindBody.data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 207 || (200...299).contains(httpResponse.statusCode) else {
            return []
        }
        
        return parseMultiStatusResponse(data: data, basePath: remotePath)
    }
    
    func fileExists(remotePath: String) async throws -> Bool {
        guard let url = resolveURL(for: remotePath), let session else {
            throw OEStorageProviderError.notAuthenticated
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        let (_, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        return httpResponse?.statusCode == 200
    }
    
    // MARK: - Private Helpers
    
    private func resolveURL(for remotePath: String) -> URL? {
        guard let serverURL else { return nil }
        if remotePath.isEmpty { return serverURL }
        return serverURL.appendingPathComponent(remotePath)
    }
    
    private func ensureDirectory(at remotePath: String) async throws {
        guard let url = resolveURL(for: remotePath), let session else { return }
        
        // Split path into components and create each level
        let components = remotePath.split(separator: "/").map(String.init)
        var currentURL = serverURL!
        
        for component in components {
            currentURL = currentURL.appendingPathComponent(component, isDirectory: true)
            
            var request = URLRequest(url: currentURL)
            request.httpMethod = "MKCOL"
            
            // MKCOL returns 201 (created) or 405 (already exists) — both are fine
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 201 && code != 405 && !(200...299).contains(code) {
                if #available(macOS 11.0, *) {
                    Logger.cloudStorage.warning("MKCOL for \(currentURL.path) returned \(code)")
                }
            }
        }
        
        // Also try the final path directly in case components were empty
        if components.isEmpty {
            var request = URLRequest(url: url)
            request.httpMethod = "MKCOL"
            _ = try? await session.data(for: request)
        }
    }
    
    /// Parse a WebDAV PROPFIND multistatus XML response into OECloudFileInfo objects.
    private func parseMultiStatusResponse(data: Data, basePath: String) -> [OECloudFileInfo] {
        var results: [OECloudFileInfo] = []
        
        guard let doc = try? XMLDocument(data: data) else { return results }
        
        // Use local-name() to avoid namespace prefix issues
        guard let responses = try? doc.nodes(forXPath: "//*[local-name()='response']") as? [XMLElement] else {
            return results
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        
        for response in responses {
            guard let href = (try? response.nodes(forXPath: "*[local-name()='href']"))?.first?.stringValue else {
                continue
            }
            
            // Skip the directory itself
            let cleanHref = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanBase = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if cleanHref == cleanBase || cleanHref.isEmpty { continue }
            
            let name = (href as NSString).lastPathComponent.removingPercentEncoding ?? (href as NSString).lastPathComponent
            let isDirectory = (try? response.nodes(forXPath: ".//*[local-name()='resourcetype']/*[local-name()='collection']"))?.isEmpty == false
            
            let sizeString = (try? response.nodes(forXPath: ".//*[local-name()='getcontentlength']"))?.first?.stringValue
            let size = Int64(sizeString ?? "0") ?? 0
            
            let dateString = (try? response.nodes(forXPath: ".//*[local-name()='getlastmodified']"))?.first?.stringValue
            let modified = dateFormatter.date(from: dateString ?? "") ?? Date()
            
            let info = OECloudFileInfo(
                identifier: name,
                name: name,
                path: basePath.isEmpty ? name : basePath + "/" + name,
                size: size,
                modifiedDate: modified,
                isDirectory: isDirectory
            )
            results.append(info)
        }
        
        return results
    }
    
    // MARK: - Keychain
    
    private struct SavedCredentials {
        let url: String
        let username: String
        let password: String
    }
    
    private func saveCredentials(url: String, username: String, password: String) {
        let data = "\(url)\n\(username)\n\(password)".data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "webdav",
        ]
        
        SecItemDelete(query as CFDictionary)
        
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    
    private func loadCredentials() -> SavedCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "webdav",
            kSecReturnData as String: true,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        let parts = string.split(separator: "\n", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        
        return SavedCredentials(url: parts[0], username: parts[1], password: parts[2])
    }
    
    private func clearCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "webdav",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@available(macOS 11.0, *)
private extension Logger {
    static let cloudStorage = Logger(subsystem: "org.openemu.Bit", category: "CloudStorage")
}
