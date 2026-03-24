/// BrowseView.swift — Content browsing panel (library, favorites, playlists, radio).
///
/// Uses a manual breadcrumb stack instead of NavigationStack to avoid macOS
/// SwiftUI bugs with NavigationLink re-selection. Each drill-down pushes a
/// BrowseDestination onto the stack, back pops it.
import SwiftUI
import Combine
import SonosKit

struct BrowseView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup?

    @State private var searchText = ""
    @State private var breadcrumbs: [BrowseDestination] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                // Navigation buttons
                if !breadcrumbs.isEmpty {
                    Button {
                        breadcrumbs.removeAll()
                    } label: {
                        Image(systemName: "house.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.browseHome)
                }

                if breadcrumbs.count > 1 {
                    Button {
                        breadcrumbs.removeLast()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.back)
                }

                if let current = breadcrumbs.last {
                    Text(current.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(L10n.browse)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                Spacer()

                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField(L10n.localSearch, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .onSubmit {
                            submitSearch()
                        }
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .opacity(searchText.isEmpty ? 0 : 1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 180)
                .animation(nil, value: searchText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Content — either sections view or drill-down list
            if breadcrumbs.isEmpty {
                BrowseSectionsView(group: group, onNavigate: { dest in
                    breadcrumbs.append(dest)
                })
            } else {
                let current = breadcrumbs.last!
                BrowseListView(
                    title: current.title,
                    objectID: current.objectID,
                    group: group,
                    onNavigate: { dest in
                        breadcrumbs.append(dest)
                    }
                )
                .id(current.objectID) // Force recreation on each navigation
                .environmentObject(sonosManager)
            }
        }
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        breadcrumbs.append(BrowseDestination(
            title: "Search: \(query)",
            objectID: "SEARCH:\(query)"
        ))
    }
}

struct BrowseDestination: Hashable {
    let title: String
    let objectID: String
}

struct BrowseSectionsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup?
    let onNavigate: (BrowseDestination) -> Void

    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading && sonosManager.browseSections.isEmpty {
                Section {
                    ProgressView(L10n.discoveringContent)
                }
            }

            if !sonosManager.browseSections.isEmpty {
                Section(L10n.libraryAndFavorites) {
                    ForEach(sonosManager.browseSections) { section in
                        Button {
                            onNavigate(BrowseDestination(title: section.title, objectID: section.objectID))
                        } label: {
                            Label(section.title, systemImage: section.icon)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .onAppear {
            Task {
                await sonosManager.loadBrowseSections()
                isLoading = false
            }
        }
    }
}

/// Displays items for a single level of the browse tree, with pagination and context menus
struct BrowseListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let title: String
    let objectID: String
    let group: SonosGroup?
    let onNavigate: (BrowseDestination) -> Void

    @State private var items: [BrowseItem] = []
    @State private var totalItems = 0
    @State private var isLoading = true
    @State private var loadedCount = 0
    @State private var errorMessage: String?
    @State private var selectedFilter: String? = nil
    @State private var playbackError: String? = nil

    private let pageSize = 100
    private var isSearch: Bool { objectID.hasPrefix("SEARCH:") }

    /// Whether this view should show service filters
    private var showsFilters: Bool {
        objectID == "FV:2" || objectID.hasPrefix("SQ:") || objectID == "SQ:"
    }

    /// Unique service labels from loaded items
    private var availableFilters: [String] {
        var seen = Set<String>()
        var filters: [String] = []
        for item in items {
            if let label = serviceLabel(for: item), !seen.contains(label) {
                seen.insert(label)
                filters.append(label)
            }
        }
        return filters.sorted()
    }

    /// Items filtered by selected service
    private var filteredItems: [BrowseItem] {
        guard let filter = selectedFilter else { return items }
        return items.filter { serviceLabel(for: $0) == filter }
    }

    /// Determines the service label for an item
    private func serviceLabel(for item: BrowseItem) -> String? {
        // URI content check first — most reliable
        if let uri = item.resourceURI,
           let name = sonosManager.detectServiceName(fromURI: uri) {
            return name
        }
        if let desc = item.serviceDescriptor,
           let name = sonosManager.musicServiceName(fromDescriptor: desc) {
            return name
        }
        if let meta = item.resourceMetadata,
           let name = sonosManager.musicServiceName(fromDescriptor: meta) {
            return name
        }
        if item.id.hasPrefix("SQ:") { return "Sonos Playlist" }
        if item.id.hasPrefix("A:") || item.id.hasPrefix("S:") { return "Music Library" }
        if item.id.hasPrefix("R:") { return "Radio" }
        return nil
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView(L10n.loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.empty)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Playback error banner
                    if let error = playbackError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                                .lineLimit(2)
                            Spacer()
                            Button {
                                playbackError = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.1))
                    }

                    // Service filter bar
                    if showsFilters && availableFilters.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                FilterChip(label: L10n.all, isSelected: selectedFilter == nil) {
                                    selectedFilter = nil
                                }
                                ForEach(availableFilters, id: \.self) { filter in
                                    FilterChip(label: filter, isSelected: selectedFilter == filter) {
                                        selectedFilter = selectedFilter == filter ? nil : filter
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .background(.bar)
                        Divider()
                    }

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredItems) { item in
                                Button {
                                    handleTap(item)
                                } label: {
                                    BrowseItemRow(item: item)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    contextMenuItems(for: item)
                                }
                                .overlay(alignment: .trailing) {
                                    if item.requiresService {
                                        Text(L10n.requiresSonosApp)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .padding(.trailing, 12)
                                    }
                                }
                                Divider().padding(.leading, 64)
                        }

                        if loadedCount < totalItems {
                            Button("\(L10n.loadMore) (\(loadedCount) \(L10n.of) \(totalItems))...") {
                                Task { await loadMore() }
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                        }
                    }
                }
                }
            }
        }
        .onAppear {
            Task { await loadItems() }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: BrowseItem) -> some View {
        if let group = group {
            if item.isPlayable {
                Button(L10n.playNow) {
                    Task { await play(item, in: group) }
                }
                Button(L10n.playNext) {
                    Task { await addToQueue(item, in: group, playNext: true) }
                }
                Button(L10n.addToQueue) {
                    Task { await addToQueue(item, in: group) }
                }
            }
            if item.isContainer {
                Divider()
                Button(L10n.browse) {
                    onNavigate(BrowseDestination(title: item.title, objectID: item.id))
                }
            }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        if item.isContainer {
            onNavigate(BrowseDestination(title: item.title, objectID: item.id))
        } else if let group = group {
            Task { await play(item, in: group) }
        }
    }

    private func loadItems() async {
        isLoading = true
        errorMessage = nil
        do {
            if isSearch {
                let query = String(objectID.dropFirst("SEARCH:".count))
                async let artistResults = sonosManager.search(query: query, in: "A:ALBUMARTIST", count: 20)
                async let albumResults = sonosManager.search(query: query, in: "A:ALBUM", count: 20)
                async let trackResults = sonosManager.search(query: query, in: "A:TRACKS", count: 30)

                let (artists, albums, tracks) = try await (artistResults, albumResults, trackResults)
                items = artists.items + albums.items + tracks.items
                totalItems = items.count
                loadedCount = items.count
            } else {
                let (result, total) = try await sonosManager.browse(objectID: objectID, start: 0, count: pageSize)
                items = result
                totalItems = total
                loadedCount = result.count
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isSearch else { return }
        do {
            let (result, _) = try await sonosManager.browse(objectID: objectID, start: loadedCount, count: pageSize)
            items.append(contentsOf: result)
            loadedCount += result.count
        } catch {
        }
    }

    private func play(_ item: BrowseItem, in group: SonosGroup) async {
        playbackError = nil
        do {
            try await sonosManager.playBrowseItem(item, in: group)
            playbackError = nil
        } catch let error as SOAPError {
            switch error {
            case .soapFault(let code, _):
                if code == "402" || code == "714" || code == "800" {
                    let serviceName = item.resourceURI.flatMap { sonosManager.detectServiceName(fromURI: $0) } ?? "the streaming service"
                    playbackError = "\(L10n.couldNotPlay) \"\(item.title)\" — \(serviceName) \(L10n.mayRequireSignIn)"
                } else {
                    playbackError = "\(L10n.couldNotPlay) \"\(item.title)\": \(L10n.error_) \(code)"
                }
            default:
                playbackError = "\(L10n.couldNotPlay) \"\(item.title)\": \(error.localizedDescription)"
            }
        } catch {
            playbackError = "\(L10n.couldNotPlay) \"\(item.title)\": \(error.localizedDescription)"
        }
    }

    private func addToQueue(_ item: BrowseItem, in group: SonosGroup, playNext: Bool = false) async {
        do {
            try await sonosManager.addBrowseItemToQueue(item, in: group, playNext: playNext)
        } catch {
        }
    }

    private func playContainer(in group: SonosGroup) async {
        let containerItem = BrowseItem(id: objectID, title: title, itemClass: .container)
        do {
            try await sonosManager.playBrowseItem(containerItem, in: group)
        } catch {
        }
    }

    private func addContainerToQueue(in group: SonosGroup) async {
        let containerItem = BrowseItem(id: objectID, title: title, itemClass: .container)
        do {
            try await sonosManager.addBrowseItemToQueue(containerItem, in: group)
        } catch {
        }
    }
}

struct BrowseItemRow: View {
    @EnvironmentObject var sonosManager: SonosManager
    let item: BrowseItem
    @State private var resolvedArtURL: URL?
    @State private var didAttemptArtLoad = false

    private var sourceLabel: String? {
        // 1. Check URI content first — most reliable for identifying the actual service
        //    (SA_RINCON/sid numbers can map to wrong services)
        if let uri = item.resourceURI,
           let name = sonosManager.detectServiceName(fromURI: uri) {
            return name
        }

        // 2. Check serviceDescriptor (SA_RINCON from desc element)
        if let desc = item.serviceDescriptor {
            if let name = sonosManager.musicServiceName(fromDescriptor: desc) {
                return name
            }
        }

        // 3. Check resourceMetadata for SA_RINCON references
        if let meta = item.resourceMetadata {
            if let name = sonosManager.musicServiceName(fromDescriptor: meta) {
                return name
            }
        }

        // 4. Check objectID for known container types
        if item.id.hasPrefix("SQ:") { return "Sonos Playlist" }
        if item.id.hasPrefix("A:") || item.id.hasPrefix("S:") { return "Music Library" }
        if item.id.hasPrefix("R:") { return "Radio" }

        return nil
    }

    private var artURL: URL? {
        // Prefer cached art (discovered during playback) over item's original URL
        // because the original URL may be stale/dead (404)
        if let resolved = resolvedArtURL {
            return resolved
        }
        if let direct = item.albumArtURI.flatMap({ URL(string: $0) }) {
            return direct
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: artURL)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !item.artist.isEmpty || !item.album.isEmpty {
                        Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let source = sourceLabel {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(sourceColor(source), in: Capsule())
                    }
                }
            }

            Spacer()

            if item.isContainer {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            checkArtCache()
            if resolvedArtURL == nil, item.albumArtURI == nil, !didAttemptArtLoad {
                didAttemptArtLoad = true
                Task { await loadMissingArt() }
            }
        }
        .onReceive(sonosManager.$discoveredArtURLs) { _ in
            checkArtCache()
        }
    }

    /// Checks the discovered art cache for this item using multi-key lookup
    private func checkArtCache() {
        // Try exact ID first (favorites use FV:2/xxx as key)
        if let cached = sonosManager.discoveredArtURLs[item.id] {
            resolvedArtURL = URL(string: cached)
            return
        }
        // Fall back to URI / title / normalized-title lookup
        if let cached = sonosManager.lookupCachedArt(uri: item.resourceURI, title: item.title) {
            resolvedArtURL = URL(string: cached)
        }
    }

    /// Whether this item is from the local Music Library (S: shares or A: library)
    private var isLocalLibraryItem: Bool {
        item.id.hasPrefix("S:") ||
        (item.id.hasPrefix("A:") && !item.id.hasPrefix("A:GENRE")) ||
        item.resourceURI?.hasPrefix("x-file-cifs://") == true ||
        item.resourceURI?.hasPrefix("x-smb://") == true
    }

    /// Loads art for items without albumArtURI.
    private func loadMissingArt() async {
        // 0. Check if playback previously discovered art for this exact item
        if let cachedArt = sonosManager.discoveredArtURLs[item.id] {
            resolvedArtURL = URL(string: cachedArt)
            return
        }

        // Local Music Library items: use embedded art, folder art, then iTunes
        if isLocalLibraryItem {
            await loadLocalLibraryArt()
            return
        }

        // 1. Try extracting art from the item's resourceMetadata DIDL
        if let meta = item.resourceMetadata, !meta.isEmpty {
            let didl = meta.contains("&lt;") ? XMLResponseParser.xmlUnescape(meta) : meta
            if let parsed = XMLResponseParser.parseDIDLMetadata(didl), !parsed.albumArtURI.isEmpty {
                var artURI = parsed.albumArtURI
                if artURI.hasPrefix("/"), let device = sonosManager.groups.first?.coordinator {
                    artURI = "http://\(device.ip):\(device.port)\(artURI)"
                }
                resolvedArtURL = URL(string: artURI)
                sonosManager.cacheArtURL(artURI, forURI: item.resourceURI ?? "", title: item.title, itemID: item.id)
                return
            }
        }

        // 2. Try BrowseMetadata — asks the speaker for the item's full metadata
        //    including albumArtURI (works for radio stations, favorites, etc.)
        do {
            if let metaItem = try await sonosManager.browseMetadata(objectID: item.id),
               let artURI = metaItem.albumArtURI {
                resolvedArtURL = URL(string: artURI)
                sonosManager.cacheArtURL(artURI, forURI: item.resourceURI ?? item.id, title: item.title, itemID: item.id)
                return
            }
        } catch {}

        // 3. For non-radio items, try the Sonos speaker's /getaa endpoint
        if let uri = item.resourceURI, !uri.isEmpty,
           !uri.hasPrefix("x-sonosapi-stream:"),
           !uri.hasPrefix("x-sonosapi-radio:"),
           !uri.hasPrefix("x-rincon-mp3radio:"),
           !uri.hasPrefix("x-rincon-playlist:"),
           let device = sonosManager.groups.first?.coordinator {
            let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
            let artURL = "http://\(device.ip):\(device.port)/getaa?s=1&u=\(encoded)"
            resolvedArtURL = URL(string: artURL)
            sonosManager.cacheArtURL(artURL, forURI: uri, title: item.title, itemID: item.id)
            return
        }

        // 3. Try browsing first track (containers only)
        if item.isContainer {
            do {
                let (items, _) = try await sonosManager.browse(objectID: item.id, start: 0, count: 1)
                if let firstItem = items.first, let artURI = firstItem.albumArtURI {
                    resolvedArtURL = URL(string: artURI)
                    return
                }
            } catch {
            }
        }

        // 4. Fallback: search iTunes for art (not for radio)
        let isRadio = item.resourceURI?.contains("x-sonosapi-stream:") == true ||
                      item.resourceURI?.contains("x-sonosapi-radio:") == true ||
                      item.resourceURI?.contains("x-rincon-mp3radio:") == true
        if !isRadio {
            let artist = item.artist.isEmpty ? "" : item.artist
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: artist, album: item.title) {
                resolvedArtURL = URL(string: artURL)
            }
        }
    }

    /// Art loading for local Music Library items.
    /// Tracks: embedded art via /getaa
    /// Albums/leaf folders: embedded art from first track, then iTunes
    /// Parent folders (artists, genres): iTunes first, then inherit from child
    private func loadLocalLibraryArt() async {
        guard let device = sonosManager.groups.first?.coordinator else { return }

        // 1. If the item has a direct file URI (not a playlist/container URI),
        //    try /getaa which extracts embedded art from the file
        if let uri = item.resourceURI, !uri.isEmpty,
           (uri.hasPrefix("x-file-cifs://") || uri.hasPrefix("x-smb://")) {
            let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
            let artURL = "http://\(device.ip):\(device.port)/getaa?s=1&u=\(encoded)"
            resolvedArtURL = URL(string: artURL)
            sonosManager.cacheArtURL(artURL, forURI: uri, title: item.title, itemID: item.id)
            return
        }

        // 2. For containers (folders/albums/artists)
        if item.isContainer {
            // Determine the best search terms based on the item type
            let isArtistContainer = item.id.hasPrefix("A:ALBUMARTIST/") || item.id.hasPrefix("A:ARTIST/")
            let isAlbumContainer = item.id.hasPrefix("A:ALBUM/")

            if isArtistContainer {
                // Artist container: title IS the artist name
                if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: item.title, album: "") {
                    resolvedArtURL = URL(string: artURL)
                    sonosManager.cacheArtURL(artURL, forURI: item.id, title: item.title)
                    return
                }
            } else if isAlbumContainer {
                // Album container: title is album, artist might be in item.artist
                let artist = item.artist.isEmpty ? "" : item.artist
                if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: artist, album: item.title) {
                    resolvedArtURL = URL(string: artURL)
                    sonosManager.cacheArtURL(artURL, forURI: item.id, title: item.title)
                    return
                }
            } else {
                // Share folder or other container — try title as album/artist
                let artist = item.artist.isEmpty ? "" : item.artist
                if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: artist, album: item.title) {
                    resolvedArtURL = URL(string: artURL)
                    sonosManager.cacheArtURL(artURL, forURI: item.id, title: item.title)
                    return
                }

                // Try guessing from path: parent folder = artist, current = album
                if let (guessedArtist, guessedAlbum) = guessArtistAlbum(from: item.id, title: item.title) {
                    if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: guessedArtist, album: guessedAlbum) {
                        resolvedArtURL = URL(string: artURL)
                        sonosManager.cacheArtURL(artURL, forURI: item.id, title: item.title)
                        return
                    }
                }
            }

            // Inherit from child: browse to find a track with embedded art
            if let artURL = await findArtInContainer(objectID: item.id, device: device, depth: 0) {
                resolvedArtURL = artURL
                sonosManager.cacheArtURL(artURL.absoluteString, forURI: item.id, title: item.title)
                return
            }
        }
    }

    /// Guesses artist and album from the objectID path or folder structure.
    /// e.g. "S://NAS/Music/Pink Floyd/The Wall" → ("Pink Floyd", "The Wall")
    /// e.g. "A:ALBUMARTIST/Beatles/Abbey Road" → ("Beatles", "Abbey Road")
    private func guessArtistAlbum(from objectID: String, title: String) -> (String, String)? {
        // Decode percent-encoded path
        let decoded = objectID.removingPercentEncoding ?? objectID

        // Split by / and get the last meaningful segments
        let parts = decoded.components(separatedBy: "/").filter { !$0.isEmpty }

        // Need at least 2 path segments beyond the root
        guard parts.count >= 2 else { return nil }

        let folder = parts[parts.count - 1]
        let parent = parts[parts.count - 2]

        // Skip if parent looks like a root/share name (short or generic)
        let skipParents = ["music", "media", "audio", "share", "shares", "nas", "volume1"]
        if skipParents.contains(parent.lowercased()) { return nil }

        // The current folder is the album, parent is the artist
        // Only if they're different from what we already searched
        if parent.lowercased() != title.lowercased() {
            return (parent, folder)
        }

        // Try parent as artist, title as album
        if parts.count >= 3 {
            let grandparent = parts[parts.count - 3]
            if !skipParents.contains(grandparent.lowercased()) {
                return (grandparent, title)
            }
        }

        return nil
    }

    /// Recursively browses into a container to find a track with album art.
    /// Checks up to 2 levels deep (folder → subfolder → track).
    private func findArtInContainer(objectID: String, device: SonosDevice, depth: Int) async -> URL? {
        guard depth < 3 else { return nil }
        do {
            let (items, _) = try await sonosManager.browse(objectID: objectID, start: 0, count: 5)
            for browseItem in items {
                // Found a track with art
                if let artURI = browseItem.albumArtURI {
                    return URL(string: artURI)
                }
                // Track without art in DIDL — try /getaa with its resource URI
                if !browseItem.isContainer, let uri = browseItem.resourceURI, !uri.isEmpty {
                    let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
                    return URL(string: "http://\(device.ip):\(device.port)/getaa?s=1&u=\(encoded)")
                }
                // Subfolder — browse into it
                if browseItem.isContainer {
                    if let art = await findArtInContainer(objectID: browseItem.id, device: device, depth: depth + 1) {
                        return art
                    }
                }
            }
        } catch {}
        return nil
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "Music Library": return .green.opacity(0.7)
        case "Radio": return .orange.opacity(0.7)
        case "Calm Radio": return .teal.opacity(0.7)
        case "Sonos Playlist": return .purple.opacity(0.7)
        case "TV", "Line-In": return .gray.opacity(0.7)
        default: return .blue.opacity(0.7)
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption2)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
