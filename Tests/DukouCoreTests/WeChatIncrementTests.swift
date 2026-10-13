import XCTest
@testable import DukouCore

final class WeChatIncrementTests: XCTestCase {
    private func record(_ sender: String, _ minute: String, _ text: String) -> WeChatTranscriptRecord {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return WeChatTranscriptRecord(sender: sender, date: formatter.date(from: minute)!, text: text)
    }

    private func checkpoint(_ records: [WeChatTranscriptRecord]) -> WeChatArchiveCheckpoint {
        WeChatArchiveCheckpoint.baseline(from: records, at: Date(timeIntervalSince1970: 0))!
    }

    func testFingerprintUsesTheMinuteAndTheWholeBody() {
        let photo = record("李四", "2026-10-12 11:06", "[图片] a.png")
        let sameMinute = record("王五", "2026-10-12 11:06", "我补充一个问题")
        XCTAssertNotEqual(WeChatMessageFingerprint.make(photo), WeChatMessageFingerprint.make(sameMinute))
        let laterSecond = WeChatTranscriptRecord(sender: "王五", date: photo.date.addingTimeInterval(30), text: "我补充一个问题")
        XCTAssertEqual(
            WeChatMessageFingerprint.minute(photo.date),
            WeChatMessageFingerprint.minute(laterSecond.date)
        )
        XCTAssertNotEqual(WeChatMessageFingerprint.make(sameMinute), WeChatMessageFingerprint.make(laterSecond))
    }

    func testSameMinuteAfterTheMatchedRunIsKept() {
        let archived = [
            record("张三", "2026-10-12 11:05", "项目已经提交"),
            record("李四", "2026-10-12 11:06", "收到"),
        ]
        let saved = checkpoint(archived)
        let incoming = archived + [
            record("王五", "2026-10-12 11:06", "我补充一个问题"),
            record("张三", "2026-10-12 11:07", "好的"),
        ]
        guard case .ready(let cut) = WeChatIncrement.assess(checkpoint: saved, records: incoming) else {
            return XCTFail("expected a boundary")
        }
        XCTAssertEqual(cut.dropPrefix, 2)
        XCTAssertEqual(cut.retained, 2)
        XCTAssertEqual(cut.overlap, 2)
    }

    func testARepeatedSuffixGrowsUntilOneAlignmentRemains() {
        let head = (0..<6).map { record("甲", "2026-10-12 10:\(String(format: "%02d", $0))", "前\($0)") }
        let tail = head + (0..<8).map { record("乙", "2026-10-12 11:\(String(format: "%02d", $0))", "句\($0)") }
        let saved = checkpoint(tail)
        let incoming = Array(tail.suffix(8)) + tail + [record("王五", "2026-10-12 12:00", "新的")]
        guard case .ready(let cut) = WeChatIncrement.assess(checkpoint: saved, records: incoming) else {
            return XCTFail("expected the longer tail to pick one alignment")
        }
        XCTAssertEqual(cut.retained, 1)
        XCTAssertGreaterThan(cut.overlap, WeChatSequenceMatch.preferredLength)
    }

    func testStillAmbiguousWhenTheWholeTailOccursTwice() {
        let tail = (0..<8).map { record("甲", "2026-10-12 12:\(String(format: "%02d", $0))", "收到\($0)") }
        let saved = checkpoint(tail)
        let incoming = tail + tail
        XCTAssertEqual(WeChatIncrement.assess(checkpoint: saved, records: incoming), .uncertain)
    }

    func testNewerBatchAloneDoesNotStopOnTheWatermark() {
        let saved = checkpoint([
            record("甲", "2026-10-12 11:00", "旧"),
            record("乙", "2026-10-12 11:06", "边界"),
        ])
        let newer = [
            record("丙", "2026-10-12 11:10", "新一"),
            record("丁", "2026-10-12 11:11", "新二"),
        ]
        XCTAssertEqual(WeChatIncrement.assess(checkpoint: saved, records: newer), .keepCollecting)
    }

    func testPassingTheWatermarkWithoutARunIsUncertain() {
        let saved = checkpoint([
            record("甲", "2026-10-12 11:00", "旧"),
            record("乙", "2026-10-12 11:06", "边界"),
        ])
        let other = [
            record("丙", "2026-10-12 10:50", "另一段历史"),
            record("丁", "2026-10-12 11:12", "新"),
        ]
        XCTAssertEqual(WeChatIncrement.assess(checkpoint: saved, records: other), .uncertain)
    }

    func testAdvanceKeepsOlderFingerprintsWhenFewMessagesAreNew() {
        let archived = (0..<20).map { record("甲", "2026-10-12 10:\(String(format: "%02d", $0))", "旧\($0)") }
        let saved = checkpoint(archived)
        let added = [record("乙", "2026-10-12 11:00", "新")]
        let next = saved.advanced(by: added)
        XCTAssertEqual(next.tail.count, 20)
        XCTAssertEqual(next.tail.dropLast(), saved.tail.dropFirst())
        XCTAssertEqual(next.tail.last, WeChatMessageFingerprint.make(added[0]))
        XCTAssertEqual(WeChatMessageFingerprint.minute(next.watermark), WeChatMessageFingerprint.minute(added[0].date))
    }
}
