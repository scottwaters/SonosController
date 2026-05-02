/// ArtResolver.swift — Art display state for the now-playing view.
///
/// Single responsibility: decides which art URL to display based on current
/// state (radio track art, station art, metadata art, web search art).
/// Does NOT do: ad break detection (TrackMetadata.isAdBreak), DIDL parsing
/// (TrackMetadata.enrichFromDIDL), or search orchestration (NowPlayingViewModel).
///
/// `@Observable` so SwiftUI re-renders when async art-search results
/// land in `radioTrackArtURL`/`webArtURL`/`displayedArtURL`. Without
/// this, the view binds to `NowPlayingViewModel` only and never gets
/// notified when ArtResolver state mutates after a metadata-driven
/// search finishes — the symptom: art shows correctly on app load
/// (initial render coincides with cached state) but stays stale across
/// in-session track changes.
import Foundation
import Observation
import AppKit
import SonosKit

@MainActor
@Observable
final class ArtResolver {
    // MARK: - Display State

    var displayedArtURL: URL?
    var radioTrackArtURL: URL?
    /// `title|artist` key the current `radioTrackArtURL` was resolved
    /// for. Compared against the *current* track's key in
    /// `artURLForDisplay` so a stale URL from the previous song doesn't
    /// keep displaying after the track has changed but before the next
    /// iTunes lookup completes (or fails). nil means the URL hasn't
    /// been associated with a specific track key yet.
    var radioTrackArtKey: String?
    var radioStationArtURL: URL?
    var webArtURL: URL?
    var forceWebArt = false

    /// Radio track-art held over from the previous song so the display
    /// doesn't snap to the station logo during the brief window between
    /// "new song started" and "iTunes search returned art for it".
    /// Set when a real track changeover is detected on radio (see
    /// `handleTrackURIChanged`); cleared when the next track's art
    /// resolves or when `radioGraceDeadline` passes.
    var previousRadioTrackArtURL: URL?

    /// Wall-clock cutoff for honouring `previousRadioTrackArtURL`. Past
    /// this point the held art releases and the display falls back to
    /// the station logo. Sized so legitimate iTunes searches finish
    /// inside the window but a real station ID lands on the station
    /// logo within seconds rather than holding stale song art.
    var radioGraceDeadline: Date?

    /// Sleep task that nils `previousRadioTrackArtURL` and
    /// `radioGraceDeadline` once the deadline passes. Cancelled on
    /// every re-arm and on every `setRadioTrackArt` call so concurrent
    /// track flips don't compound.
    @ObservationIgnored
    private var radioGraceCleanupTask: Task<Void, Never>?

    /// Grace-window length, in seconds. Tuned so most iTunes radio-
    /// track searches finish inside it but a station-ID gap doesn't
    /// hold the prior song's art for an obviously-wrong duration.
    private static let radioGraceWindow: TimeInterval = 8.0

    // MARK: - Dedup Keys

    var lastArtSearchKey = ""

    /// Per-track-URI canonical art decisions.
    ///
    /// ArtResolver is the single source of truth for which URL the view
    /// displays. Once we resolve a URL for a track URI, we pin it here
    /// and return the same URL for every subsequent `artURLForDisplay`
    /// call until the track URI changes or the user explicitly acts
    /// (Search Artwork / Refresh / Ignore / Clear).
    ///
    /// Historically the pipeline had five places that could touch art
    /// (SonosManager cache substitution, PlayHistoryManager iTunes search,
    /// NowPlayingViewModel.searchWebArtIfNeeded, AVTransport /getaa?
    /// fallback, ArtResolver.resolveArtURL). They raced, and the view
    /// saw different URLs across adjacent polls — visible flicker
    /// (Virgin Suicides Redux vs Original). This cache pins one answer.
    ///
    /// Keyed by `trackMetadata.trackURI` (or title|artist if URI is
    /// missing). A nil value means "resolved to no art" so we don't
    /// keep attempting to resolve.
    private var pinnedArtByTrackURI: [String: URL?] = [:]

    /// Back-compat shim for existing call sites. Backed by `pinnedArtByTrackURI`.
    private var artResolvedTrackURIs: Set<String> {
        Set(pinnedArtByTrackURI.keys)
    }
    var lastTrackURI = ""
    var lastTrackTitle = ""
    var lastTrackArtist = ""
    var lastRadioTrackKey = ""
    var lastStationName = ""

    // MARK: - Dependencies

