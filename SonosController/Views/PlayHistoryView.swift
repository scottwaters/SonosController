/// PlayHistoryView.swift — Dedicated window for play history and statistics.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct PlayHistoryView: View {
    @EnvironmentObject var historyManager: PlayHistoryManager

    @State private var searchText = ""
    @State private var filterRoom: String?
    @State private var filterSource: String?
    @State private var filterDateRange: DateRange = .all
    @State private var sortNewestFirst = true
    @State private var showClearConfirm = false
    @State private var selectedTab = 1
    @State private var expandedArtEntry: PlayHistoryEntry?
    @State private var customDateFrom: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customDateTo: Date = Date()

    enum DateRange: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case week = "This Week"
        case month = "This Month"
        case quarter = "3 Months"
        case custom = "Custom Range"
    }

    private func sourceLabel(for entry: PlayHistoryEntry) -> String {
        historyManager.sourceServiceName(for: entry)
    }

    private var uniqueSources: [String] {
        Array(Set(historyManager.entries.map { sourceLabel(for: $0) })).sorted()
    }

    /// Entries filtered by date/room/source/search but NOT sorted (for dashboard)
    private var filteredEntriesUnsorted: [PlayHistoryEntry] {
        var result = historyManager.entries

        if filterDateRange != .all {
            if filterDateRange == .custom {
                let fromStart = Calendar.current.startOfDay(for: customDateFrom)
                let toEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customDateTo)) ?? customDateTo
                result = result.filter { $0.timestamp >= fromStart && $0.timestamp < toEnd }
            } else {
                let calendar = Calendar.current
                let now = Date()
                let cutoff: Date
                switch filterDateRange {
                case .today: cutoff = calendar.startOfDay(for: now)
                case .week: cutoff = calendar.date(byAdding: .day, value: -7, to: now)!
                case .month: cutoff = calendar.date(byAdding: .month, value: -1, to: now)!
                case .quarter: cutoff = calendar.date(byAdding: .month, value: -3, to: now)!
                default: cutoff = .distantPast
                }
                result = result.filter { $0.timestamp >= cutoff }
            }
        }

        if let room = filterRoom {
            result = result.filter { $0.groupName == room }
        }
        if let source = filterSource {
            result = result.filter { sourceLabel(for: $0) == source }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.artist.lowercased().contains(query) ||
                $0.title.lowercased().contains(query) ||
                $0.album.lowercased().contains(query) ||
                $0.stationName.lowercased().contains(query) ||
                $0.groupName.lowercased().contains(query)
            }
        }
        return result
    }

    /// Sorted for history list display
    private var filteredEntries: [PlayHistoryEntry] {
        sortNewestFirst ? filteredEntriesUnsorted.sorted { $0.timestamp > $1.timestamp }
                        : filteredEntriesUnsorted.sorted { $0.timestamp < $1.timestamp }
    }

    private var hasActiveFilters: Bool {
        filterRoom != nil || filterSource != nil || filterDateRange != .all || !searchText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Info banner
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Listening activity is tracked across all speakers and zones while SonosController is running.")
                    .font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))

            // Shared filter bar
            filterBar
            activeFilterChips

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Dashboard").tag(1)
                Text("History").tag(0)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)

            switch selectedTab {
            case 0:
                PlayHistoryView2(entries: filteredEntries, expandedArtEntry: $expandedArtEntry, sourceLabel: sourceLabel)
            default:
                PlayHistoryDashboard(entries: filteredEntriesUnsorted, expandedArtEntry: $expandedArtEntry)
                    .environmentObject(historyManager)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(historyManager.entries.isEmpty)

                Button {
                    showClearConfirm = true
                } label: {
                    Label(L10n.clearHistory, systemImage: "trash")
                }
                .disabled(historyManager.entries.isEmpty)
            }
        }
        .alert("Clear Play History?", isPresented: $showClearConfirm) {
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.clearHistory, role: .destructive) {
                historyManager.clearHistory()
            }
        } message: {
            Text("This will permanently remove all \(historyManager.totalEntries) entries.")
        }
        .onDisappear {
            NSColorPanel.shared.close()
        }
        .sheet(item: $expandedArtEntry) { entry in
            ExpandedArtView(
                artURL: entry.albumArtURI.flatMap { URL(string: $0) },
                title: entry.title,
                artist: entry.artist,
                album: entry.album,
                stationName: entry.stationName
            )
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Search tracks, artists, albums...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { searchText = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 280)

            // Date range
            Picker("", selection: $filterDateRange) {
                ForEach(DateRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .fixedSize()

            // Custom date range pickers
            if filterDateRange == .custom {
                DatePicker("", selection: $customDateFrom, displayedComponents: [.date])
                    .labelsHidden()
                    .frame(width: 100)
                Text("to")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $customDateTo, displayedComponents: [.date])
                    .labelsHidden()
                    .frame(width: 100)
            }

            // Room
            Picker("", selection: $filterRoom) {
                Label("All Rooms", systemImage: "hifispeaker.2").tag(String?.none)
                Divider()
                ForEach(historyManager.uniqueRooms, id: \.self) { room in
                    Text(room).tag(Optional(room))
                }
            }
            .fixedSize()

            // Source
            Picker("", selection: $filterSource) {
                Label("All Sources", systemImage: "dot.radiowaves.left.and.right").tag(String?.none)
                Divider()
                ForEach(uniqueSources, id: \.self) { source in
                    HStack {
                        Circle().fill(ServiceColor.color(for: source)).frame(width: 6, height: 6)
                        Text(source)
                    }
                    .tag(Optional(source))
                }
            }
            .fixedSize()

            Spacer()

            // Count
            Text("\(filteredEntriesUnsorted.count)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            + Text(" tracks")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Active Filter Chips

    @ViewBuilder
    private var activeFilterChips: some View {
        if hasActiveFilters {
            HStack(spacing: 6) {
                if filterDateRange != .all {
                    filterChip(label: filterDateRange.rawValue, icon: "calendar") {
                        withAnimation { filterDateRange = .all }
                    }
                }
                if let room = filterRoom {
                    filterChip(label: room, icon: "hifispeaker") {
                        withAnimation { filterRoom = nil }
                    }
                }
                if let source = filterSource {
                    filterChip(label: source, icon: "music.note", color: ServiceColor.color(for: source)) {
                        withAnimation { filterSource = nil }
                    }
                }
                if !searchText.isEmpty {
                    filterChip(label: "\"\(searchText)\"", icon: "magnifyingglass") {
                        withAnimation { searchText = "" }
                    }
                }

                Spacer()

                Button("Clear All") {
                    withAnimation {
                        filterDateRange = .all
                        filterRoom = nil
                        filterSource = nil
                        searchText = ""
                    }
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func filterChip(label: String, icon: String, color: Color = .accentColor, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.85), in: Capsule())
    }

    // MARK: - History Content


    // MARK: - Copy

    @ViewBuilder
    private func copyEntryMenu(_ entry: PlayHistoryEntry) -> some View {
        Button("Copy Track Details") {
            var lines: [String] = []
            if !entry.stationName.isEmpty { lines.append("\(L10n.sourceLabel): \(entry.stationName)") }
            if !entry.artist.isEmpty { lines.append("\(L10n.artistLabel): \(entry.artist)") }
            if !entry.album.isEmpty { lines.append("\(L10n.albumLabel): \(entry.album)") }
            if !entry.title.isEmpty { lines.append("\(L10n.trackLabel): \(entry.title)") }
            copyToClipboard(lines.joined(separator: "\n"))
        }
        if !entry.title.isEmpty {
            Button("Copy Title") { copyToClipboard(entry.title) }
        }
        if !entry.artist.isEmpty {
            Button("Copy Artist") { copyToClipboard(entry.artist) }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Export

    private func exportCSV() {
        let csv = historyManager.exportCSV()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "SonosPlayHistory.csv"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? csv.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
