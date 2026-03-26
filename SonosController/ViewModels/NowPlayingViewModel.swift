/// NowPlayingViewModel.swift — Business logic for the Now Playing view.
///
/// Handles transport control, volume management, position interpolation,
/// album art resolution, and metadata display. The view binds to published
/// state and calls action methods.
import SwiftUI
import Combine
import SonosKit

@MainActor
final class NowPlayingViewModel: ObservableObject {
    let sonosManager: SonosManager
    let group: SonosGroup

    // MARK: - Transport State

    var transportState: TransportState {
        sonosManager.groupTransportStates[group.coordinatorID] ?? .stopped
    }

    var trackMetadata: TrackMetadata {
        sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
    }

    var playMode: PlayMode {
        sonosManager.groupPlayModes[group.coordinatorID] ?? .normal
    }

    var hasTrack: Bool {
        !trackMetadata.title.isEmpty || !trackMetadata.stationName.isEmpty || trackMetadata.duration > 0
    }

    var awaitingPlayback: Bool {
        sonosManager.awaitingPlayback[group.coordinatorID] ?? false
    }

    var currentServiceName: String? {
        if let sid = trackMetadata.serviceID,
           let name = sonosManager.musicServiceName(for: sid) { return name }
        if let uri = trackMetadata.trackURI,
           let name = sonosManager.detectServiceName(fromURI: uri) { return name }
        if let uri = trackMetadata.trackURI, URIPrefix.isLocal(uri) { return ServiceName.musicLibrary }
        return nil
    }

    var displayArtist: String {
        let artist = trackMetadata.artist
        if artist.hasPrefix("RINCON_") { return "" }
        return artist
    }

    // MARK: - Volume

    @Published var volume: Double = 30
    @Published var isMuted = false
    @Published var speakerVolumes: [String: Double] = [:]
    @Published var speakerMutes: [String: Bool] = [:]
    @Published var volumeActionPending = false
    var lastMasterVolume: Double = 0
    var volumePendingTimer: Task<Void, Never>?
    var volumeGraceUntil: Date = .distantPast
    var muteGraceUntil: Date = .distantPast

    // MARK: - Position

    @Published var smoothPosition: TimeInterval = 0
    @Published var isDraggingSeek = false
    var lastKnownPosition: TimeInterval = 0
    var lastPositionTimestamp: Date = .distantPast
    var positionFrozenUntil: Date = .distantPast
    var progressTimer: Timer?
    var positionPollingTask: Task<Void, Never>?

    // MARK: - Transport UI

    @Published var actionInFlight: String?
    @Published var crossfadeOn = false
    @Published var isInitialized = false

    // MARK: - Art

    @Published var displayedArtURL: URL?
    @Published var radioTrackArtURL: URL?
    @Published var radioStationArtURL: URL?
    @Published var webArtURL: URL?
    var forceWebArt = false
    var lastArtSearchKey = ""
    var lastTrackURI = ""
    var lastRadioTrackKey = ""

    // MARK: - Init

    init(sonosManager: SonosManager, group: SonosGroup) {
        self.sonosManager = sonosManager
        self.group = group
    }

    // MARK: - Transport Actions

    func togglePlayPause() {
        let shouldPlay = !transportState.isPlaying
        if shouldPlay {
            sonosManager.groupTransportStates[group.coordinatorID] = .playing
        } else {
            sonosManager.groupTransportStates[group.coordinatorID] = .paused
        }
        sonosManager.setTransportGrace(groupID: group.coordinatorID)
        performAction("playPause") {
            if shouldPlay {
                try await self.sonosManager.play(group: self.group)
            } else {
                try await self.sonosManager.pause(group: self.group)
            }
        }
    }

    func toggleShuffle() {
        let newMode = playMode.togglingShuffle()
        sonosManager.groupPlayModes[group.coordinatorID] = newMode
        sonosManager.setModeGrace(groupID: group.coordinatorID)
        performAction("shuffle") {
            try await self.sonosManager.setPlayMode(group: self.group, mode: newMode)
        }
    }

    func cycleRepeat() {
        let newMode = playMode.cyclingRepeat()
        sonosManager.groupPlayModes[group.coordinatorID] = newMode
        sonosManager.setModeGrace(groupID: group.coordinatorID)
        performAction("repeat") {
            try await self.sonosManager.setPlayMode(group: self.group, mode: newMode)
        }
    }

    func toggleCrossfade() {
        let newValue = !crossfadeOn
        crossfadeOn = newValue
        performAction("crossfade") {
            try await self.sonosManager.setCrossfadeMode(group: self.group, enabled: newValue)
        }
    }

    func seekToPosition(_ seconds: TimeInterval) {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let timeStr = String(format: "%d:%02d:%02d", hours, minutes, secs)
        positionFrozenUntil = Date().addingTimeInterval(Timing.positionFreezeAfterSeek)
        sonosManager.setPositionGrace(coordinatorID: group.coordinatorID, duration: Timing.positionFreezeAfterSeek)
        Task {
            try? await sonosManager.seek(group: group, to: timeStr)
        }
    }

    // MARK: - Volume Actions

