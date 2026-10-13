import Foundation

/// Joins successive visible pages of a virtualized conversation list.
///
/// Pages are top-to-bottom. A scroll that stays inside rows already collected
/// adds nothing. A scroll that skips the overlap is rejected instead of
/// appending a gap.
public enum WeChatSessionStitch {
    public enum Direction: Sendable, Equatable { case down, up }

    public enum Merge: Sendable, Equatable {
        case grown([String], Direction)
        case unchanged
        case jumped
    }

    /// `scrolling` breaks a tie where the same page can be read as moving
    /// either way. A page that only fits one way reports that way.
    public static func merge(_ collected: [String], with page: [String], scrolling: Direction) -> Merge {
        if collected.isEmpty { return page.isEmpty ? .unchanged : .grown(page, scrolling) }
        if page.isEmpty || contains(collected, window: page) { return .unchanged }
        let down = overlap(tail: collected, head: page)
        let up = overlap(tail: page, head: collected)
        let extendsDown = down > 0 && page.count > down
        let extendsUp = up > 0 && page.count > up
        switch (extendsDown, extendsUp) {
        case (true, false):
            return .grown(collected + page.dropFirst(down), .down)
        case (false, true):
            return .grown(Array(page.dropLast(up)) + collected, .up)
        case (true, true):
            let downward = down > up || (down == up && scrolling == .down)
            if downward { return .grown(collected + page.dropFirst(down), .down) }
            return .grown(Array(page.dropLast(up)) + collected, .up)
        case (false, false):
            return .jumped
        }
    }

    private static func overlap(tail: [String], head: [String]) -> Int {
        let limit = min(tail.count, head.count)
        guard limit > 0 else { return 0 }
        var best = 0
        for length in 1...limit where Array(tail.suffix(length)) == Array(head.prefix(length)) {
            best = length
        }
        return best
    }

    private static func contains(_ collected: [String], window page: [String]) -> Bool {
        guard !page.isEmpty, page.count <= collected.count else { return false }
        let last = collected.count - page.count
        for start in 0...last where Array(collected[start..<(start + page.count)]) == page {
            return true
        }
        return false
    }
}
