import XCTest
@testable import DukouCore

final class WeChatSessionStitchTests: XCTestCase {
    func testEmptyCollectionTakesTheFirstPage() {
        XCTAssertEqual(WeChatSessionStitch.merge([], with: ["A", "B"], scrolling: .down), .grown(["A", "B"], .down))
        XCTAssertEqual(WeChatSessionStitch.merge([], with: [], scrolling: .up), .unchanged)
    }

    func testDownwardPageAppendsOnlyTheNewTail() {
        XCTAssertEqual(
            WeChatSessionStitch.merge(["A", "B", "C"], with: ["B", "C", "D", "E"], scrolling: .down),
            .grown(["A", "B", "C", "D", "E"], .down)
        )
    }

    func testUpwardPagePrependsOnlyTheNewHead() {
        XCTAssertEqual(
            WeChatSessionStitch.merge(["C", "D"], with: ["A", "B", "C"], scrolling: .up),
            .grown(["A", "B", "C", "D"], .up)
        )
    }

    func testPageAlreadyInsideTheCollectionDoesNotGrow() {
        XCTAssertEqual(WeChatSessionStitch.merge(["A", "B", "C", "D"], with: ["B", "C"], scrolling: .down), .unchanged)
        XCTAssertEqual(WeChatSessionStitch.merge(["A", "B"], with: ["A", "B"], scrolling: .up), .unchanged)
    }

    func testAGapIsNotAppended() {
        XCTAssertEqual(WeChatSessionStitch.merge(["A", "B"], with: ["X", "Y"], scrolling: .down), .jumped)
    }

    func testRepeatedNamesKeepTheirOrder() {
        XCTAssertEqual(
            WeChatSessionStitch.merge(["A", "A", "B"], with: ["A", "B", "C"], scrolling: .down),
            .grown(["A", "A", "B", "C"], .down)
        )
    }

    func testAnAmbiguousStepFollowsTheScrollDirection() {
        XCTAssertEqual(
            WeChatSessionStitch.merge(["A", "B"], with: ["B", "A"], scrolling: .down),
            .grown(["A", "B", "A"], .down)
        )
        XCTAssertEqual(
            WeChatSessionStitch.merge(["A", "B"], with: ["B", "A"], scrolling: .up),
            .grown(["B", "A", "B"], .up)
        )
    }
}
