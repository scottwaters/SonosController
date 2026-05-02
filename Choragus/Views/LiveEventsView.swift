/// LiveEventsView.swift — Diagnostics tab that shows the live UPnP
/// event stream from the speakers. Driven from Choragus's existing
/// transport subscriptions, so it adds zero new wire traffic.
import SwiftUI
import SonosKit

struct LiveEventsView: View {
    /// Owned by `DiagnosticsView` (and ultimately created in
    /// `WindowManager.openDiagnostics`) so the log keeps recording
    /// while the user is on other tabs of the Diagnostics window.
    @EnvironmentObject var log: LiveEventLog
    @State private var expandedEventID: UUID?

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            filterBar
            Divider()
            eventList
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                log.togglePause()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: log.isPaused ? "play.fill" : "pause.fill")
                    Text(log.isPaused ? L10n.liveEventsResume : L10n.liveEventsPause)
                }
                .frame(minWidth: 90)
            }
            .keyboardShortcut(" ", modifiers: [])

            Button {
                log.clear()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text(L10n.liveEventsClear)
                }
            }

            Spacer()

            Text(log.isPaused ? L10n.liveEventsPausedNote : L10n.liveEventsLive)
                .font(.callout)
                .foregroundStyle(log.isPaused ? .red : .green)

            Text(L10n.liveEventsCountFormat(log.filtered.count, log.events.count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            ForEach(LiveEventLog.ServiceKind.allCases) { kind in
                Toggle(isOn: kindBinding(for: kind)) {
                    Text(kind.tag)
                        .font(.system(.callout, design: .monospaced))
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }

            Divider().frame(height: 16)

            HStack(spacing: 4) {
                Text(L10n.liveEventsSpeakerLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("", selection: $log.roomFilter) {
                    Text(L10n.liveEventsAllSpeakers).tag("")
                    ForEach(log.knownRooms, id: \.self) { room in
                        Text(room).tag(room)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            Spacer()

            Button(L10n.liveEventsResetFilters) {
                log.enabledKinds = Set(LiveEventLog.ServiceKind.allCases)
                log.roomFilter = ""
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func kindBinding(for kind: LiveEventLog.ServiceKind) -> Binding<Bool> {
        Binding(
            get: { log.enabledKinds.contains(kind) },
            set: { newValue in
                if newValue { log.enabledKinds.insert(kind) }
                else { log.enabledKinds.remove(kind) }
            }
        )
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if log.filtered.isEmpty {
                    Text(L10n.liveEventsEmpty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else {
                    ForEach(log.filtered) { event in
                        eventRow(event)
                        Divider()
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func eventRow(_ event: LiveEventLog.Event) -> some View {
        let isExpanded = expandedEventID == event.id
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(Self.timeFmt.string(from: event.timestamp))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)

                Text(event.kind.tag)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(badgeColor(for: event.kind).opacity(0.18))
                    .foregroundStyle(badgeColor(for: event.kind))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: 48, alignment: .leading)

                Text(event.roomName)
                    .font(.system(.callout).weight(.medium))
                    .frame(width: 160, alignment: .leading)
                    .lineLimit(1)

                Text("[\(event.groupName)]")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 160, alignment: .leading)
                    .lineLimit(1)

                Text(event.summary)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                expandedEventID = isExpanded ? nil : event.id
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            if isExpanded {
                Text(event.body)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func badgeColor(for kind: LiveEventLog.ServiceKind) -> Color {
        switch kind {
        case .renderingControl: return .blue
        case .avTransport:      return .purple
        case .topology:         return .orange
        }
    }
}