    private(set) weak var playHistoryManager: PlayHistoryManager?
    private let albumArtSearch: AlbumArtSearchProtocol

    init(playHistoryManager: PlayHistoryManager? = nil,
         albumArtSearch: AlbumArtSearchProtocol = AlbumArtSearchService.shared) {
        self.playHistoryManager = playHistoryManager
        self.albumArtSearch = albumArtSearch
    }

    // MARK: - Display Resolution

    /// Returns the URL that should be displayed as album art right now.
    /// Priority: forced web art > radio track art > metadata art > web search art > station art.
    func resolveArtURL(trackMetadata: TrackMetadata, group: SonosGroup) -> URL? {
        let isLocalFile = trackMetadata.trackURI.map(URIPrefix.isLocal) ?? false
        let artURI = trackMetadata.albumArtURI ?? localFileArtURL(trackMetadata: trackMetadata, group: group)
        if forceWebArt {
            return webArtURL ?? artURI.flatMap { URL(string: $0) }
        } else if isLocalFile && webArtURL != nil {
            return webArtURL
        } else {
            return artURI.flatMap { URL(string: $0) } ?? webArtURL
        }
    }

    /// Updates displayedArtURL from current state. Handles station changes.
    func updateDisplayedArt(trackMetadata: TrackMetadata, group: SonosGroup) {
        let currentStation = trackMetadata.stationName
        let onRadio = !currentStation.isEmpty || trackMetadata.isRadioStream

        // Station changed — clear stale radio art. Two cases trigger a
        // genuine change:
        //   1. Incoming `currentStation` is non-empty AND differs from
        //      `lastStationName` (real switch to a different station).
        //   2. We've truly LEFT radio (lastStationName non-empty, current
        //      empty, AND `onRadio` is false — no longer a radio stream).
        // Transient empty `stationName` while still on the same station
        // (Sonos's metadata polls occasionally drop the field for a frame)
        // must NOT clear `radioTrackArtURL`, or the auto-resolved track
        // art flicks back to the station logo for the next render.
        let realStationChange: Bool
        if !currentStation.isEmpty {
            realStationChange = currentStation != lastStationName
        } else {
            realStationChange = !lastStationName.isEmpty && !onRadio
        }
        if realStationChange {
            let wasRadio = !lastStationName.isEmpty
            lastStationName = currentStation
            radioStationArtURL = nil
            radioTrackArtURL = nil
            lastRadioTrackKey = ""
            if wasRadio || onRadio {
                displayedArtURL = nil
                webArtURL = nil
            }
        }

        // Capture station art — try metadata art first, then current displayed art
        if onRadio && radioStationArtURL == nil {
            if let metaArt = trackMetadata.albumArtURI, !metaArt.isEmpty, let url = URL(string: metaArt) {
                radioStationArtURL = url
            } else if let displayed = displayedArtURL {
                radioStationArtURL = displayed
            }
        }

        // During ad breaks, show station art — don't update displayedArtURL
        if trackMetadata.isAdBreak {
            radioTrackArtURL = nil
            lastRadioTrackKey = ""
            return
        }

        let resolved = resolveArtURL(trackMetadata: trackMetadata, group: group)
        if resolved != displayedArtURL {
            if resolved == nil && displayedArtURL != nil {
                if onRadio { return }
                let currentURI = trackMetadata.trackURI ?? ""
                if currentURI == lastTrackURI { return }
            }
            displayedArtURL = resolved
        }
        // Auto-pin the first non-`/getaa?` art we see for this track.
        // For direct-stream playback (Plex direct, custom HTTP) the
        // first frame carries the real upstream URL we provided in DIDL,
        // and subsequent speaker polls rewrite it to a `/getaa?` proxy
        // that returns generic placeholder art when the upstream isn't
        // fetchable speaker-side. Pinning the original means
        // `artURLForDisplay` can prefer it over the broken proxy.
        if !isArtResolved(for: trackMetadata),
           !onRadio,
           let url = resolved,
           !url.absoluteString.contains("/getaa?") {
            markArtResolved(for: trackMetadata, url: url)
        }
    }

