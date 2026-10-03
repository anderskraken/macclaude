import AppKit
import XCTest
import MacClaudeCore
@testable import MacClaude

final class PresentationTests: XCTestCase {
    func testTransferCompatibilityRequiresAnExactReviewedVersion() {
        XCTAssertTrue(AccountAvailability.supportsTransfers(version: "2.9939.4"))
        XCTAssertTrue(AccountAvailability.supportsTransfers(version: "2.19675.0"))
        for version in [nil, "", "2.16120.0", "2.19675", "2.19675.1", "3.0.0"] as [String?] {
            XCTAssertFalse(AccountAvailability.supportsTransfers(version: version))
        }
    }

    func testUsageKeepsSourceAgeAndLabelsUtilizationAsUsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = UsagePresentation(.init(observedAt: now.addingTimeInterval(-180), sessionPercent: 20, weeklyPercent: 40), now: now)
        XCTAssertEqual(fresh.amounts, "5h: 20% used · Week: 40% used")
        XCTAssertTrue(fresh.recorded.hasPrefix("Recorded "))
        XCTAssertFalse(fresh.isStale)
        let stale = UsagePresentation(.init(observedAt: now.addingTimeInterval(-901), sessionPercent: nil, weeklyPercent: 100), now: now)
        XCTAssertEqual(stale.amounts, "Week: 100% used")
        XCTAssertTrue(stale.isStale)
        XCTAssertTrue(stale.recorded.hasSuffix(" · stale"))
        XCTAssertNotEqual(fresh.recorded, stale.recorded)
    }

    func testDiagnosticsCannotExposeAliasesPathsOrErrorPayloads() {
        let profiles = [AccountProfile(id: "default", name: "private@example.com", createdAt: Date()),
                        AccountProfile(id: "secret-account-id", name: "/Users/private/customer", createdAt: Date())]
        let error = SharedSessionStoreError.unsafe("/Users/private/secret token=abc123")
        let report = DiagnosticsReport(appVersion: "0.2.5", build: "7", claudeVersion: "/Users/private/app",
                                       profiles: profiles, runningIDs: [profiles[1].id], unidentifiedProcesses: 1,
                                       location: .unavailable(error), transfersSupported: false, phase: nil,
                                       pendingID: profiles[1].id, launchTimedOut: true,
                                       lastFailure: DiagnosticFailure(error)).text
        for secret in ["private", "secret-account-id", "abc123", "/Users/", "example.com"] {
            XCTAssertFalse(report.contains(secret), secret)
        }
        XCTAssertTrue(report.contains("Account 2: running"))
        XCTAssertTrue(report.contains("Pending launch: Account 2"))
        XCTAssertTrue(report.contains("Pending session recovery: unknown"))
        XCTAssertTrue(report.contains("unsafe_session_storage"))
        XCTAssertTrue(report.contains("Claude: unknown"))
    }

    func testDiagnosticsDifferentiatesOwnerRunningAndRecovery() {
        let profiles = [AccountProfile(id: "default", name: "One", createdAt: Date()),
                        AccountProfile(id: "second", name: "Two", createdAt: Date())]
        func report(_ location: SessionLocation) -> String {
            DiagnosticsReport(appVersion: "0.2.5", build: "7", claudeVersion: "2.16120.0",
                              profiles: profiles, runningIDs: ["default"], unidentifiedProcesses: 0,
                              location: location, transfersSupported: false, phase: .preparing,
                              pendingID: nil, launchTimedOut: false, lastFailure: nil).text
        }
        let ready = report(.ready(ownerID: "second", canReopen: true))
        XCTAssertTrue(ready.contains("Session holder: Account 2"))
        XCTAssertTrue(ready.contains("Account 1 (original): running"))
        XCTAssertTrue(ready.contains("Pending session recovery: no"))
        let recovering = report(.recoveryRequired)
        XCTAssertTrue(recovering.contains("Pending session recovery: yes"))
        XCTAssertFalse(recovering.contains("Reopen without transfer verified: yes"))
    }

    @MainActor func testLaunchWatchdogResumesOnceAndLeavesLateFailureDeliverable() async {
        do {
            let _: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                let gate = LaunchCompletion(continuation: continuation)
                XCTAssertTrue(gate.finish(.failure(RuntimeError.launchTimedOut)))
                // A false return routes the late result to the UI instead of losing it.
                XCTAssertFalse(gate.finish(.failure(RuntimeError.launchDidNotMatch)))
                XCTAssertFalse(gate.finish(.success(NSRunningApplication.current)))
            }
            XCTFail("Expected timeout")
        } catch {
            guard case RuntimeError.launchTimedOut = error else { return XCTFail("Wrong first completion") }
        }
    }

    @MainActor func testCompletedLaunchIgnoresLaterWatchdog() async throws {
        let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            let gate = LaunchCompletion(continuation: continuation)
            XCTAssertTrue(gate.finish(.success(NSRunningApplication.current)))
            XCTAssertFalse(gate.finish(.failure(RuntimeError.launchTimedOut)))
        }
        XCTAssertEqual(application.processIdentifier, NSRunningApplication.current.processIdentifier)
    }
}
