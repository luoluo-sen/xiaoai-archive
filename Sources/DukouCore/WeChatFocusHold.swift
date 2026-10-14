import Foundation

/// The keyboard row a counted walk stopped on.
///
/// An accessibility element pointer is not an identity. Qt recycles virtual
/// cells, so the same pointer can draw a different message, and the same
/// message can come back as a new pointer. Text, role and height are the
/// identity; vertical position is only how far a viewport nudge moved it.
public struct WeChatFocusedMessage: Equatable, Sendable {
    public var identifier: String
    public var role: String
    public var texts: [String]
    public var y: Double
    public var height: Double
    public var selected: Bool
    public var ordinal: Int

    public init(identifier: String, role: String, texts: [String], y: Double, height: Double, selected: Bool, ordinal: Int) {
        self.identifier = identifier
        self.role = role
        self.texts = texts
        self.y = y
        self.height = height
        self.selected = selected
        self.ordinal = ordinal
    }
}

public enum WeChatFocusVerdict: Equatable, Sendable {
    /// Same message, and its movement matches the nudge that was asked for.
    case held
    /// Same message, but the viewport did not move.
    case unmoved
    /// The pointer still names a cell, and the cell is now a different message.
    case recycled
    case replaced
    /// Empty text cannot distinguish one bubble from the next.
    case unreadable
    /// The text matches a message, but not the one this nudge was tracking.
    case jumped
}

public enum WeChatFocusHold {
    /// `elementMatches` is never proof by itself. A recycled cell keeps the
    /// pointer. A rematerialised row keeps the text and drops the pointer.
    public static func judge(current: WeChatFocusedMessage, target: WeChatFocusedMessage, elementMatches: Bool, expectedShift: Double, slack: Double) -> WeChatFocusVerdict {
        guard current.identifier == "chat_bubble_item_view", current.role == "AXCheckBox",
              current.identifier == target.identifier, current.role == target.role else { return .replaced }
        guard current.texts.contains(where: { !$0.isEmpty }) else { return .unreadable }
        guard current.texts == target.texts, abs(current.height - target.height) < 3 else {
            return elementMatches ? .recycled : .replaced
        }
        let shift = current.y - target.y
        if abs(shift - expectedShift) <= slack { return .held }
        if abs(expectedShift) > slack, abs(shift) <= slack { return .unmoved }
        return .jumped
    }

    /// Identity without position. Selection flips from off to on when the
    /// range control runs; that change is not a different message.
    public static func identifies(_ current: WeChatFocusedMessage, as target: WeChatFocusedMessage) -> Bool {
        current.identifier == "chat_bubble_item_view"
            && current.role == "AXCheckBox"
            && current.identifier == target.identifier
            && current.role == target.role
            && current.texts.contains(where: { !$0.isEmpty })
            && current.texts == target.texts
            && abs(current.height - target.height) < 3
    }
}

/// Why one reading of the visible bubbles cannot be half of a settled pair.
/// A well-formed reading still has to match the next one; that mismatch is
/// `pageChanged`, and only the caller knows it.
public enum WeChatSnapshotReject: String, Sendable {
    case emptyText
    case overlappingY
    case readFailed
    case noRows
    case listMissing
    case pageChanged
}

public struct WeChatVisibleSample: Equatable, Sendable {
    public var readOK: Bool
    public var textEmpty: Bool
    public var y: Double

    public init(readOK: Bool, textEmpty: Bool, y: Double) {
        self.readOK = readOK
        self.textEmpty = textEmpty
        self.y = y
    }
}

public enum WeChatPageSample {
    public static func reject(listFound: Bool, rows: [WeChatVisibleSample]) -> WeChatSnapshotReject? {
        guard listFound else { return .listMissing }
        guard !rows.isEmpty else { return .noRows }
        if rows.contains(where: { !$0.readOK }) { return .readFailed }
        if rows.contains(where: \.textEmpty) { return .emptyText }
        if zip(rows, rows.dropFirst()).contains(where: { $0.y >= $1.y }) { return .overlappingY }
        return nil
    }
}

public enum WeChatRangeControlLabel: String, Sendable {
    case selectHere
    case capped
    case missing

