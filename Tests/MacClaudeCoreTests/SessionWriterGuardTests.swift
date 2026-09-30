import Darwin
import Foundation
import XCTest
@testable import MacClaudeCore

final class SessionWriterGuardTests: XCTestCase {
    private var root: URL!
    private var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    private var registry: URL { config.appendingPathComponent("sessions", isDirectory: true) }
    private var history: URL { root.appendingPathComponent("history", isDirectory: true) }
    private let current = "11111111-1111-4111-8111-111111111111"
    private let prior = "22222222-2222-4222-8222-222222222222"
    private let unrelated = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let pid: Int32 = 65432

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClaudeWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMatchingLiveWriterBlocksButDeadEntryDoesNot() throws {
        try record(["cliSessionId": current])
        try writer(current)
        assertFailure(.activeWriter)
        XCTAssertNoThrow(try check(live: []))
    }

    func testUnrelatedLiveCLIAllowedIncludingNilHistory() throws {
        try record(["cliSessionId": current])
        try writer(unrelated, extras: ["kind": "interactive", "procStart": "Tue Sep 29 10:00:00 2026", "updatedAt": 1_800_000_000_000])
        XCTAssertNoThrow(try check())
        XCTAssertNoThrow(try SessionWriterGuard.check(sessionDirectory: nil, configDirectory: config, liveProcessIDs: [pid]))
    }

    func testAllHistoricalHandlesAndRewindEdgesBlock() throws {
        let variants: [[String: Any]] = [
            ["unarchivedCliSessionId": prior],
            ["preClearCliSessionId": prior],
            ["priorCliSessionIds": [prior]],
            ["rewindEdges": [["parent": prior, "child": current]]],
            ["rewindEdges": [["parent": current, "child": prior]]],
            ["transcriptCuts": [prior: "message-id-not-read"]],
            ["transcriptModelStates": [prior: ["model": "model-not-read"]]]
        ]
        try writer(prior)
        for fields in variants {
            try record(fields.merging(["cliSessionId": current]) { first, _ in first })
            assertFailure(.activeWriter)
        }
    }

    func testNativeFilenameAndRecordStemRemainClaimsAfterCLIChanges() throws {
        try writer(current)
        try record(["cliSessionId": unrelated])
        assertFailure(.activeWriter)
        try FileManager.default.removeItem(at: recordURL)
        try write(["sessionId": "local_\(current)", "cliSessionId": unrelated],
                  to: history.appendingPathComponent("local_\(prior).json"))
        assertFailure(.activeWriter)
    }

    func testUUIDCaseDoesNotBypassOwnershipCheck() throws {
        try record(["cliSessionId": unrelated.lowercased()])
        try writer(unrelated)
        assertFailure(.activeWriter)
    }

    func testMalformedLivingEntriesFailClosedButDeadMalformedEntriesAreIgnored() throws {
        try record(["cliSessionId": current])
        let invalid: [Any] = [
            ["pid": pid, "sessionId": 3],
            ["pid": pid + 1, "sessionId": unrelated],
            ["pid": true, "sessionId": unrelated],
            ["pid": pid, "sessionId": "not-an-id"],
            ["pid": pid, "sessionId": unrelated, "updatedAt": "tomorrow"],
            ["pid": pid, "sessionId": unrelated, "procStart": 17],
            ["pid": pid, "sessionId": unrelated, "kind": []],
            []
        ]
        for object in invalid {
            try write(object, to: writerURL)
            assertFailure(.invalidLiveRegistryEntry)
            XCTAssertNoThrow(try check(live: []))
        }
        try Data("{incomplete".utf8).write(to: writerURL)
        assertFailure(.invalidLiveRegistryEntry)
        XCTAssertNoThrow(try check(live: []))
    }

