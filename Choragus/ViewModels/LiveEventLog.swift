/// LiveEventLog.swift — Captures the live UPnP event stream emitted by
/// `HybridEventFirstTransport` and exposes it for the Diagnostics
/// "Live Events" tab. Subscribes via the `SonosUPnPEventNotification`
/// broadcast so it doesn't have to own its own `EventListener` /
/// subscriptions (those already exist inside the transport).
///
/// Newest-first ring buffer, pause buffers events instead of dropping
/// them, parsed one-line summaries per event.
import Foundation
import Combine
import SonosKit

@MainActor
final class LiveEventLog: ObservableObject {

    enum ServiceKind: String, CaseIterable, Identifiable, Hashable {
        case renderingControl
        case avTransport
        case topology
        var id: String { rawValue }

        var tag: String {
            switch self {
            case .renderingControl: return "RC"
            case .avTransport:      return "AVT"
            case .topology:         return "TOPO"
            }
        }

        static func from(serviceType: String) -> ServiceKind? {
            switch serviceType {
            case "renderingControl": return .renderingControl
            case "avTransport":      return .avTransport
            case "topology":         return .topology
            default:                 return nil
            }
        }
    }

    struct Event: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let deviceID: String
        let roomName: String
        let groupName: String
        let kind: ServiceKind
        let summary: String
        let body: String
    }

    @Published private(set) var events: [Event] = []
    @Published var isPaused = false
    @Published var enabledKinds: Set<ServiceKind> = Set(ServiceKind.allCases)
    @Published var roomFilter: String = ""

    private var bufferedWhilePaused: [Event] = []
    private static let cap = 5_000

    /// SonosManager reference — used to resolve `deviceID` to a
    /// human-readable room name and group label at append time.
    /// Captured weakly so a teardown of the manager doesn't keep this
    /// log alive.
    private weak var sonosManager: SonosManager?
    private var cancellable: AnyCancellable?

    init(sonosManager: SonosManager) {
        self.sonosManager = sonosManager
        self.cancellable = NotificationCenter.default
            .publisher(for: SonosUPnPEventNotification.name)
            .sink { [weak self] note in
                Task { @MainActor [weak self] in
                    self?.ingest(note)
                }
            }
    }

    private func ingest(_ note: Notification) {
        guard let info = note.userInfo,
              let serviceType = info[SonosUPnPEventNotification.serviceKey] as? String,
              let deviceID = info[SonosUPnPEventNotification.deviceIDKey] as? String,
              let body = info[SonosUPnPEventNotification.bodyKey] as? String,
              let kind = ServiceKind.from(serviceType: serviceType)
        else { return }

        let manager = sonosManager
        let device = manager?.devices[deviceID]
        let room = device?.roomName ?? deviceID
        let group = manager?.groups
            .first { $0.members.contains(where: { $0.id == deviceID }) }?
            .name ?? "—"

        let summary = Self.summarise(body: body, kind: kind)

        append(.init(
            timestamp: Date(),
            deviceID: deviceID,
            roomName: room,
            groupName: group,
            kind: kind,
            summary: summary,
            body: body
        ))
    }

    private func append(_ event: Event) {
        if isPaused {
            bufferedWhilePaused.append(event)
            if bufferedWhilePaused.count > Self.cap {
                bufferedWhilePaused.removeFirst(bufferedWhilePaused.count - Self.cap)
            }
        } else {
            events.insert(event, at: 0)
            if events.count > Self.cap {
                events.removeLast(events.count - Self.cap)
            }
        }
    }

    /// Toggles pause. On resume, anything captured during the pause is
    /// flushed in to the visible list, newest-first ordering preserved.
    func togglePause() {
        if isPaused {
            let flush = bufferedWhilePaused
            bufferedWhilePaused.removeAll(keepingCapacity: false)
            events.insert(contentsOf: flush.reversed(), at: 0)
            if events.count > Self.cap {
                events.removeLast(events.count - Self.cap)
            }
        }
        isPaused.toggle()
    }

    func clear() {
        events.removeAll(keepingCapacity: false)
        bufferedWhilePaused.removeAll(keepingCapacity: false)
    }

    var filtered: [Event] {
        events.filter { ev in
            guard enabledKinds.contains(ev.kind) else { return false }
            if !roomFilter.isEmpty, ev.roomName != roomFilter { return false }
            return true
        }
    }

    var knownRooms: [String] {
        Array(Set(events.map(\.roomName)))
            .filter { !$0.isEmpty && $0 != "—" }
            .sorted()
    }

    /// Builds a one-line summary of the parsed event. Mirrors the
    /// standalone monitor's per-kind digest.
    private static func summarise(body: String, kind: ServiceKind) -> String {
        switch kind {
        case .renderingControl:
            let ev = LastChangeParser.parseRenderingControlEvent(body)
            var parts: [String] = []
            if let v = ev.volume { parts.append("vol=\(v)") }
            if let m = ev.mute { parts.append("mute=\(m)") }
            if let b = ev.bass { parts.append("bass=\(b)") }
            if let t = ev.treble { parts.append("treble=\(t)") }
            if let l = ev.loudness { parts.append("loud=\(l)") }
            return parts.isEmpty ? "(no fields)" : parts.joined(separator: " ")

        case .avTransport:
            let ev = LastChangeParser.parseAVTransportEvent(body)
            var parts: [String] = []
            if let s = ev.transportState { parts.append("state=\(s.rawValue)") }
            if let m = ev.currentPlayMode { parts.append("mode=\(m.rawValue)") }
            if let uri = ev.currentTrackURI, !uri.isEmpty {
                let trimmed = uri.count > 60 ? String(uri.prefix(60)) + "…" : uri
                parts.append("uri=\(trimmed)")
            }
            if let dur = ev.currentTrackDuration { parts.append("dur=\(dur)") }
            if let n = ev.numberOfTracks { parts.append("queue=\(n)") }
            return parts.isEmpty ? "(no fields)" : parts.joined(separator: " ")

        case .topology:
            return "topology changed (\(body.count) bytes)"
        }
    }
}
