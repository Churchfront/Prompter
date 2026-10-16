#if canImport(XCTest)
import XCTest
@testable import TeleprompterCore

/// Runs the shared scenarios under XCTest (Product > Test in Xcode, or `swift test`).
final class TeleprompterCoreTests: XCTestCase {

    private func run(_ entries: [(String, () -> ScenarioReport)]) {
        for (name, scenario) in entries {
            let report = scenario()
            XCTAssertTrue(report.passed, "\(name): \(report.failures.joined(separator: "; "))")
        }
    }

    func testUnitChecks() { run(UnitChecks.all) }

    func testAcceptanceScenarios() { run(AcceptanceScenarios.all) }

    func testVoiceCommands() { run(VoiceCommandChecks.all) }
}
#endif
