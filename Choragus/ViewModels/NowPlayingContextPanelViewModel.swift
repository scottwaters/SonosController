/// NowPlayingContextPanelViewModel.swift — Owns the About + History
/// tab state for the Now Playing context panel. Lyrics state moved to
/// `LyricsCoordinator` so the inline panel and the karaoke popout
/// window share one source of truth (resolved lyrics, parse cache,
/// load status, user offset).
import Foundation
import SonosKit

/// State of one async metadata fetch (about).
enum ContextLoadState: Equatable {
    case idle, loading, loaded, missing
    case error(String)

    static func == (lhs: ContextLoadState, rhs: ContextLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading),
             (.loaded, .loaded), (.missing, .missing):
            return true
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}

@MainActor
@Observable
final class NowPlayingContextPanelViewModel {
    // MARK: - About state
    var artistInfo: ArtistInfo?
    var albumInfo: AlbumInfo?
    var aboutState: ContextLoadState = .idle

    // MARK: - Dependencies
    private let lyricsCoordinator: LyricsCoordinator
    private let metadataService: MusicMetadataService

    init(lyricsCoordinator: LyricsCoordinator, metadataService: MusicMetadataService) {
        self.lyricsCoordinator = lyricsCoordinator
        self.metadataService = metadataService
    }

    // MARK: - Lifecycle

    /// Reset all per-track state for a new track. The coordinator owns
    /// the per-track lyrics + offset memoisation, so this only clears
    /// the About fetch state.
    func resetForNewTrack(_ metadata: TrackMetadata) {
        artistInfo = nil
        albumInfo = nil
        aboutState = .idle
    }

    /// Loads whichever tab is currently active, then pre-warms the
    /// other one in the background so tab switches are instant.
    func loadActiveTab(
        _ tab: NowPlayingContextPanelTab,
        metadata: TrackMetadata
    ) async {
        guard !metadata.title.isEmpty else { return }
        switch tab {
        case .lyrics:
            // Coordinator handles its own idempotent fetch.
            lyricsCoordinator.loadIfNeeded(for: metadata)
        case .about:   await loadAbout(metadata)
        case .history: break
        }
        warmInactiveTabCaches(active: tab, metadata: metadata)
    }

    /// Drops the cached artist + album entries for this track and
    /// re-runs the About fetch. Wired to the right-click context menu
    /// so users can pull updated info without waiting for the 30-day
    /// cache TTL.
    func refreshAbout(_ metadata: TrackMetadata) async {
        guard !metadata.title.isEmpty else { return }
        if !metadata.artist.isEmpty {
            metadataService.invalidateArtist(name: metadata.artist)
        }
        if !metadata.album.isEmpty {
            metadataService.invalidateAlbum(artist: metadata.artist, album: metadata.album)
        }
        artistInfo = nil
        albumInfo = nil
        aboutState = .idle
        await loadAbout(metadata)
    }

    // MARK: - Private loaders

    private func loadAbout(_ metadata: TrackMetadata) async {
        if case .loaded = aboutState { return }
        if case .loading = aboutState { return }
        // On radio, the `artist` field frequently carries the station or
        // soundtrack name rather than the actual performing artist (e.g.
        // station "Movie Ticket Radio" reports artist="Animal House").
        // Sending that to Wikipedia / MusicBrainz / Last.fm reliably
        // produces unrelated articles. Render an empty About card
        // instead — matches user preference: "if Wikipedia doesn't have
        // a solid result, don't show anything".
        if metadata.isRadioStream || !metadata.stationName.isEmpty {
            let artistField = metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let stationField = metadata.stationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let artistMatchesStation = !stationField.isEmpty &&
                artistField.caseInsensitiveCompare(stationField) == .orderedSame
            if artistField.isEmpty || artistMatchesStation {
                artistInfo = nil
                albumInfo = nil
                aboutState = .loaded
                return
            }
        }
        aboutState = .loading
        async let artistTask = metadataService.artistInfo(name: metadata.artist)
        async let albumTask: AlbumInfo? = metadata.album.isEmpty
            ? nil
            : metadataService.albumInfo(artist: metadata.artist, album: metadata.album)
        artistInfo = await artistTask
        albumInfo = await albumTask
        aboutState = .loaded
    }

    /// Fire-and-forget background fetches for the inactive tab(s) so
    /// the cache is hot when the user switches tabs.
    private func warmInactiveTabCaches(
        active: NowPlayingContextPanelTab,
        metadata: TrackMetadata
    ) {
        guard !metadata.title.isEmpty else { return }
        let metadataRef = metadataService
        let coordinator = lyricsCoordinator
        let artist = metadata.artist
        let album = metadata.album

        if active != .lyrics {
            // Coordinator's loadIfNeeded is idempotent and cheap on hit.
            coordinator.loadIfNeeded(for: metadata)
        }
        if active != .about {
            Task {
                _ = await metadataRef.artistInfo(name: artist)
                if !album.isEmpty {
                    _ = await metadataRef.albumInfo(artist: artist, album: album)
                }
            }
        }
    }
}

/// Tabs in the context panel — defined here (not nested inside the
/// View) so the ViewModel can take them as a parameter without
/// pulling in SwiftUI.
enum NowPlayingContextPanelTab: String, CaseIterable, Identifiable {
    case lyrics = "Lyrics"
    case about = "About"
    case history = "History"
    var id: String { rawValue }

    /// Localised label rendered in the segmented picker. The raw value
    /// is kept stable as a stringly-typed identifier so it can be
    /// persisted / logged without going through the L10n layer.
    var displayName: String {
        switch self {
        case .lyrics:  return L10n.tabLyrics
        case .about:   return L10n.tabAbout
        case .history: return L10n.tabHistory
        }
    }
}
