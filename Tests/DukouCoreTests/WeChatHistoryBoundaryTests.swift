import XCTest

final class WeChatHistoryBoundaryTests: XCTestCase {
    func testNoticeOnlyViewport() throws { try HistoryBoundaryScenarios.noticeOnlyViewport() }
    func testFirstBubbleAfterNotices() throws { try HistoryBoundaryScenarios.firstBubbleAfterNotices() }
    func testOlderBubbleIsNotEOF() throws { try HistoryBoundaryScenarios.olderBubbleIsNotEOF() }
    func testVirtualPrefixIsPending() throws { try HistoryBoundaryScenarios.virtualPrefixIsPending() }
    func testUnreadablePrefix() throws { try HistoryBoundaryScenarios.unreadablePrefix() }
    func testBusyList() throws { try HistoryBoundaryScenarios.busyList() }
    func testChangedPrefixResets() throws { try HistoryBoundaryScenarios.changedPrefixResets() }
    func testFailureResets() throws { try HistoryBoundaryScenarios.failureResets() }
    func testObservationCountNeedsTime() throws { try HistoryBoundaryScenarios.observationCountNeedsTime() }
    func testElapsedTimeNeedsObservations() throws { try HistoryBoundaryScenarios.elapsedTimeNeedsObservations() }
    func testInvalidClock() throws { try HistoryBoundaryScenarios.invalidClock() }
    func testMissingList() throws { try HistoryBoundaryScenarios.missingList() }
    func testZeroSeparators() throws { try HistoryBoundaryScenarios.zeroSeparators() }
    func testOneSeparator() throws { try HistoryBoundaryScenarios.oneSeparator() }
    func testManyNotices() throws { try HistoryBoundaryScenarios.manyNotices() }
    func testRepeatedNotices() throws { try HistoryBoundaryScenarios.repeatedNotices() }
    func testWrongMessage() throws { try HistoryBoundaryScenarios.wrongMessage() }
    func testChangedNotice() throws { try HistoryBoundaryScenarios.changedNotice() }
    func testSelectedAnchor() throws { try HistoryBoundaryScenarios.selectedAnchor() }
    func testChangedSelection() throws { try HistoryBoundaryScenarios.changedSelection() }
    func testUnresolvedRoute() throws { try HistoryBoundaryScenarios.unresolvedRoute() }
    func testDelayedHistory() throws { try HistoryBoundaryScenarios.delayedHistory() }
    func testExactBatchBoundary() throws { try HistoryBoundaryScenarios.exactBatchBoundary() }
    func testOffscreenArrivals() throws { try HistoryBoundaryScenarios.offscreenArrivals() }
    func testLeadingEdgeMustBeVisible() throws { try HistoryBoundaryScenarios.leadingEdgeMustBeVisible() }
}
