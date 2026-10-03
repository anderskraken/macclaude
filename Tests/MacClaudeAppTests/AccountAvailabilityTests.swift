import XCTest
import MacClaudeCore
@testable import MacClaude

final class AccountAvailabilityTests: XCTestCase {
    private let one = AccountProfile(id: "default", name: "One", createdAt: Date())
    private let two = AccountProfile(id: "second", name: "Two", createdAt: Date())
    private let checked = "2.9939.4"

    private func availability(_ version: String?, _ location: SessionLocation) -> AccountAvailability {
        AccountAvailability(claudeVersion: version, location: location, profiles: [one, two])
    }

    func testMissingClaudeBlocksEveryAccountAndOffersChooser() {
        let state = availability(nil, .ready(ownerID: "second", canReopen: true))
        XCTAssertFalse(state.canOpen(one))
        XCTAssertFalse(state.canOpen(two))
        guard case .chooseClaude = state.banner.action?.action else { return XCTFail("expected Choose Claude") }
    }

    func testCheckedVersionOpensAnyAccountWithoutBanner() {
        for version in AccountAvailability.checkedClaudeVersions {
            let state = availability(version, .ready(ownerID: "second", canReopen: true))
            XCTAssertTrue(state.canOpen(one))
            XCTAssertTrue(state.canOpen(two))
            XCTAssertNil(state.banner.text)
            XCTAssertNil(state.blockedReason)
        }
    }

    func testUncheckedVersionOnlyReopensVerifiedOwner() {
        let state = availability("9.9.9", .ready(ownerID: "second", canReopen: true))
        XCTAssertFalse(state.canOpen(one))
        XCTAssertTrue(state.canOpen(two))
        guard case .open("second") = state.banner.action?.action else { return XCTFail("expected Open Two") }
    }

    func testUncheckedVersionWithoutVerifiedOwnerOffersNothing() {
        for location in [SessionLocation.ready(ownerID: nil, canReopen: false), .ready(ownerID: "second", canReopen: false)] {
            let state = availability("9.9.9", location)
            XCTAssertFalse(state.canOpen(one))
            XCTAssertFalse(state.canOpen(two))
            XCTAssertNotNil(state.banner.text)
            XCTAssertNil(state.banner.action)
        }
    }

    func testCheckingShowsNoBannerAndRecoveryPointsAtItsFolder() {
        XCTAssertNil(availability(checked, .checking).banner.text)
        guard case .revealRecovery = availability(checked, .recoveryRequired).banner.action?.action else {
            return XCTFail("expected Show Recovery Folder")
        }
        XCTAssertFalse(availability("9.9.9", .recoveryRequired).canOpen(one))
    }
}