    /// The art URL the view should show — accounts for ad breaks and ignore state.
    ///
    /// Canonical return value: once a track URI is pinned in
    /// `pinnedArtByTrackURI`, this always returns that URL for that
    /// track regardless of other state changes. User actions
    /// (invalidateArtResolution) are the only way the answer changes.
    func artURLForDisplay(trackMetadata: TrackMetadata) -> URL? {
        if isArtIgnored { return nil }
        if trackMetadata.isAdBreak {
            return radioStationArtURL
        }
        if isArtResolved(for: trackMetadata) {
            // User's manual override wins over radio auto-search. A pin
            // exists here only because `setManualArtwork` (or another
            // explicit user action) called `markArtResolved` — radio
            // auto-search results never pin. So if a pin is present
            // while on radio, it's an explicit user choice and must
            // beat `radioTrackArtURL`, which gets re-populated on
            // subsequent polls and would otherwise reclobber the choice.
            if !trackMetadata.stationName.isEmpty,
               let pin = pinnedURL(for: trackMetadata) {
                return pin
            }
            if let trackArt = radioTrackArtURL, !trackMetadata.stationName.isEmpty,
               radioTrackArtKeyMatches(trackMetadata) {
                return trackArt
            }
            let metaArtString = trackMetadata.albumArtURI ?? ""
            let metaIsGetaa = metaArtString.contains("/getaa?")
            // Direct-stream playback (Plex direct, custom HTTP) goes
            // through Sonos's `/getaa?` art proxy when echoed back from
            // the speaker. The proxy returns a generic placeholder
            // when it can't fetch the upstream URL (HTTPS .plex.direct
            // + token, auth-required URLs). If we have a real pinned
            // URL, prefer it over the proxy regardless of whether the
            // proxy URL is "non-empty".
            if metaIsGetaa,
               let pin = pinnedURL(for: trackMetadata),
               !pin.absoluteString.contains("/getaa?") {
                return pin
            }
            // Speaker's current albumArtURI is the source of truth — read it
            // directly so the inline view stays in sync with menubar/popup.
            if !metaArtString.isEmpty, let url = URL(string: metaArtString) {
                return url
            }
            // Speaker reports no art for this track. A pinned /getaa? URL
            // is almost always stale here (queue-advance transitions can
            // briefly leak the previous track's /getaa URL into metadata
            // before Sonos refreshes its internal art; that frame can pin
            // the wrong URL). A non-/getaa pin is a legitimate iTunes
            // result for a track without speaker art — keep that.
            if let pin = pinnedURL(for: trackMetadata),
               !pin.absoluteString.contains("/getaa?") {
                return pin
            }
            return radioStationArtURL
        }
        if let trackArt = radioTrackArtURL, !trackMetadata.stationName.isEmpty,
           radioTrackArtKeyMatches(trackMetadata) {
            return trackArt
        }
        // Radio grace window: hold the prior song's art while the new
        // song's iTunes search is in flight. Released as soon as
        // `setRadioTrackArt` lands or the deadline expires.
        if !trackMetadata.stationName.isEmpty,
           let held = previousRadioTrackArtURL,
           let deadline = radioGraceDeadline,
           Date() < deadline {
            return held
        }
        return displayedArtURL ?? radioStationArtURL
    }

    /// True when the current `radioTrackArtURL` was resolved for the
    /// currently-displayed track. Compares titles only — radio metadata
    /// arrives in stages (title first, artist may fill in later), so an
    /// `artist|title`-strict comparison would reject correct art when
    /// the artist field finalises after the search completed. The title
    /// is the stable per-song identifier; artist drift inside the same
    /// title is treated as the same song. A nil `radioTrackArtKey`
    /// means the URL was set without a key (legacy callers / pre-fix
    /// state) — we trust those.
    private func radioTrackArtKeyMatches(_ trackMetadata: TrackMetadata) -> Bool {
        guard let stored = radioTrackArtKey else { return true }
        let storedTitle = stored
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let currentTitle = trackMetadata.title
        guard !storedTitle.isEmpty, !currentTitle.isEmpty else { return false }
        return storedTitle.caseInsensitiveCompare(currentTitle) == .orderedSame
    }

    /// Whether to show the station badge overlay.
    func shouldShowStationBadge(trackMetadata: TrackMetadata) -> Bool {
        guard let _ = radioTrackArtURL,
              let stationArt = radioStationArtURL,
              !trackMetadata.isAdBreak else { return false }
        return stationArt != radioTrackArtURL && stationArt != displayedArtURL
    }

    // MARK: - Track Change Handling

