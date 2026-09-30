import Foundation
import XCTest
import MacClaudeCore
@testable import MacClaude

final class SessionLocationTests: XCTestCase {
    private let a = AccountProfile(id: "default", name: "First", createdAt: Date())
    private let b = AccountProfile(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", name: "Second", createdAt: Date())

    func testFailureAfterCompletedTransferNamesTheNewLocation() {
        let location = SessionLocation.ready(ownerID: b.id, canReopen: true)
        let message = location.outcome(startingOwnerID: a.id, profiles: [a, b])
        XCTAssertTrue(message.contains("now in Second"))
        XCTAssertFalse(message.contains("remain in"))
    }

    func testPreTransferFailureNamesTheUnchangedLocation() {
        let location = SessionLocation.ready(ownerID: a.id, canReopen: true)
        XCTAssertEqual(location.outcome(startingOwnerID: a.id, profiles: [a, b]), "Your shared sessions remain in First.")
    }

    func testRecoveryAndUnknownLocationDoNotClaimNothingMovedOrPermitReopening() {
        for location in [SessionLocation.recoveryRequired, .unavailable(SharedSessionStoreError.changed)] {
            XCTAssertNil(location.ownerID)
            XCTAssertFalse(location.canReopen)
            let message = location.outcome(startingOwnerID: a.id, profiles: [a, b])
            XCTAssertFalse(message.contains("remain in"))
            XCTAssertFalse(message.contains("have not been moved"))
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testUninitializedProfilesDoNotInventASessionOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProfilePaths(rootDirectory: root.appendingPathComponent("MacClaude"), homeDirectory: root)
        let location = SessionLocation.read(root: root.appendingPathComponent("SharedSessions"), profiles: [a, b], paths: paths)
        if case .ready(nil, false) = location {} else { XCTFail("Missing profiles must not be presented as the recorded owner") }
    }
}