    func testRegistryAndLiveEntrySymlinksAreRefused() throws {
        try record(["cliSessionId": current])
        let outside = root.appendingPathComponent("elsewhere.json")
        try write(["pid": pid, "sessionId": unrelated], to: outside)
        try FileManager.default.createSymbolicLink(at: writerURL, withDestinationURL: outside)
        assertFailure(.invalidLiveRegistryEntry)
        XCTAssertNoThrow(try check(live: []))
        try FileManager.default.removeItem(at: writerURL)
        try FileManager.default.removeItem(at: registry)
        let otherDirectory = root.appendingPathComponent("other-registry", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: otherDirectory)
        assertFailure(.unreadableRegistry)
    }

    func testMetadataSymlinkMalformedAndInvalidLineageFailClosed() throws {
        try writer(unrelated)
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try write(["sessionId": "local_\(current)", "cliSessionId": current], to: elsewhere)
        try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: elsewhere)
        assertFailure(.unreadableSessionMetadata)
        try FileManager.default.removeItem(at: recordURL)
        try Data("broken".utf8).write(to: recordURL)
        assertFailure(.unreadableSessionMetadata)
        try record(["priorCliSessionIds": [1]])
        assertFailure(.unreadableSessionMetadata)
        try record(["rewindEdges": [["parent": prior]]])
        assertFailure(.unreadableSessionMetadata)
        try record(["cliSessionId": "unexpected"])
        assertFailure(.unreadableSessionMetadata)
    }

    func testHardlinkedAndNonRegularLivingEntriesAreRefused() throws {
        try record(["cliSessionId": current])
        let elsewhere = root.appendingPathComponent("entry.json")
        try write(["pid": pid, "sessionId": unrelated], to: elsewhere)
        try FileManager.default.linkItem(at: elsewhere, to: writerURL)
        assertFailure(.invalidLiveRegistryEntry)
        try FileManager.default.removeItem(at: writerURL)
        XCTAssertEqual(mkfifo(writerURL.path, 0o600), 0)
        assertFailure(.invalidLiveRegistryEntry)
    }

    func testOversizedLiveRegistryAndMetadataAreRefused() throws {
        try Data(repeating: 0x20, count: 1_048_577).write(to: writerURL)
        assertFailure(.invalidLiveRegistryEntry)
        try writer(unrelated)
        try Data(repeating: 0x20, count: 10_485_761).write(to: recordURL)
        assertFailure(.unreadableSessionMetadata)
    }

    func testMissingRegistryAllowedButUnreadableSourceIsNotWhenWritersExist() throws {
        try FileManager.default.removeItem(at: registry)
        XCTAssertNoThrow(try check())
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try writer(unrelated)
        try FileManager.default.removeItem(at: history)
        assertFailure(.unreadableSessionMetadata)
    }

    func testIgnoresOtherRegistryNamesAndNonSessionFiles() throws {
        try writer(unrelated)
        try Data("broken".utf8).write(to: registry.appendingPathComponent("not-a-pid.json"))
        try Data("broken".utf8).write(to: registry.appendingPathComponent("\(pid).json.tmp"))
        try Data("broken".utf8).write(to: history.appendingPathComponent("scheduled-tasks.json"))
        try Data("broken".utf8).write(to: history.appendingPathComponent("deleted_\(current)"))
        try record(["cliSessionId": current])
        XCTAssertNoThrow(try check())
    }

    func testRecoveryScanFindsWriterInEitherProfileWithoutMasterLocation() throws {
        let first = root.appendingPathComponent("profile-a", isDirectory: true)
        let second = root.appendingPathComponent("profile-b", isDirectory: true)
        let source = try namespace(in: first, account: current, organization: prior)
        let destination = try namespace(in: second, account: prior, organization: current)
        let fileName = "local_\(current).json"
        try write(["sessionId": "local_\(current)", "priorCliSessionIds": [prior]], to: source.appendingPathComponent(fileName))
        try writer(prior)
        let checkBoth = {
            try SessionWriterGuard.check(profileDirectories: [first, second], configDirectory: self.config, liveProcessIDs: [self.pid])
        }
        XCTAssertThrowsError(try checkBoth()) { XCTAssertEqual($0 as? SessionWriterGuardError, .activeWriter) }
        // Simulate the store's real-directory rename during recovery. The old
        // namespace now has no organization leaf; the guard still finds it.
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        XCTAssertThrowsError(try checkBoth()) { XCTAssertEqual($0 as? SessionWriterGuardError, .activeWriter) }
        try writer(unrelated)
        XCTAssertNoThrow(try checkBoth())
    }

    func testRecoveryScanAllowsMissingNamespaceAtEveryTransferStage() throws {
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        let checkProfile = {
            try SessionWriterGuard.check(profileDirectories: [profile], configDirectory: self.config, liveProcessIDs: [self.pid])
        }
        try writer(unrelated)
        XCTAssertNoThrow(try checkProfile())
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        XCTAssertNoThrow(try checkProfile())
        let sessions = profile.appendingPathComponent("claude-code-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        XCTAssertNoThrow(try checkProfile())
        let account = sessions.appendingPathComponent(current, isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        XCTAssertNoThrow(try checkProfile())
        let organization = try namespace(in: profile, account: current, organization: prior)
        try Data("not-session-metadata".utf8).write(to: organization.appendingPathComponent("scheduled-tasks.json"))
        XCTAssertNoThrow(try checkProfile())
    }

    func testRecoveryScanRefusesSymlinkAtEachNamespaceLevel() throws {
        try writer(unrelated)
        for level in 0...3 {
            let container = root.appendingPathComponent("case-\(level)", isDirectory: true)
            let profile = container.appendingPathComponent("profile", isDirectory: true)
            let sessions = profile.appendingPathComponent("claude-code-sessions", isDirectory: true)
            let account = sessions.appendingPathComponent(current, isDirectory: true)
            let organization = try namespace(in: profile, account: current, organization: prior)
            let aliased = [profile, sessions, account, organization][level]
            let real = container.appendingPathComponent("aliased-real", isDirectory: true)
            try FileManager.default.moveItem(at: aliased, to: real)
            try FileManager.default.createSymbolicLink(at: aliased, withDestinationURL: real)
            XCTAssertThrowsError(try SessionWriterGuard.check(profileDirectories: [profile], configDirectory: config, liveProcessIDs: [pid])) {
                XCTAssertEqual($0 as? SessionWriterGuardError, .unreadableSessionMetadata)
            }
        }
    }

    func testRecoveryScanFailsClosedForMalformedLiveRegistryEvenWhenProfilesMissing() throws {
        try Data("incomplete".utf8).write(to: writerURL)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try SessionWriterGuard.check(profileDirectories: [missing], configDirectory: config, liveProcessIDs: [pid])) {
            XCTAssertEqual($0 as? SessionWriterGuardError, .invalidLiveRegistryEntry)
        }
        XCTAssertNoThrow(try SessionWriterGuard.check(profileDirectories: [missing], configDirectory: config, liveProcessIDs: []))
    }

    private func namespace(in profile: URL, account: String, organization: String) throws -> URL {
        let result = profile.appendingPathComponent("claude-code-sessions", isDirectory: true)
            .appendingPathComponent(account, isDirectory: true).appendingPathComponent(organization, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private var writerURL: URL { registry.appendingPathComponent("\(pid).json") }
    private var recordURL: URL { history.appendingPathComponent("local_\(current).json") }

    private func writer(_ sessionID: String, extras: [String: Any] = [:]) throws {
        try write(extras.merging(["pid": pid, "sessionId": sessionID]) { _, value in value }, to: writerURL)
    }

    private func record(_ fields: [String: Any]) throws {
        try write(fields.merging(["sessionId": "local_\(current)"]) { _, value in value }, to: recordURL)
    }

    private func write(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func check(live: Set<Int32>? = nil) throws {
        try SessionWriterGuard.check(sessionDirectory: history, configDirectory: config, liveProcessIDs: live ?? [pid])
    }

    private func assertFailure(_ expected: SessionWriterGuardError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try check(), file: file, line: line) {
            XCTAssertEqual($0 as? SessionWriterGuardError, expected, file: file, line: line)
        }
    }
}
