import CryptoKit
import Foundation

/// A content fingerprint, not a WeChat message id. Minute timestamps collide,
/// and so do repeated texts; only an ordered run of these can mark a boundary.
public enum WeChatMessageFingerprint {
    public static func minute(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    public static func make(sender: String, date: Date, text: String) -> String {
        let payload = "\(sender)\u{1e}\(minute(date))\u{1e}\(text)"
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func make(_ record: WeChatTranscriptRecord) -> String {
        make(sender: record.sender, date: record.date, text: record.text)
    }
}

/// Where a successful archive of one chat ended. Independent of the prompt
/// cursor: saving messages and an agent having read them are different facts.
public struct WeChatArchiveCheckpoint: Codable, Hashable, Sendable {
    /// How many newest messages are remembered. Longer than the match window
    /// so an ambiguous short run can be extended without another export.
    public static let tailLength = 20

    /// Minute of the newest archived message.
    public var watermark: Date
    /// Chronological. The last hash is the newest archived message.
    public var tail: [String]
    public var updatedAt: Date

    public init(watermark: Date, tail: [String], updatedAt: Date = Date()) {
        self.watermark = watermark
        self.tail = tail
        self.updatedAt = updatedAt
    }

    public static func baseline(from records: [WeChatTranscriptRecord], at date: Date = Date()) -> Self? {
        guard let newest = records.last else { return nil }
        let tail = records.suffix(tailLength).map(WeChatMessageFingerprint.make)
        return Self(watermark: newest.date, tail: tail, updatedAt: date)
    }

    /// New messages are strictly after the matched boundary. A short addition
    /// keeps the older hashes so the next search still has a full tail.
    public func advanced(by records: [WeChatTranscriptRecord], at date: Date = Date()) -> Self {
        guard let newest = records.last else { return self }
        let combined = tail + records.map(WeChatMessageFingerprint.make)
        return Self(watermark: newest.date, tail: Array(combined.suffix(Self.tailLength)), updatedAt: date)
    }
}

public struct WeChatArchiveCheckpoints: Codable, Hashable, Sendable {
    public static let limit = 200
    public private(set) var chats: [String: WeChatArchiveCheckpoint]

    public init(chats: [String: WeChatArchiveCheckpoint] = [:]) {
        self.chats = chats
    }

    public func checkpoint(for chat: String) -> WeChatArchiveCheckpoint? {
        chats[WeChatForwardPreset.normalizedChat(chat)]
    }

    public mutating func replace(_ chat: String, with records: [WeChatTranscriptRecord], at date: Date = Date()) {
        let key = WeChatForwardPreset.normalizedChat(chat)
        guard !key.isEmpty, let baseline = WeChatArchiveCheckpoint.baseline(from: records, at: date) else { return }
        store(baseline, for: key)
    }

    public mutating func advance(_ chat: String, by records: [WeChatTranscriptRecord], at date: Date = Date()) {
        let key = WeChatForwardPreset.normalizedChat(chat)
        guard !key.isEmpty, records.isEmpty == false, let existing = chats[key] else { return }
        store(existing.advanced(by: records, at: date), for: key)
    }

    private mutating func store(_ checkpoint: WeChatArchiveCheckpoint, for key: String) {
        chats[key] = checkpoint
        guard chats.count > Self.limit else { return }
        for stale in chats.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(chats.count - Self.limit) {
            chats[stale.key] = nil
        }
    }
}

/// Whether a saved tail occurs once inside a chronological export.
///
/// The search starts at eight fingerprints (or the whole tail, if shorter)
/// and only grows. A shorter slice is never accepted after a longer one was
/// ambiguous: repeated 「收到」 must not become a boundary by being less specific.
public enum WeChatSequenceMatch {
    public static let preferredLength = 8

    public enum Outcome: Equatable, Sendable {
        /// `matchStart` is the first haystack index of the matched run.
        /// Messages at and after `matchStart + overlap` are newer than the archive.
        case found(matchStart: Int, overlap: Int)
        case notFound
        case ambiguous
    }

    public static func locate(checkpoint tail: [String], in haystack: [String]) -> Outcome {
        guard !tail.isEmpty, !haystack.isEmpty else { return .notFound }
        let start = min(preferredLength, tail.count)
        var length = start
        while length <= tail.count {
            let needle = Array(tail.suffix(length))
            let hits = occurrences(of: needle, in: haystack)
            if hits.count == 1 { return .found(matchStart: hits[0], overlap: length) }
            if hits.isEmpty { return length == start ? .notFound : .ambiguous }
            length += 1
        }
        return .ambiguous
    }

    private static func occurrences(of needle: [String], in haystack: [String]) -> [Int] {
        guard needle.count <= haystack.count else { return [] }
        var hits: [Int] = []
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            hits.append(start)
        }
        return hits
    }
}

public struct WeChatIncrementCut: Equatable, Sendable {
    /// Chronological records to leave out of the delivered archive.
    public let dropPrefix: Int
    public let retained: Int
    public let overlap: Int

    public init(dropPrefix: Int, retained: Int, overlap: Int) {
        self.dropPrefix = dropPrefix
        self.retained = retained
        self.overlap = overlap
    }
}

public enum WeChatIncrementAssessment: Equatable, Sendable {
    /// The archived tail is still newer than anything in this export.
    case keepCollecting
    case ready(WeChatIncrementCut)
    /// A minute at or before the watermark was reached, or a repeated run
    /// could not be made unique. Not a completed increment.
    case uncertain
}

public enum WeChatIncrement {
    /// `records` are chronological, oldest first, across every batch so far.
    /// A shared minute never ends the search by itself.
    public static func assess(checkpoint: WeChatArchiveCheckpoint, records: [WeChatTranscriptRecord]) -> WeChatIncrementAssessment {
        guard !records.isEmpty else { return .keepCollecting }
        let haystack = records.map(WeChatMessageFingerprint.make)
        switch WeChatSequenceMatch.locate(checkpoint: checkpoint.tail, in: haystack) {
        case .found(let start, let overlap):
            let end = start + overlap
            return .ready(WeChatIncrementCut(dropPrefix: end, retained: haystack.count - end, overlap: overlap))
        case .ambiguous:
            return .uncertain
        case .notFound:
            guard let oldest = records.map(\.date).min() else { return .keepCollecting }
            if WeChatMessageFingerprint.minute(oldest) > WeChatMessageFingerprint.minute(checkpoint.watermark) {
                return .keepCollecting
            }
            return .uncertain
        }
    }
}
