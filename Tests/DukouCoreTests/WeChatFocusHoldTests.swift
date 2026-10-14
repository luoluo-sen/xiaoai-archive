import XCTest
@testable import DukouCore

final class WeChatFocusHoldTests: XCTestCase {
    private func message(_ texts: [String], y: Double = 200, height: Double = 80, selected: Bool = false, ordinal: Int = 99) -> WeChatFocusedMessage {
        WeChatFocusedMessage(identifier: "chat_bubble_item_view", role: "AXCheckBox", texts: texts, y: y, height: height, selected: selected, ordinal: ordinal)
    }

    func testSameMessageHoldsWhenThePointerIsReplacedAndTheNudgeMatches() {
        let target = message(["现在开始就不稳"], y: 209, height: 585)
        let rematerialised = message(["现在开始就不稳"], y: 225, height: 585)
        XCTAssertEqual(WeChatFocusHold.judge(current: rematerialised, target: target, elementMatches: false, expectedShift: 16, slack: 12), .held)
        XCTAssertTrue(WeChatFocusHold.identifies(rematerialised, as: target))
    }

    func testSamePointerWithDifferentTextIsRecycledNotHeld() {
        let target = message(["第一条"], y: 200, height: 80)
        let recycled = message(["入群提示旁边的另一条"], y: 200, height: 80)
        XCTAssertEqual(WeChatFocusHold.judge(current: recycled, target: target, elementMatches: true, expectedShift: 0, slack: 4), .recycled)
        XCTAssertFalse(WeChatFocusHold.identifies(recycled, as: target))
    }

    func testEmptyTextNeverProvesABubble() {
        let blank = message([""], y: 200, height: 240)
        XCTAssertEqual(WeChatFocusHold.judge(current: blank, target: blank, elementMatches: true, expectedShift: 0, slack: 4), .unreadable)
        let picture = message(["图片"], y: 200, height: 240)
        XCTAssertEqual(WeChatFocusHold.judge(current: blank, target: picture, elementMatches: true, expectedShift: 0, slack: 4), .unreadable)
    }

    func testAJumpToAnotherCopyOfTheSameTextIsNotTheTrackedMessage() {
        let target = message(["图片"], y: 200, height: 240)
        let nextPhoto = message(["图片"], y: 440, height: 240)
        XCTAssertEqual(WeChatFocusHold.judge(current: nextPhoto, target: target, elementMatches: false, expectedShift: 16, slack: 12), .jumped)
    }

    func testAnUnmovedListIsTheSameMessageAndNotASuccessfulNudge() {
        let target = message(["一条"], y: 209, height: 80)
        XCTAssertEqual(WeChatFocusHold.judge(current: target, target: target, elementMatches: true, expectedShift: 16, slack: 8), .unmoved)
        XCTAssertEqual(WeChatFocusHold.judge(current: target, target: target, elementMatches: false, expectedShift: 0, slack: 4), .held)
    }

    func testSelectionChangingDoesNotMakeItADifferentMessage() {
        let before = message(["一条"], selected: false)
        var after = before
        after.selected = true
        XCTAssertTrue(WeChatFocusHold.identifies(after, as: before))
    }

    func testSnapshotRejectsEmptyTextOverlapAndAMissingList() {
        XCTAssertEqual(WeChatPageSample.reject(listFound: false, rows: []), .listMissing)
        XCTAssertEqual(WeChatPageSample.reject(listFound: true, rows: []), .noRows)
        XCTAssertEqual(WeChatPageSample.reject(listFound: true, rows: [
            WeChatVisibleSample(readOK: false, textEmpty: false, y: 10),
        ]), .readFailed)
        XCTAssertEqual(WeChatPageSample.reject(listFound: true, rows: [
            WeChatVisibleSample(readOK: true, textEmpty: false, y: 10),
            WeChatVisibleSample(readOK: true, textEmpty: true, y: 90),
        ]), .emptyText)
        XCTAssertEqual(WeChatPageSample.reject(listFound: true, rows: [
            WeChatVisibleSample(readOK: true, textEmpty: false, y: 100),
            WeChatVisibleSample(readOK: true, textEmpty: false, y: 100),
        ]), .overlappingY)
        XCTAssertNil(WeChatPageSample.reject(listFound: true, rows: [
            WeChatVisibleSample(readOK: true, textEmpty: false, y: 10),
            WeChatVisibleSample(readOK: true, textEmpty: false, y: 90),
        ]))
    }

    func testRangeCapIsNeverReportedAsTheSelectButton() {
        XCTAssertEqual(WeChatRangeControlLabel.parse(["选择到这里"]), .selectHere)
        XCTAssertEqual(WeChatRangeControlLabel.parse(["最多选择 100 条"]), .capped)
        XCTAssertEqual(WeChatRangeControlLabel.parse(["最多选择100条", "选择到这里"]), .capped)
        XCTAssertEqual(WeChatRangeControlLabel.parse(["取消"]), .missing)
        XCTAssertEqual(WeChatRangeControlLabel.parse([]), .missing)
    }

