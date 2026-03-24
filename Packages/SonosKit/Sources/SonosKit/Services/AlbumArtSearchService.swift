/// AlbumArtSearchService.swift — Fetches album art from iTunes Search API.
///
/// Used as a fallback when Sonos doesn't provide album art.
/// Supports album searches, artist searches, and combined searches.
/// No API key required. Results are cached in memory to avoid repeat lookups.
import Foundation

public final class AlbumArtSearchService {
    public static let shared = AlbumArtSearchService()

    private let session: URLSession
    private var cache: [String: String?] = [:] // cacheKey -> artURL (nil = not found)
    private let cacheLock = NSLock()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    /// Searches iTunes for album art. Tries multiple strategies:
    /// 1. Album search with artist + title
    /// 2. Album search with just title
    /// 3. Artist search (for artist-level containers)
    public func searchArtwork(artist: String, album: String) async -> String? {
        let cacheKey = "art:\(artist.lowercased())|\(album.lowercased())"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Strategy 1: Combined artist + album search
        if !artist.isEmpty && !album.isEmpty {
            if let url = await iTunesSearch(query: "\(artist) \(album)", entity: "album") {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 2: Album-only search
        if !album.isEmpty {
            if let url = await iTunesSearch(query: album, entity: "album") {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 3: Artist search (returns artist image)
        let artistQuery = !artist.isEmpty ? artist : album
        if !artistQuery.isEmpty {
            if let url = await iTunesSearch(query: artistQuery, entity: "musicArtist") {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 4: Broad song search (might find artwork from a popular track)
        if !album.isEmpty {
            if let url = await iTunesSearch(query: album, entity: "song") {
                cacheSet(cacheKey, url)
                return url
            }
        }

        cacheSet(cacheKey, nil)
        return nil
    }

    private func cacheSet(_ key: String, _ value: String?) {
        cacheLock.lock()
        cache[key] = value
        cacheLock.unlock()
    }

    /// Low-level iTunes Search API call
    private func iTunesSearch(query: String, entity: String) async -> String? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity)&limit=1") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first else {
                return nil
            }

            // Different entities return art in different fields
            let artURL = first["artworkUrl100"] as? String ??
                         first["artworkUrl60"] as? String ??
                         first["artworkUrl30"] as? String
            guard let art = artURL else { return nil }

            return art.replacingOccurrences(of: "100x100", with: "600x600")
                      .replacingOccurrences(of: "60x60", with: "600x600")
                      .replacingOccurrences(of: "30x30", with: "600x600")
        } catch {
            return nil
        }
    }
}
