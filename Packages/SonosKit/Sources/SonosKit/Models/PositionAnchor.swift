/// PositionAnchor.swift — Authoritative playhead anchor.
///
/// Anchor + per-frame wall-clock projection eliminates the discrete
/// jumps that earlier polling-based displays produced. Between
/// authoritative updates, `projected(at:)` extrapolates monotonically;
/// authoritative events only rebase the anchor when drift exceeds the
/// noise floor (see `SonosManager.updatePositionAnchorFromAuthoritative`).
import Foundation

public struct PositionAnchor: Equatable, Sendable {
    /// Track position the speaker reported at `wallClock` (or 0 if
    /// uninitialised). Frozen during pause.
    public var time: TimeInterval
    /// Local wall-clock instant when `time` was received. Projection
    /// uses `now - wallClock` as the elapsed since-anchor delta.
    public var wallClock: Date
    /// Whether the speaker is actively advancing the playhead. When
    /// false, `projected(at:)` returns `time` unchanged.
    public var isPlaying: Bool

    public init(time: TimeInterval, wallClock: Date, isPlaying: Bool) {
        self.time = time
        self.wallClock = wallClock
        self.isPlaying = isPlaying
    }

    public static let zero = PositionAnchor(time: 0, wallClock: .distantPast, isPlaying: false)

    /// Continuous wall-clock-projected position. Returns `time`
    /// directly when paused or before the first authoritative report.
    /// Clamps non-negative — for tracks just past zero a stale
    /// `wallClock` (off by a frame) could otherwise underflow.
    public func projected(at now: Date) -> TimeInterval {
        guard isPlaying, wallClock != .distantPast else { return time }
        return max(0, time + now.timeIntervalSince(wallClock))
    }
}
