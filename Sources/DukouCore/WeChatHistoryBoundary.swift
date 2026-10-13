import Foundation

/// A short-lived navigation observation, not a persistent message identity.
/// The adapter supplies a fingerprint of role, identifier and text. Geometry
/// and AX child indices are deliberately excluded: scrolling rematerialises
/// rows and live arrivals can renumber them.
public struct WeChatHistoryRow: Equatable, Sendable {
    public enum Kind: String, Sendable { case message, notice, unresolved }
    public let kind: Kind
    public let fingerprint: String
    public let readable: Bool
    public let materialized: Bool
    public let selected: Bool

    public init(kind: Kind, fingerprint: String, readable: Bool = true,
                materialized: Bool = true, selected: Bool = false) {
        self.kind = kind
        self.fingerprint = fingerprint
        self.readable = readable
        self.materialized = materialized
        self.selected = selected
    }

    public var usable: Bool {
        readable && materialized && kind != .unresolved && !fingerprint.isEmpty
    }
}

/// Evidence about the loaded prefix THROUGH the current keyboard row. A
/// screen containing only timestamps/join notices is valid navigation input,
/// even though it is not a valid message-selection Page.
public enum WeChatHistoryPrefix {
    public enum Verdict: String, Sendable {
        case candidate, missing, unreadable, pending, olderMessage, aboveViewport
    }

    public static func judge(_ prefix: [WeChatHistoryRow], busy: Bool = false, leadingEdgeVisible: Bool = true) -> Verdict {
        guard !prefix.isEmpty else { return .missing }
        guard prefix.allSatisfy({ $0.readable && !$0.fingerprint.isEmpty }) else { return .unreadable }
        guard !busy, prefix.allSatisfy({ $0.materialized && $0.kind != .unresolved }) else { return .pending }
        guard prefix.dropLast().allSatisfy({ $0.kind == .notice }) else { return .olderMessage }
        guard leadingEdgeVisible else { return .aboveViewport }
        return .candidate
    }
}

/// Bounded QUIET evidence, used only after acknowledged Up/older-scroll probes
/// failed to advance focus. A missing virtual prefix alone is not an EOF
/// signal. Any changed prefix, failed read or pending row resets the proof.
/// This confirms the history the current client exposes, not server history
/// that the client has not made available through its UI.
public struct WeChatHistoryTopProbe: Sendable {
    public static let minimumQuietSeconds = 2.0
    public static let minimumObservations = 3
    private var prefix: [WeChatHistoryRow] = []
    private var since: Double?
    private var lastTime: Double?
    private var observations = 0

    public init() {}

    public mutating func observe(_ current: [WeChatHistoryRow], at now: Double, busy: Bool = false, leadingEdgeVisible: Bool = true) -> Bool {
        guard now.isFinite, WeChatHistoryPrefix.judge(current, busy: busy, leadingEdgeVisible: leadingEdgeVisible) == .candidate else {
            reset()
            return false
        }
        if let lastTime, now <= lastTime {
            reset()
            return false
        }
        if current != prefix || since == nil {
            prefix = current
            since = now
            observations = 0
        }
        observations += 1
        lastTime = now
        return observations >= Self.minimumObservations && now - (since ?? now) >= Self.minimumQuietSeconds
    }

    private mutating func reset() {
        prefix = []
        since = nil
        lastTime = nil
        observations = 0
    }
}

/// Undo ONLY the non-message rows actually crossed after the last counted
/// message. One Down is not generally enough: a group can begin with hundreds
/// of join notices. The route is verified in reverse, including multiplicity;
/// a wrong/recycled row aborts rather than selecting a convenient next bubble.
public struct WeChatHistoryRewind: Sendable {
    public enum Verdict: Equatable, Sendable { case continuing, arrived, mismatch }
    private let expected: [WeChatHistoryRow]
    private var position = 0
    private var rejected = false

    public init?(endpoint: WeChatHistoryRow, passedNotices: [WeChatHistoryRow]) {
        guard endpoint.usable, endpoint.kind == .message,
              passedNotices.allSatisfy({ $0.usable && $0.kind == .notice }) else { return nil }
        expected = passedNotices.isEmpty ? [] : Array(passedNotices.dropLast().reversed()) + [endpoint]
    }

    public var remaining: Int { expected.count - position }
    public var isComplete: Bool { !rejected && remaining == 0 }

    public mutating func accept(_ row: WeChatHistoryRow) -> Verdict {
        guard !rejected, position < expected.count, row.usable, row == expected[position] else {
            rejected = true
            return .mismatch
        }
        position += 1
        return remaining == 0 ? .arrived : .continuing
    }
}
