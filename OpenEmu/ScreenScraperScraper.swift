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

import Foundation

/// Queries the ScreenScraper.fr API for game metadata and artwork.
/// Synchronous calls intended for use from the OpenVGDB sync thread.
final class ScreenScraperScraper {

    private static let baseURL = "https://www.screenscraper.fr/api2/"
    private static let softName = "OpenEmu"

    // MARK: - System ID Mapping

    /// Maps OpenEmu system identifiers to ScreenScraper system IDs.
    private static let systemIDMap: [String: Int] = [
        "openemu.system.nes":           3,
        "openemu.system.snes":          4,
        "openemu.system.n64":           14,
        "openemu.system.gb":            9,
        "openemu.system.gba":           12,
        "openemu.system.nds":           15,
        "openemu.system.gc":            13,
        "openemu.system.wii":           16,
        "openemu.system.fds":           106,
        "openemu.system.vb":            11,
        "openemu.system.sg":            1,
        "openemu.system.sms":           2,
        "openemu.system.gg":            21,
        "openemu.system.32x":           19,
        "openemu.system.scd":           20,
        "openemu.system.saturn":        22,
        "openemu.system.dc":            23,
        "openemu.system.sg1000":        109,
        "openemu.system.psx":           57,
        "openemu.system.ps2":           58,
        "openemu.system.psp":           61,
        "openemu.system.pce":           31,
        "openemu.system.pcecd":         114,
        "openemu.system.pcfx":          72,
        "openemu.system.2600":          26,
        "openemu.system.5200":          40,
        "openemu.system.7800":          41,
        "openemu.system.lynx":          28,
        "openemu.system.jaguar":        27,
        "openemu.system.atari8bit":     43,
        "openemu.system.colecovision":  48,
        "openemu.system.intellivision": 115,
        "openemu.system.vectrex":       102,
        "openemu.system.odyssey2":      104,
        "openemu.system.ngp":           25,
        "openemu.system.ws":            45,
        "openemu.system.c64":           66,
        "openemu.system.msx":           113,
        "openemu.system.3do":           29,
        "openemu.system.arcade":        75,
        "openemu.system.pokemonmini":   211,
        "openemu.system.sv":            207,
    ]

    // MARK: - Developer Credentials

    private static var devCredentials: (devid: String, devpassword: String)? = {
        guard let url = Bundle.main.url(forResource: "CloudSecrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String],
              let devid = dict["ScreenScraperDevID"],
              let devpw = dict["ScreenScraperDevPassword"]
        else {
            NSLog("[ScreenScraperScraper] Missing developer credentials in CloudSecrets.plist")
            return nil
        }
        return (devid, devpw)
    }()

    // MARK: - Rate Limiting

    private static let minimumRequestInterval: TimeInterval = 1.2
    private static var lastRequestTime: Date = .distantPast
    private static let rateLimitLock = NSLock()

    private static func waitForRateLimit() {
        rateLimitLock.lock()
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minimumRequestInterval {
            Thread.sleep(forTimeInterval: minimumRequestInterval - elapsed)
        }
        lastRequestTime = Date()
        rateLimitLock.unlock()
    }

    // MARK: - Public API

    /// Look up game info from ScreenScraper by MD5 hash and system.
    /// Returns a dictionary with keys: "gameTitle", "boxImageURL", "gameDescription".
    /// Returns nil if not found or on error.
    static func gameInfo(
        md5: String?,
        systemIdentifier: String,
        romFileName: String?,
        romFileSize: Int?
    ) -> [String: Any]? {

        guard let devCreds = devCredentials else { return nil }
        guard let ssSystemID = systemIDMap[systemIdentifier] else {
            NSLog("[ScreenScraperScraper] No system ID mapping for: %@", systemIdentifier)
            return nil
        }

        var params: [URLQueryItem] = [
            URLQueryItem(name: "devid", value: devCreds.devid),
            URLQueryItem(name: "devpassword", value: devCreds.devpassword),
            URLQueryItem(name: "softname", value: softName),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "systemeid", value: "\(ssSystemID)"),
        ]

        // Add user credentials if available (for higher rate limits)
        let userCreds = ScreenScraperCredentialStore.shared
        if let username = userCreds.username, let password = userCreds.password {
            params.append(URLQueryItem(name: "ssid", value: username))
            params.append(URLQueryItem(name: "sspassword", value: password))
        }

        // Identification params
        if let md5 = md5, !md5.isEmpty {
            params.append(URLQueryItem(name: "md5", value: md5))
        }
        if let romFileName = romFileName, !romFileName.isEmpty {
            params.append(URLQueryItem(name: "romnom", value: romFileName))
        }
        if let romFileSize = romFileSize, romFileSize > 0 {
            params.append(URLQueryItem(name: "romtaille", value: "\(romFileSize)"))
        }

        var components = URLComponents(string: "\(baseURL)jeuInfos.php")!
        components.queryItems = params

        guard let url = components.url else { return nil }

        waitForRateLimit()

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard resultError == nil,
              let data = resultData,
              let httpResponse = resultResponse as? HTTPURLResponse
        else {
            NSLog("[ScreenScraperScraper] Request failed: %@", resultError?.localizedDescription ?? "unknown")
            return nil
        }

        switch httpResponse.statusCode {
        case 429:
            NSLog("[ScreenScraperScraper] Thread limit reached (429)")
            Thread.sleep(forTimeInterval: 5.0)
            return nil
        case 430:
            NSLog("[ScreenScraperScraper] Daily quota exceeded (430)")
            return nil
        case 431:
            NSLog("[ScreenScraperScraper] Too many unrecognized requests (431)")
            return nil
        case 200:
            break
        default:
            NSLog("[ScreenScraperScraper] HTTP %d", httpResponse.statusCode)
            return nil
        }

        return parseGameInfo(from: data)
    }

