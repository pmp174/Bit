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

/// Queries the Flashpoint database API to find box art for imported Flash games.
final class FlashpointArtScraper {

    private static let baseURL = "https://db-api.unstable.life"

    private struct SearchResult: Decodable {
        let id: String
        let title: String
    }

    /// Search Flashpoint by title and return a logo image URL for the best match.
    /// This is a synchronous call intended to be used from the OpenVGDB sync thread.
    static func fetchArtURL(forGameTitle title: String) -> URL? {
        guard !title.isEmpty,
              let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "\(baseURL)/search?platform=Flash&title=\(encoded)")
        else { return nil }

        var request = URLRequest(url: searchURL)
        request.timeoutInterval = 10

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
              let httpResponse = resultResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            NSLog("[FlashpointArtScraper] API request failed for title: %@", title)
            return nil
        }

        guard let results = try? JSONDecoder().decode([SearchResult].self, from: data),
              !results.isEmpty
        else { return nil }

        // Find best match: prefer exact (case-insensitive) title match, else first result
        let normalizedTitle = title.lowercased()
        let bestMatch = results.first(where: { $0.title.lowercased() == normalizedTitle }) ?? results[0]

        // Return the logo endpoint URL; the sync pipeline will download it via OEDBImage.prepareImage()
        return URL(string: "\(baseURL)/logo?id=\(bestMatch.id)")
    }
}
