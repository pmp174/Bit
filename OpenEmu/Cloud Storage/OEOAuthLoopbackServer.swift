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
import Network

/// A temporary loopback HTTP server for receiving OAuth2 authorization code callbacks.
///
/// Starts on a random port on 127.0.0.1, waits for a single HTTP request containing
/// an authorization code in the query string, sends a user-friendly HTML response,
/// and shuts down. This implements the loopback redirect approach described in
/// RFC 8252 (OAuth 2.0 for Native Apps).
final class OEOAuthLoopbackServer {
    
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var assignedPort: UInt16 = 0
    
    /// The redirect URI to use in OAuth authorization requests.
    /// Only valid after `start()` completes.
    var redirectURI: String {
        return "http://127.0.0.1:\(assignedPort)"
    }
    
    /// Start the loopback server on a random available port.
    /// - Returns: The port number the server is listening on.
    func start() async throws -> UInt16 {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                
                var portResumed = false
                
                listener.stateUpdateHandler = { [weak self] state in
                    guard !portResumed else { return }
                    switch state {
                    case .ready:
                        if let port = self?.listener?.port {
                            portResumed = true
                            self?.assignedPort = port.rawValue
                            continuation.resume(returning: port.rawValue)
                        }
                    case .failed(let error):
                        portResumed = true
                        continuation.resume(throwing: error)
                    case .cancelled:
                        portResumed = true
                        continuation.resume(throwing: OEStorageProviderError.authenticationFailed(underlying: nil))
                    default:
                        break
                    }
                }
                
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                
                listener.start(queue: .main)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Wait for the OAuth provider to redirect the browser back with an authorization code.
    /// - Returns: The authorization code extracted from the callback URL.
    func waitForAuthorizationCode() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
    
    /// Stop the server and clean up.
    func stop() {
        listener?.cancel()
        listener = nil
    }
    
    // MARK: - Connection Handling
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                return
            }
            
            let params = self.parseQueryParameters(from: request)
            
            if let code = params["code"] {
                let html = """
                <html><head><title>OpenEmu</title>\
                <style>body{font-family:-apple-system,sans-serif;text-align:center;padding:60px;background:#1a1a1a;color:#e0e0e0;}\
                h2{color:#4CAF50;}p{color:#999;}</style></head>\
                <body><h2>Authentication Successful</h2>\
                <p>You can close this window and return to OpenEmu.</p></body></html>
                """
                self.sendHTTPResponse(connection: connection, statusCode: 200, html: html)
                self.stop()
                self.continuation?.resume(returning: code)
                self.continuation = nil
            } else {
                let errorMessage = params["error_description"] ?? params["error"] ?? "No authorization code received."
                let html = """
                <html><head><title>OpenEmu</title>\
                <style>body{font-family:-apple-system,sans-serif;text-align:center;padding:60px;background:#1a1a1a;color:#e0e0e0;}\
                h2{color:#f44336;}p{color:#999;}</style></head>\
                <body><h2>Authentication Failed</h2>\
                <p>\(errorMessage)</p></body></html>
                """
                self.sendHTTPResponse(connection: connection, statusCode: 400, html: html)
                self.stop()
                self.continuation?.resume(throwing: OEStorageProviderError.authenticationFailed(
                    underlying: NSError(
                        domain: "org.openemu.CloudStorage",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: errorMessage]
                    )
                ))
                self.continuation = nil
            }
        }
    }
    
    /// Parse query parameters from an HTTP request line.
    /// Expects format: `GET /path?key=value&key2=value2 HTTP/1.1`
    private func parseQueryParameters(from request: String) -> [String: String] {
        guard let queryStart = request.range(of: "?"),
              let queryEnd = request.range(of: " HTTP/", range: queryStart.upperBound..<request.endIndex)
        else { return [:] }
        
        let queryString = String(request[queryStart.upperBound..<queryEnd.lowerBound])
        
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                params[key] = value
            }
        }
        return params
    }
    
    private func sendHTTPResponse(connection: NWConnection, statusCode: Int, html: String) {
        let statusText = statusCode == 200 ? "OK" : "Bad Request"
        let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}
