/// ServiceSearchProvider.swift — Searches public music APIs and constructs Sonos-playable BrowseItems.
///
/// Uses iTunes Search API (free, no auth) to find tracks, artists, and albums on Apple Music.
/// Results are returned as BrowseItems with x-sonos-http URIs that the speaker can play
/// if Apple Music is connected via the Sonos app.
import Foundation

public enum ServiceSearchEntity: String, CaseIterable, Sendable {
    case all = "All"
    case song = "Songs"
    case album = "Albums"
    case artist = "Artists"

    var iTunesEntity: String {
        switch self {
        case .all: return "song"  // iTunes "all" isn't great; songs give broadest useful results
        case .song: return "song"
        case .album: return "album"
        case .artist: return "musicArtist"
        }
    }
}

public final class ServiceSearchProvider {
    public static let shared = ServiceSearchProvider()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Apple Music (iTunes Search API)

    /// Search Apple Music via the iTunes Search API.
    /// For `.all`, searches songs + albums concurrently.
    public func searchAppleMusic(query: String, entity: ServiceSearchEntity, sn: Int, limit: Int = 25) async -> [BrowseItem] {
        if entity == .all {
            async let songs = fetchiTunes(query: query, entity: .song, sn: sn, limit: 20)
            async let albums = fetchiTunes(query: query, entity: .album, sn: sn, limit: 10)
            let (s, a) = await (songs, albums)
            return a + s  // Albums first, then songs
        }
        return await fetchiTunes(query: query, entity: entity, sn: sn, limit: limit)
    }

    private func fetchiTunes(query: String, entity: ServiceSearchEntity, sn: Int, limit: Int) async -> [BrowseItem] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity.iTunesEntity)&limit=\(limit)") else {
            return []
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            let sid = ServiceID.appleMusic
            let serviceType = (sid << 8) + 7  // 52231

            switch entity {
            case .song, .all:
                return parseSongResults(results, sid: sid, serviceType: serviceType, sn: sn)
            case .album:
                return parseAlbumResults(results, sid: sid, serviceType: serviceType, sn: sn)
            case .artist:
                return parseArtistResults(results)
            }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] Apple Music search failed: \(error)")
            return []
        }
    }

    // MARK: - Result Parsers

    private func parseSongResults(_ results: [[String: Any]], sid: Int, serviceType: Int, sn: Int) -> [BrowseItem] {
        results.compactMap { result in
            guard let trackId = result["trackId"] as? Int,
                  let trackName = result["trackName"] as? String,
                  let artistName = result["artistName"] as? String else {
                return nil
            }

            let albumName = result["collectionName"] as? String ?? ""
            let collectionId = result["collectionId"] as? Int ?? 0
            let artURL = upscaleArt(result["artworkUrl100"] as? String)

            let resourceURI = "x-sonos-http:song%3a\(trackId).mp4?sid=\(sid)&flags=8224&sn=\(sn)"
            let metadata = buildTrackDIDL(trackId: trackId, collectionId: collectionId, title: trackName, artist: artistName, album: albumName, serviceType: serviceType)

            return BrowseItem(
                id: "apple:\(trackId)",
                title: trackName,
                artist: artistName,
                album: albumName,
                albumArtURI: artURL,
                itemClass: .musicTrack,
                resourceURI: resourceURI,
                resourceMetadata: metadata
            )
        }
    }

    private func parseAlbumResults(_ results: [[String: Any]], sid: Int, serviceType: Int, sn: Int) -> [BrowseItem] {
        results.compactMap { result in
            guard let collectionId = result["collectionId"] as? Int,
                  let collectionName = result["collectionName"] as? String,
                  let artistName = result["artistName"] as? String else {
                return nil
            }

            let artURL = upscaleArt(result["artworkUrl100"] as? String)

            // Album container URI
            let resourceURI = "x-rincon-cpcontainer:1006206calbum%3a\(collectionId)?sid=\(sid)&flags=8300&sn=\(sn)"
            let metadata = buildAlbumDIDL(collectionId: collectionId, title: collectionName, artist: artistName, serviceType: serviceType)

            return BrowseItem(
                id: "apple:album:\(collectionId)",
                title: collectionName,
                artist: artistName,
                album: "",
                albumArtURI: artURL,
                itemClass: .musicAlbum,
                resourceURI: resourceURI,
                resourceMetadata: metadata
            )
        }
    }

    private func parseArtistResults(_ results: [[String: Any]]) -> [BrowseItem] {
        // Artist results are informational — no direct playback URI
        results.compactMap { result in
            guard let artistId = result["artistId"] as? Int,
                  let artistName = result["artistName"] as? String else {
                return nil
            }

            let artURL = upscaleArt(result["artworkUrl100"] as? String)
            let genre = result["primaryGenreName"] as? String ?? ""

            return BrowseItem(
                id: "apple:artist:\(artistId)",
                title: artistName,
                artist: genre,
                album: "",
                albumArtURI: artURL,
                itemClass: .musicArtist,
                resourceURI: nil,
                resourceMetadata: nil
            )
        }
    }

    // MARK: - DIDL Builders

    private func buildTrackDIDL(trackId: Int, collectionId: Int, title: String, artist: String, album: String, serviceType: Int) -> String {
        """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="00032020song%3a\(trackId)" parentID="0004206calbum%3a\(collectionId)" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><dc:creator>\(xmlEscape(artist))</dc:creator><upnp:album>\(xmlEscape(album))</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>
        """
    }

    private func buildAlbumDIDL(collectionId: Int, title: String, artist: String, serviceType: Int) -> String {
        """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="1006206calbum%3a\(collectionId)" parentID="" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><dc:creator>\(xmlEscape(artist))</dc:creator><upnp:class>object.container.album.musicAlbum</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>
        """
    }

    // MARK: - Helpers

    private func upscaleArt(_ url: String?) -> String? {
        url?.replacingOccurrences(of: "100x100", with: "600x600")
           .replacingOccurrences(of: "60x60", with: "600x600")
    }

    private func xmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