    func toggleMute() {
        let newMuted = !isMuted
        isMuted = newMuted
        muteGraceUntil = Date().addingTimeInterval(Timing.playbackGracePeriod)
        for member in group.members {
            sonosManager.setMuteGrace(deviceID: member.id)
            speakerMutes[member.id] = newMuted
            sonosManager.deviceMutes[member.id] = newMuted
        }
        Task {
            for member in group.members {
                try? await sonosManager.setMute(device: member, muted: newMuted)
            }
        }
    }

    func setVolume() {
        let now = Date()
        volumeGraceUntil = now.addingTimeInterval(Timing.playbackGracePeriod)
        let delta = volume - lastMasterVolume
        for member in group.members {
            sonosManager.setVolumeGrace(deviceID: member.id)
            let currentVol = speakerVolumes[member.id] ?? 0
            let newVol = max(0, min(100, currentVol + delta))
            speakerVolumes[member.id] = newVol
            sonosManager.deviceVolumes[member.id] = Int(newVol)
        }
        lastMasterVolume = volume
        showVolumePending()
    }

    func commitVolume() {
        Task {
            for member in group.members {
                let vol = Int(speakerVolumes[member.id] ?? 0)
                try? await sonosManager.setVolume(device: member, volume: vol)
            }
            clearVolumePending()
        }
    }

    private func showVolumePending() {
        volumePendingTimer?.cancel()
        volumePendingTimer = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            volumeActionPending = true
        }
    }

    private func clearVolumePending() {
        volumePendingTimer?.cancel()
        volumeActionPending = false
    }

    // MARK: - Copy Track Info

    func copyTrackInfo() {
        var lines: [String] = []
        if !trackMetadata.stationName.isEmpty {
            lines.append("\(L10n.sourceLabel): \(trackMetadata.stationName)")
        } else if let sid = trackMetadata.serviceID,
                  let serviceName = sonosManager.musicServiceName(for: sid) {
            lines.append("\(L10n.sourceLabel): \(serviceName)")
        }
        if !displayArtist.isEmpty {
            lines.append("\(L10n.artistLabel): \(displayArtist)")
        }
        if !trackMetadata.album.isEmpty {
            lines.append("\(L10n.albumLabel): \(trackMetadata.album)")
        }
        if !trackMetadata.title.isEmpty {
            lines.append("\(L10n.trackLabel): \(trackMetadata.title)")
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Action Runner

    func performAction(_ id: String, _ action: @escaping () async throws -> Void) {
        guard actionInFlight == nil else { return }
        actionInFlight = id
        Task {
            do {
                try await action()
            } catch {
                ErrorHandler.shared.handle(error, context: "TRANSPORT")
            }
            actionInFlight = nil
        }
    }

    // MARK: - Sync from Manager

    func syncFromManager() {
        isInitialized = true
        syncVolumeFromManager()
        syncMuteFromManager()
    }

    func syncVolumeFromManager() {
        let now = Date()
        guard now > volumeGraceUntil else { return }

        if group.members.count > 1 {
            var totalVol = 0.0
            for member in group.members {
                if sonosManager.isVolumeGraceActive(deviceID: member.id) {
                    let v = Double(sonosManager.deviceVolumes[member.id] ?? 0)
                    if abs((speakerVolumes[member.id] ?? 0) - v) > 0.5 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            speakerVolumes[member.id] = v
                        }
                    }
                    totalVol += v
                    continue
                }
                let v = Double(sonosManager.deviceVolumes[member.id] ?? 0)
                if abs((speakerVolumes[member.id] ?? 0) - v) > 0.5 || !isInitialized {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        speakerVolumes[member.id] = v
                    }
                }
                totalVol += v
            }
            let avg = totalVol / Double(group.members.count)
            if abs(volume - avg) > 0.5 || !isInitialized {
                withAnimation(.easeInOut(duration: 0.3)) {
                    volume = avg
                }
            }
            lastMasterVolume = volume
        } else if let device = group.coordinator {
            let v = Double(sonosManager.deviceVolumes[device.id] ?? 0)
            if abs(volume - v) > 0.5 || !isInitialized {
                withAnimation(.easeInOut(duration: 0.3)) {
                    volume = v
                }
            }
            lastMasterVolume = volume
        }
    }

    func syncMuteFromManager() {
        let now = Date()
        guard now > muteGraceUntil else { return }

        for member in group.members {
            if !sonosManager.isMuteGraceActive(deviceID: member.id) {
                speakerMutes[member.id] = sonosManager.deviceMutes[member.id] ?? false
            }
        }
        syncMasterMuteFromSpeakers()
    }

    func syncMasterMuteFromSpeakers() {
        let allMuted = group.members.allSatisfy { speakerMutes[$0.id] == true }
        if allMuted != isMuted {
            isMuted = allMuted
        }
    }

    // MARK: - Helpers

    var volumeIcon: String {
        if isMuted { return "speaker.slash.fill" }
        if volume < 33 { return "speaker.wave.1.fill" }
        if volume < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var repeatIcon: String {
        switch playMode.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var smoothPositionString: String {
        formatTime(smoothPosition)
    }

    func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