    func handleTrackURIChanged(trackMetadata: TrackMetadata, group: SonosGroup) {
        let currentURI = trackMetadata.trackURI ?? trackMetadata.title
        // Radio HLS streams keep the same trackURI for the whole
        // session — different songs come down the same stream URL.
        // The bare `currentURI != lastTrackURI` gate misses these
        // intra-stream song changes, which means the grace window
        // below never arms and the display falls to the station logo
        // for the metadata-loading frame. Treat a title change on a
        // stable radio URI as a track change as well.
        let onRadio = !trackMetadata.stationName.isEmpty || trackMetadata.isRadioStream
        let titleChangedOnSameRadioURI =
            onRadio &&
            currentURI == lastTrackURI &&
            !trackMetadata.title.isEmpty &&
            trackMetadata.title != lastTrackTitle
        guard (currentURI != lastTrackURI || titleChangedOnSameRadioURI),
              !currentURI.isEmpty
        else { return }
        let previousTitle = lastTrackTitle
        let previousArtist = lastTrackArtist
        let previouslyResolvedRadioArt = radioTrackArtURL
        lastTrackURI = currentURI
        lastTrackTitle = trackMetadata.title
        lastTrackArtist = trackMetadata.artist
        // Same song but URI rotated (common with radio HLS streams) — keep radio art
        let sameSong = !trackMetadata.title.isEmpty &&
                       trackMetadata.title == previousTitle &&
                       trackMetadata.artist == previousArtist
        if sameSong { return }
        // New track — reset all overrides
        isArtIgnored = false
        forceWebArt = false
        webArtURL = nil
        // Don't clear radioTrackArtURL here. For radio streams, clearing it now
        // forces a brief revert to station art during the ~1 s window it takes
        // for searchRadioTrackArt to return iTunes results, producing a visible
        // flicker (old track art → station art → new track art). Instead, let
        // searchRadioTrackArt update it when the new result arrives, or clear
        // it explicitly if iTunes returns no match or the track leaves radio.
        lastArtSearchKey = ""
        displayedArtURL = trackMetadata.albumArtURI.flatMap { URL(string: $0) }
        // Restore any persisted override for this specific track
        loadPersistedArtOverride(trackMetadata: trackMetadata, group: group)

        // Radio grace window: hold the previous song's art over the
        // metadata-loading gap so the display doesn't snap to the
        // station logo for the second or two it takes the iTunes search
        // to return. Skipped when the new "track" looks like a station
        // ID (empty title, or title equals station name) — in that case
        // the station logo is the right answer immediately.
        // `onRadio` reuses the value computed at the top of the
        // function for the title-change-on-stable-URI gate.
        let isStationID = trackMetadata.title.isEmpty ||
            (!trackMetadata.stationName.isEmpty &&
             trackMetadata.title.caseInsensitiveCompare(trackMetadata.stationName) == .orderedSame)
        if onRadio, !isStationID, let prior = previouslyResolvedRadioArt {
            armRadioGraceWindow(holding: prior)
        } else {
            cancelRadioGraceWindow()
        }
    }

