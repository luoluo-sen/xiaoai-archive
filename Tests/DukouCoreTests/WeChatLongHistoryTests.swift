import XCTest
@testable import DukouCore

final class WeChatLongHistoryTests: XCTestCase {
    func testSharedLongHistoryScenarios() {
        for scenario in LongHistoryScenarios.all() {
            XCTAssertNoThrow(try scenario.run(), scenario.name)
        }
    }
}