    func testClearanceNudgeStaysInsideOneSmallStepTowardOlderMessages() {
        XCTAssertNil(WeChatFocusClearance.olderNudge(rowY: 108, listTop: 100))
        XCTAssertEqual(WeChatFocusClearance.olderNudge(rowY: 100, listTop: 100), 16)
        XCTAssertEqual(WeChatFocusClearance.olderNudge(rowY: 104, listTop: 100), 12)
        XCTAssertEqual(WeChatFocusClearance.olderNudge(rowY: 40, listTop: 100), 30)
        XCTAssertEqual(WeChatNudge.units(points: 20, gain: 1.5), 13)
        XCTAssertEqual(WeChatNudge.units(points: 10, gain: 5), 2)
        // An implausible gain must not become a gesture WeChat clamps.
        XCTAssertEqual(WeChatNudge.units(points: 20, gain: 0.05), 13)
    }

    func testEachBatchKeepsItsOwnNudgeBudget() {
        XCTAssertTrue(WeChatFocusClearance.allowsAnotherAttempt(0))
        XCTAssertTrue(WeChatFocusClearance.allowsAnotherAttempt(2))
        XCTAssertFalse(WeChatFocusClearance.allowsAnotherAttempt(3))
        // Three earlier batches of 100 do not spend the next batch's attempts.
        XCTAssertTrue(WeChatFocusClearance.allowsAnotherAttempt(0))
    }

    func testAPinnedKeyboardRowAsksForAboutOneRowOfClearance() {
        XCTAssertEqual(WeChatFocusClearance.pinnedClearance(rowHeight: 79), 79)
        XCTAssertEqual(WeChatFocusClearance.pinnedClearance(rowHeight: 289), 140)
        XCTAssertEqual(WeChatFocusClearance.pinnedClearance(rowHeight: 20), 48)
        XCTAssertEqual(WeChatNudge.units(points: 79, gain: 1.5, limit: 140, maxUnits: 100), 53)
        XCTAssertEqual(WeChatNudge.units(points: 20, gain: 1.5), 13)
    }

    func testAnIgnoredNudgeGrowsWithoutLeavingTheSmallStepCap() {
        XCTAssertEqual(WeChatNudge.retryPoints(base: 16, attempt: 0), 16)
        XCTAssertEqual(WeChatNudge.retryPoints(base: 16, attempt: 1), 24)
        XCTAssertEqual(WeChatNudge.retryPoints(base: 16, attempt: 2), 30)
        XCTAssertEqual(WeChatNudge.retryPoints(base: 16, attempt: 5), 30)
        XCTAssertEqual(WeChatNudge.retryPoints(base: 12, attempt: 1), 18)
        XCTAssertEqual(WeChatNudge.retryPoints(base: 40, attempt: 0), 30)
        XCTAssertEqual(WeChatNudge.retryPoints(base: 4, attempt: 0), WeChatFocusClearance.capNudge)
    }

    func testOnlyASettledViewportMayStartAnotherBatch() {
        XCTAssertTrue(WeChatBatchBoundary.resumeNextBatch(boundaryConfirmed: true, reachedHistoryStart: false))
        XCTAssertFalse(WeChatBatchBoundary.resumeNextBatch(boundaryConfirmed: true, reachedHistoryStart: true))
        XCTAssertFalse(WeChatBatchBoundary.resumeNextBatch(boundaryConfirmed: false, reachedHistoryStart: false))
        XCTAssertTrue(WeChatBatchBoundary.warnStoppedEarly(boundaryConfirmed: false, reachedHistoryStart: false, requestSatisfied: false))
        XCTAssertFalse(WeChatBatchBoundary.warnStoppedEarly(boundaryConfirmed: false, reachedHistoryStart: true, requestSatisfied: false))
        XCTAssertFalse(WeChatBatchBoundary.warnStoppedEarly(boundaryConfirmed: false, reachedHistoryStart: false, requestSatisfied: true))
        XCTAssertFalse(WeChatBatchBoundary.warnStoppedEarly(boundaryConfirmed: true, reachedHistoryStart: false, requestSatisfied: false))
        XCTAssertTrue(WeChatBatchBoundary.finishedShort(requested: 1000, actual: 230, historyStartProved: true))
        XCTAssertTrue(WeChatBatchBoundary.finishedShort(requested: nil, actual: 230, historyStartProved: true))
        XCTAssertFalse(WeChatBatchBoundary.finishedShort(requested: 1000, actual: 230, historyStartProved: false))
        XCTAssertFalse(WeChatBatchBoundary.finishedShort(requested: 100, actual: 100, historyStartProved: true))
    }
}