    /// Captures `prior` as the held-over art and arms the deadline. A
    /// background task fires after `radioGraceWindow` seconds to release
    /// the hold, so views observing `previousRadioTrackArtURL` /
    /// `radioGraceDeadline` get an automatic re-render and fall back to
    /// the station logo when the search fails to land in time.
    private func armRadioGraceWindow(holding prior: URL) {
        previousRadioTrackArtURL = prior
        let deadline = Date().addingTimeInterval(Self.radioGraceWindow)
        radioGraceDeadline = deadline
        radioGraceCleanupTask?.cancel()
        radioGraceCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.radioGraceWindow * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // If a newer arm has bumped the deadline forward, defer to it.
            if let current = self.radioGraceDeadline, current > Date() { return }
            self.previousRadioTrackArtURL = nil
            self.radioGraceDeadline = nil
        }
    }

    /// Releases any held-over radio art immediately. Called when fresh
    /// track art lands (`setRadioTrackArt`) or a definitive non-result
    /// returns from the search.
    private func cancelRadioGraceWindow() {
        radioGraceCleanupTask?.cancel()
        radioGraceCleanupTask = nil
        previousRadioTrackArtURL = nil
        radioGraceDeadline = nil
    }

    // MARK: - Persistence

    /// Sentinel value stored to indicate artwork should be ignored (show generic icon)
    static let ignoreArtMarker = "IGNORE"

    /// Whether artwork is currently being ignored for this track
    var isArtIgnored = false

    func loadPersistedArtOverride(trackMetadata: TrackMetadata, group: SonosGroup) {
        let searchTerm = artOverrideKey(trackMetadata: trackMetadata)
        guard !searchTerm.isEmpty else { return }
        let key = "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())"
        if let saved = UserDefaults.standard.string(forKey: key) {
            if saved == Self.ignoreArtMarker {
                isArtIgnored = true
                webArtURL = nil
                forceWebArt = false
                displayedArtURL = nil
            } else {
                isArtIgnored = false
                webArtURL = URL(string: saved)
                forceWebArt = true
                updateDisplayedArt(trackMetadata: trackMetadata, group: group)
            }
        }
    }

    /// Persists an ignore marker so this track always shows the generic icon
    func ignoreArtwork(trackMetadata: TrackMetadata) {
        let searchTerm = artOverrideKey(trackMetadata: trackMetadata)
        guard !searchTerm.isEmpty else { return }
        let key = "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())"
        UserDefaults.standard.set(Self.ignoreArtMarker, forKey: key)
        isArtIgnored = true
        webArtURL = nil
        forceWebArt = false
        displayedArtURL = nil
        // Explicit user decision — the resolution is fixed now.
        markArtResolved(for: trackMetadata)
    }

    /// Persists a manually chosen art URL and pre-caches the image
    func setManualArtwork(_ artURL: String, trackMetadata: TrackMetadata, group: SonosGroup) {
        let searchTerm = artOverrideKey(trackMetadata: trackMetadata)
        guard !searchTerm.isEmpty else { return }
        let key = "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())"
        UserDefaults.standard.set(artURL, forKey: key)
        isArtIgnored = false
        let chosenURL = URL(string: artURL)
        webArtURL = chosenURL
        forceWebArt = true
        // Clear stale state BEFORE pinning so `markArtResolved`'s fallback
        // (`displayedArtURL ?? webArtURL`) doesn't capture the previous
        // station-logo URL still sitting in displayedArtURL. Better still,
        // pass the chosen URL explicitly — guarantees the pin matches the
        // user's choice regardless of any transient state.
        radioTrackArtURL = nil
        displayedArtURL = chosenURL
        markArtResolved(for: trackMetadata, url: chosenURL)
        updateDisplayedArt(trackMetadata: trackMetadata, group: group)

        // Pre-cache the image so it's available immediately on future plays
        if let url = URL(string: artURL) {
            Task {
                if ImageCache.shared.image(for: url) == nil {
                    if let (data, _) = try? await URLSession.shared.data(from: url),
                       let image = NSImage(data: data) {
                        ImageCache.shared.store(image, for: url)
                    }
                }
            }
        }

        // Update play history artwork for this track
        playHistoryManager?.updateArtwork(
            forTitle: trackMetadata.title, artist: trackMetadata.artist, artURL: artURL)
    }

    /// Consistent key for art override persistence
    func artOverrideKey(trackMetadata: TrackMetadata) -> String {
        !trackMetadata.title.isEmpty ? trackMetadata.title :
        !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
    }

    /// Key used to track a single "resolved" art decision per track.
    /// Falls back to title|artist when trackURI isn't populated (e.g.,
    /// very-early metadata with only DIDL-parsed title/artist).
    func artResolutionKey(trackMetadata: TrackMetadata) -> String {
        if let uri = trackMetadata.trackURI, !uri.isEmpty { return uri }
        return "\(trackMetadata.title)|\(trackMetadata.artist)"
    }

    /// True if the track's art has already been resolved this session and
    /// automatic searches should be skipped.
    func isArtResolved(for trackMetadata: TrackMetadata) -> Bool {
        pinnedArtByTrackURI[artResolutionKey(trackMetadata: trackMetadata)] != nil
    }

    /// Pin the current art decision for this track. Called after any
    /// art-source hop lands a real URL (iTunes search, manual override,
    /// metadata URL, persistent cache hit).
    func markArtResolved(for trackMetadata: TrackMetadata, url: URL? = nil) {
        let key = artResolutionKey(trackMetadata: trackMetadata)
        guard !key.isEmpty else { return }
        sonosDebugLog("[ART/PIN] mark key=\(key.prefix(60)) url=\(url?.absoluteString.prefix(80) ?? "<derive>")")
        // Use the explicitly-passed URL if provided, else whatever the
        // current resolver state yields. Storing the URL (not just the
        // fact of resolution) makes `artURLForDisplay` return a stable
        // value regardless of transient state changes.
        let resolved = url ?? displayedArtURL ?? webArtURL
        pinnedArtByTrackURI[key] = resolved
    }

    /// Clear the "already resolved" flag for this track so the next
    /// metadata change will re-run the search. Only called from explicit
    /// user actions (Search Artwork, Refresh, Ignore, Clear).
    func invalidateArtResolution(for trackMetadata: TrackMetadata) {
        let key = artResolutionKey(trackMetadata: trackMetadata)
        sonosDebugLog("[ART/PIN] invalidate key=\(key.prefix(60))")
        pinnedArtByTrackURI.removeValue(forKey: key)
    }

    /// Pinned URL for this track if one was resolved, else nil. Used by
    /// `artURLForDisplay` to short-circuit the resolver chain once the
    /// canonical answer is known.
    func pinnedURL(for trackMetadata: TrackMetadata) -> URL? {
        let key = artResolutionKey(trackMetadata: trackMetadata)
        return pinnedArtByTrackURI[key] ?? nil
    }

    func forceITunesArtSearch(trackMetadata: TrackMetadata, displayArtist: String, group: SonosGroup) {
        let artist = displayArtist
        let searchTerm = artOverrideKey(trackMetadata: trackMetadata)
        guard !searchTerm.isEmpty else { return }
        lastArtSearchKey = ""
        invalidateArtResolution(for: trackMetadata)
        forceWebArt = false
        isArtIgnored = false
        Task {
            if let artURL = await albumArtSearch.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                setManualArtwork(artURL, trackMetadata: trackMetadata, group: group)
            } else {
                // No iTunes match. Clear any stale displayed art and webArt
                // so the view shows the placeholder rather than the previous
                // track's URL. Without this, Refresh Artwork on a track with
                // no findable art appears to "do nothing".
                displayedArtURL = nil
                webArtURL = nil
            }
        }
    }

    // MARK: - State Mutation (encapsulated — ViewModel calls these, not direct property access)

    func clearWebArt() {
        webArtURL = nil
        forceWebArt = false
    }

    func setWebArtResult(_ url: URL?) {
        webArtURL = url
    }

    func setRadioTrackArt(_ url: URL?) {
        radioTrackArtURL = url
        // Keyless setter — used by call sites that don't yet know which
        // track this URL belongs to. Clears the gating key so display
        // doesn't reject the URL. New call sites should prefer
        // `setRadioTrackArt(_:forKey:)`.
        radioTrackArtKey = nil
        // Search resolved (success or definitive nil) — release any
        // held-over art from the grace window.
        cancelRadioGraceWindow()
    }

    /// Records the URL together with the `title|artist` key it was
    /// resolved for. The display layer compares this against the current
    /// track's key and refuses to surface a stale URL from a previous
    /// song while the new search is still in flight.
    func setRadioTrackArt(_ url: URL?, forKey key: String) {
        radioTrackArtURL = url
        radioTrackArtKey = url == nil ? nil : key
        // Search resolved (success or definitive nil) — release any
        // held-over art from the grace window.
        cancelRadioGraceWindow()
    }

    func clearRadioTrackArt() {
        radioTrackArtURL = nil
        radioTrackArtKey = nil
        lastRadioTrackKey = ""
        cancelRadioGraceWindow()
    }

    func setSearchKey(_ key: String) {
        lastArtSearchKey = key
    }

    func shouldSearch(key: String) -> Bool {
        key != lastArtSearchKey
    }

    func shouldSearchRadioTrack(key: String) -> Bool {
        key != lastRadioTrackKey
    }

    func setRadioTrackKey(_ key: String) {
        lastRadioTrackKey = key
    }

    func reset() {
        displayedArtURL = nil
        radioTrackArtURL = nil
        radioTrackArtKey = nil
        radioStationArtURL = nil
        webArtURL = nil
        forceWebArt = false
        isArtIgnored = false
        lastArtSearchKey = ""
        lastTrackURI = ""
        lastTrackTitle = ""
        lastTrackArtist = ""
        lastRadioTrackKey = ""
        lastStationName = ""
    }

    // MARK: - Helpers

    private func localFileArtURL(trackMetadata: TrackMetadata, group: SonosGroup) -> String? {
        guard let uri = trackMetadata.trackURI,
              URIPrefix.isLocal(uri),
              let coordinator = group.coordinator else { return nil }
        return AlbumArtSearchService.getaaURL(speakerIP: coordinator.ip, port: coordinator.port, trackURI: uri)
    }
}
