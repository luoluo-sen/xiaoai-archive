// Build with the production boundary policy and shared scenarios; see
// docs/history-boundary-fix.md. No XCTest or WeChat UI access is needed.
import Foundation

@main
struct CheckHistoryBoundary {
    static func main() throws {
        var failed: [String] = []
        let cases = HistoryBoundaryScenarios.cases
        for (name, run) in cases {
            do { try run(); print("PASS: \(name)") }
            catch { failed.append(name); print("FAIL: \(name): \(error)") }
        }
        print("\(cases.count - failed.count)/\(cases.count) boundary scenarios passed")
        if !failed.isEmpty { throw HistoryBoundaryScenarios.Failure(description: failed.joined(separator: ", ")) }
    }
}
