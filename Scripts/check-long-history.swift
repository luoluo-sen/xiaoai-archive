// Compile with -D LONG_HISTORY_STANDALONE and the production DukouCore files.
// This runner does not access WeChat, post events, or change app installation.
import Foundation

@main
struct CheckLongHistory {
    static func main() {
        let scenarios = LongHistoryScenarios.all()
        var failed = 0
        for scenario in scenarios {
            do { try scenario.run(); print("PASS: \(scenario.name)") }
            catch { failed += 1; print("FAIL: \(scenario.name): \(error)") }
        }
        print("\(scenarios.count - failed)/\(scenarios.count) long-history scenarios passed")
        exit(failed == 0 ? 0 : 1)
    }
}