    // MARK: - Response Parsing

    private static func parseGameInfo(from data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let jeu = response["jeu"] as? [String: Any]
        else { return nil }

        var result: [String: Any] = [:]

        // Game title: prefer region-specific name
        if let noms = jeu["noms"] as? [[String: Any]] {
            let preferredRegions = ["us", "wor", "eu", "jp"]
            var title: String?
            for region in preferredRegions {
                if let nom = noms.first(where: { ($0["region"] as? String) == region }) {
                    title = nom["text"] as? String
                    break
                }
            }
            if title == nil {
                title = noms.first?["text"] as? String
            }
            if let title = title {
                result["gameTitle"] = title
            }
        }

        // Description: prefer English synopsis
        if let synopses = jeu["synopsis"] as? [[String: Any]] {
            let preferredLanguages = ["en", "us", "eu"]
            var description: String?
            for lang in preferredLanguages {
                if let syn = synopses.first(where: { ($0["langue"] as? String) == lang }) {
                    description = syn["text"] as? String
                    break
                }
            }
            if description == nil {
                description = synopses.first?["text"] as? String
            }
            if let description = description {
                result["gameDescription"] = description
            }
        }

        // Box art URL: prefer box-2D for US/World region
        if let medias = jeu["medias"] as? [[String: Any]] {
            let preferredRegions = ["us", "wor", "eu", "jp"]
            var boxURL: String?

            // Try box-2D first (front cover)
            for region in preferredRegions {
                if let media = medias.first(where: {
                    ($0["type"] as? String) == "box-2D" &&
                    ($0["region"] as? String) == region
                }) {
                    boxURL = media["url"] as? String
                    break
                }
            }

            // Fall back to any box-2D
            if boxURL == nil {
                boxURL = medias.first(where: { ($0["type"] as? String) == "box-2D" })?["url"] as? String
            }

            // Fall back to box-3D
            if boxURL == nil {
                boxURL = medias.first(where: { ($0["type"] as? String) == "box-3D" })?["url"] as? String
            }

            // Final fallback: screenshot or mix
            if boxURL == nil {
                boxURL = medias.first(where: { ($0["type"] as? String) == "mixrbv1" })?["url"] as? String
            }

            if let boxURL = boxURL {
                result["boxImageURL"] = boxURL
            }
        }

        return result.isEmpty ? nil : result
    }
}