    /// The cap is not a button that selects the batch. It wins over any other
    /// label on the same control so a caller cannot press it by mistake.
    public static func parse(_ labels: [String]) -> WeChatRangeControlLabel {
        let compact = labels.map { $0.filter { !$0.isWhitespace } }
        if compact.contains("最多选择100条") { return .capped }
        if compact.contains("选择到这里") { return .selectHere }
        return .missing
    }
}

public enum WeChatFocusClearance {
    public static let minimum = 8.0
    public static let preferred = 16.0
    public static let maximumAttempts = 3
    /// A cap with the bubble already clear of the edge still gets one small
    /// shove toward older messages, never a step the size of a navigation scroll.
    public static let capNudge = 10.0
    /// A keyboard-pinned row ignores a few points of scroll and stays glued to
    /// the top edge. One short row is enough to leave the range button's inset
    /// without sending the endpoint off this screen. Taller bubbles stop here.
    public static let pinnedScrollLimit = 140.0

    public static func pinnedClearance(rowHeight: Double) -> Double {
        let row = rowHeight.isFinite && rowHeight > 0 ? rowHeight : 80
        return min(pinnedScrollLimit, max(48, row))
    }

    /// Each batch owns this many viewport nudges. Earlier batches in the same
    /// chat must not spend them: a keyboard walk pins every 100th message on
    /// the top edge, so every batch needs its own clearance.
    public static func allowsAnotherAttempt(_ batchAttempts: Int) -> Bool {
        batchAttempts < maximumAttempts
    }

    /// Points to scroll toward older messages so the bubble's top sits about
    /// `preferred` below the list's top. Nil when the gap is already usable.
    /// One attempt never asks for more than 30 points; a bubble sitting far
    /// above the edge takes another attempt rather than one large gesture.
    public static func olderNudge(rowY: Double, listTop: Double) -> Double? {
        let gap = rowY - listTop
        guard gap < minimum else { return nil }
        return min(30, max(capNudge, preferred - gap))
    }
}

public enum WeChatNudge {
    /// Scroll units whose expected movement is `points`, using the run's
    /// measured gain. An unmeasured or implausible gain uses the engine's
    /// starting 1.5 rather than a gesture large enough to clamp.
    public static func units(points: Double, gain: Double, limit: Double = 30, maxUnits: Int32 = 40) -> Int32 {
        let clamped = min(limit, max(WeChatFocusClearance.capNudge, points))
        let safeGain = WeChatScrollStep.isPlausible(gain: gain) ? gain : 1.5
        let units = Int((clamped / safeGain).rounded())
        return Int32(max(1, min(Int(maxUnits), units)))
    }

    /// Attempt 0 asks for the clearance the row still needs. A gesture the
    /// list ignored grows by half on the next try, and stops at 30 points so
    /// the keyboard row stays on this screen.
    public static func retryPoints(base: Double, attempt: Int) -> Double {
        var points = min(30, max(WeChatFocusClearance.capNudge, base))
        for _ in 0..<max(0, attempt) {
            points = min(30, points * 1.5)
        }
        return points
    }
}

public enum WeChatBatchBoundary {
    /// A request for more messages than the conversation holds finishes with
    /// the real count once the first message is proved. An unproved stall is
    /// not that finish: the run must not report the request as complete.
    public static func finishedShort(requested: Int?, actual: Int, historyStartProved: Bool) -> Bool {
        guard historyStartProved, actual > 0 else { return false }
        guard let requested else { return true }
        return actual < requested
    }

    /// The next batch resumes only from a viewport two identical snapshots
    /// agreed on. Reaching the first message is a finished walk, not a
    /// boundary to resume. A focus-only proof exports the batch it checked
    /// and then stops: the transcript count is not a substitute viewport.
    public static func resumeNextBatch(boundaryConfirmed: Bool, reachedHistoryStart: Bool) -> Bool {
        boundaryConfirmed && !reachedHistoryStart
    }

    /// Warn only when a further batch was still owed. A finished count, and a
    /// walk that proved it had reached the first message, already explain
    /// themselves.
    public static func warnStoppedEarly(boundaryConfirmed: Bool, reachedHistoryStart: Bool, requestSatisfied: Bool) -> Bool {
        !boundaryConfirmed && !reachedHistoryStart && !requestSatisfied
    }
}
