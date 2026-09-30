import Darwin
import Foundation
import XCTest
@testable import MacClaudeCore

final class SharedSessionStoreTests: XCTestCase {
    private var root: URL!
    private var fixture: Fixture!
    private var manager: FileManager { .default }

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent("MacClaudeSharedTests-\(UUID().uuidString)", isDirectory: true)
        fixture = try Fixture(root: root)
    }

    override func tearDownWithError() throws { try manager.removeItem(at: root) }

    func testReopenRecordedOwnerDoesNotWriteOrAuthorizeAnotherProfile() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        try f.addPools()
        XCTAssertFalse(try f.store.canReopenWithoutTransfer(profileDirectories: f.profiles, destination: f.profileA))
        _ = try f.store.activate(profileDirectories: f.profiles, destination: f.profileB)
        let before = try files(in: root)
        let ownerInode = try inode(f.b)
        XCTAssertTrue(try f.store.canReopenWithoutTransfer(profileDirectories: f.profiles, destination: f.profileB))
        XCTAssertFalse(try f.store.canReopenWithoutTransfer(profileDirectories: f.profiles, destination: f.profileA))
        XCTAssertEqual(try files(in: root), before)
        XCTAssertEqual(try inode(f.b), ownerInode)
    }

    func testReopenRefusesPendingTransactionWithoutRecoveringIt() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        _ = try f.store.activate(profileDirectories: f.profiles, destination: f.profileB)
        let interrupted = SharedSessionStore(rootDirectory: f.state, faultInjector: { point in
            if point == .historyMoved { throw TestError.interrupted }
        })
        XCTAssertThrowsError(try interrupted.activate(profileDirectories: f.profiles, destination: f.profileA))
        let before = try files(in: root)
        for profile in f.profiles {
            XCTAssertFalse(try f.store.canReopenWithoutTransfer(profileDirectories: f.profiles, destination: profile))
        }
        XCTAssertEqual(try files(in: root), before)
        XCTAssertTrue(try f.store.hasPendingTransaction())
    }

    func testReopenRejectsReplacementDirectoryEvenWithSameHistory() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        _ = try f.store.activate(profileDirectories: f.profiles, destination: f.profileB)
        let parked = root.appendingPathComponent("original")
        try manager.moveItem(at: f.b, to: parked)
        try manager.copyItem(at: parked, to: f.b)
        XCTAssertThrowsError(try f.store.canReopenWithoutTransfer(profileDirectories: f.profiles, destination: f.profileB))
        XCTAssertEqual(try Data(contentsOf: f.record(in: f.b)), f.recordData)
    }

    func testReopenRejectsIndependentHistoryInOtherAccount() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        _ = try f.store.activate(profileDirectories: f.profiles, destination: f.profileB)
        try f.recordData.write(to: f.record(in: f.a))
        XCTAssertThrowsError(try f.store.canReopenWithoutTransfer(profileDirectories: f.profiles, destination: f.profileB))
    }

    func testRoundTripMovesOriginalDirectoryAndFilesWhileSchedulesStayByteExact() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        let directoryInode = try inode(f.a)
        let recordInode = try inode(f.record(in: f.a))
        let scheduleAInode = try inode(f.schedule(in: f.a))
        let scheduleBInode = try inode(f.schedule(in: f.b))
        let originalFiles = try files(in: f.a, excludingSchedule: true)
        let store = f.store
        XCTAssertEqual(try store.inspect(profileDirectories: f.profiles).activeProfileDirectory, f.profileA)

        let first = try store.activate(profileDirectories: f.profiles, destination: f.profileB)
        XCTAssertTrue(first.didMove)
        XCTAssertFalse(first.destinationNeedsSetup)
        XCTAssertEqual(try inode(f.b), directoryInode)
        XCTAssertEqual(try inode(f.record(in: f.b)), recordInode)
        XCTAssertEqual(try files(in: f.b, excludingSchedule: true), originalFiles)
        try assertSchedules(f)
        XCTAssertEqual(try inode(f.schedule(in: f.a)), scheduleAInode)
        XCTAssertEqual(try inode(f.schedule(in: f.b)), scheduleBInode)
        XCTAssertEqual(try store.inspect(profileDirectories: f.profiles).activeProfileDirectory, f.profileB)
        XCTAssertFalse(try store.hasPendingTransaction())

        let backup = try XCTUnwrap(first.backupDirectory)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("0/\(f.recordName)")), f.recordData)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("0/scheduled-tasks.json")), f.scheduleA)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("1/scheduled-tasks.json")), f.scheduleB)
        XCTAssertEqual(try permissions(backup), 0o700)
        XCTAssertEqual(try permissions(backup.appendingPathComponent("0/\(f.recordName)")), 0o600)

        let second = try store.activate(profileDirectories: f.profiles, destination: f.profileA)
        XCTAssertTrue(second.didMove)
        XCTAssertEqual(second.backupDirectory, backup)
        XCTAssertEqual(try inode(f.a), directoryInode)
        XCTAssertEqual(try inode(f.record(in: f.a)), recordInode)
        XCTAssertEqual(try files(in: f.a, excludingSchedule: true), originalFiles)
        try assertSchedules(f)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: f.state.appendingPathComponent("Backups").path).count, 1)
        XCTAssertFalse(try store.activate(profileDirectories: f.profiles, destination: f.profileA).didMove)
    }

    func testEmptyHistoryRemembersActiveProfileAndCanMoveBack() throws {
        let f = try XCTUnwrap(fixture)
        let original = try inode(f.a)
        XCTAssertTrue(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB).didMove)
        XCTAssertEqual(try f.store.inspect(profileDirectories: f.profiles).activeProfileDirectory, f.profileB)
        XCTAssertFalse(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB).didMove)
        XCTAssertEqual(try inode(f.b), original)
        XCTAssertTrue(try f.store.activate(profileDirectories: f.profiles, destination: f.profileA).didMove)
        XCTAssertEqual(try inode(f.a), original)
        try assertSchedules(f)
    }

    func testWorktreePoolMovesWithHistoryPreservingFileIdentityAndEmptyDestination() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        try f.addPools()
        let fullInode = try inode(f.pool(in: f.profileA))
        let emptyInode = try inode(f.pool(in: f.profileB))
        let first = try f.store.activate(profileDirectories: f.profiles, destination: f.profileB)
        XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileB)), f.fullPool)
        XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileA)), f.emptyPool)
        XCTAssertEqual(try inode(f.pool(in: f.profileB)), fullInode)
        XCTAssertEqual(try inode(f.pool(in: f.profileA)), emptyInode)
        let backup = try XCTUnwrap(first.backupDirectory)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("git-worktrees-0.json")), f.fullPool)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("git-worktrees-1.json")), f.emptyPool)
        XCTAssertEqual(try permissions(backup.appendingPathComponent("git-worktrees-0.json")), 0o600)
        XCTAssertTrue(try f.store.activate(profileDirectories: f.profiles, destination: f.profileA).didMove)
        XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileA)), f.fullPool)
        XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileB)), f.emptyPool)
        XCTAssertEqual(try inode(f.pool(in: f.profileA)), fullInode)
        XCTAssertEqual(try inode(f.pool(in: f.profileB)), emptyInode)
        try assertSchedules(f)
    }

    func testWorktreePoolAbsentStatesArePreservedInBothDirections() throws {
        for sourceHasPool in [false, true] {
            let f = try Fixture(root: root.appendingPathComponent("pool-\(sourceHasPool)", isDirectory: true))
            try f.addHistory()
            let presentProfile = sourceHasPool ? f.profileA : f.profileB
            let poolBytes = sourceHasPool ? f.fullPool : f.emptyPool
            try poolBytes.write(to: f.pool(in: presentProfile))
            let poolInode = try inode(f.pool(in: presentProfile))
            XCTAssertTrue(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB).didMove)
            let transferredProfile = sourceHasPool ? f.profileB : f.profileA
            XCTAssertEqual(try inode(f.pool(in: transferredProfile)), poolInode)
            XCTAssertFalse(manager.fileExists(atPath: f.pool(in: presentProfile).path))
            XCTAssertTrue(try f.store.activate(profileDirectories: f.profiles, destination: f.profileA).didMove)
            XCTAssertEqual(try inode(f.pool(in: presentProfile)), poolInode)
            XCTAssertEqual(try Data(contentsOf: f.pool(in: presentProfile)), poolBytes)
            XCTAssertFalse(manager.fileExists(atPath: f.pool(in: transferredProfile).path))
        }
    }

    func testGCWorkingDirectoryTimestampOnlyPoolIsEmptyAndPreservedByteExact() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        try f.fullPool.write(to: f.pool(in: f.profileA))
        let gcOnly = Data("{\"schemaVersion\":2,\"untrackedDirGc\":{\"sightings\":{},\"roots\":{},\"cwds\":{\"/tmp/disposable-code-fixture\":1790000000000}}}\n".utf8)
        try gcOnly.write(to: f.pool(in: f.profileB))
        let gcInode = try inode(f.pool(in: f.profileB))
        XCTAssertEqual(try f.store.inspect(profileDirectories: f.profiles).activeProfileDirectory, f.profileA)
        let first = try f.store.activate(profileDirectories: f.profiles, destination: f.profileB)
        XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileA)), gcOnly)
        XCTAssertEqual(try inode(f.pool(in: f.profileA)), gcInode)
        XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileB)), f.fullPool)
        let backup = try XCTUnwrap(first.backupDirectory)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("git-worktrees-1.json")), gcOnly)
        XCTAssertTrue(try f.store.activate(profileDirectories: f.profiles, destination: f.profileA).didMove)
        XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileB)), gcOnly)
        XCTAssertEqual(try inode(f.pool(in: f.profileB)), gcInode)
        XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileA)), f.fullPool)
    }

    func testMalformedGCTimestampsDoNotCountAsAnEmptyPool() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        for value in ["true", "\"timestamp\"", "{}", "[]", "-1", "1.5", "9007199254740992"] {
            let bytes = Data("{\"schemaVersion\":2,\"untrackedDirGc\":{\"cwds\":{\"/tmp/disposable-code-fixture\":\(value)}}}".utf8)
            try bytes.write(to: f.pool(in: f.profileB))
            XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB))
            XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileB)), bytes)
            XCTAssertFalse(manager.fileExists(atPath: f.state.path))
        }
    }

    func testIndependentWorktreePoolsIncludingAncillaryDataAreNeverOverwritten() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        try f.fullPool.write(to: f.pool(in: f.profileA))
        for other in [
            "{\"worktrees\":{\"other\":{}}}",
            "{\"originUrls\":{\"repo\":\"git@example.test/repo\"}}",
            "{\"originPins\":{\"repo\":\"path\"}}",
            "{\"pendingTombstones\":[\"retained\"]}",
            "{\"untrackedDirGc\":{\"sightings\":{\"retained\":1}}}"
        ] {
            let bytes = Data(other.utf8)
            try bytes.write(to: f.pool(in: f.profileB))
            XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB))
            XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileB)), bytes)
            XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileA)), f.fullPool)
            XCTAssertFalse(manager.fileExists(atPath: f.state.path))
        }
    }

    func testUnknownOrUnsafeWorktreePoolFormatRefusesBeforeMutation() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        for malformed in ["{broken", "[]", "{\"schemaVersion\":3}", "{\"schemaVersion\":true}", "{\"worktrees\":[]}", "{\"unknownFutureField\":{}}", "{\"untrackedDirGc\":{\"unknown\":{}}}"] {
            let bytes = Data(malformed.utf8)
            try bytes.write(to: f.pool(in: f.profileA))
            XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB))
            XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileA)), bytes)
            XCTAssertFalse(manager.fileExists(atPath: f.state.path))
        }
        try manager.removeItem(at: f.pool(in: f.profileA))
        let target = root.appendingPathComponent("external-pool.json")
        try f.fullPool.write(to: target)
        try manager.createSymbolicLink(at: f.pool(in: f.profileA), withDestinationURL: target)
        XCTAssertThrowsError(try f.store.inspect(profileDirectories: f.profiles))
        XCTAssertEqual(try Data(contentsOf: target), f.fullPool)
    }

    func testUninitializedDestinationAllowsLoginWithoutChangingHistory() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        let newProfile = root.appendingPathComponent("not-signed-in", isDirectory: true)
        let profiles = f.profiles + [newProfile]
        let before = try files(in: f.a)
        let inspection = try f.store.inspect(profileDirectories: profiles)
        XCTAssertEqual(inspection.uninitializedProfiles, [newProfile])
        XCTAssertTrue(inspection.canActivate)
        let result = try f.store.activate(profileDirectories: profiles, destination: newProfile)
        XCTAssertTrue(result.destinationNeedsSetup)
        XCTAssertFalse(result.didMove)
        XCTAssertEqual(try files(in: f.a), before)
        XCTAssertFalse(manager.fileExists(atPath: f.state.path))
    }

    func testMultipleHistoriesAndAmbiguousNamespacesArePreserved() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        try f.recordData.write(to: f.record(in: f.b))
        let a = try files(in: f.a), b = try files(in: f.b)
        XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB))
        XCTAssertEqual(try files(in: f.a), a)
        XCTAssertEqual(try files(in: f.b), b)
        try manager.removeItem(at: f.record(in: f.b))
        try manager.createDirectory(at: f.b.deletingLastPathComponent().appendingPathComponent(UUID().uuidString), withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.store.inspect(profileDirectories: f.profiles))
        XCTAssertFalse(manager.fileExists(atPath: f.state.path))
    }

    func testInvalidSessionAndUnfinishedImportRefuseWithoutWriting() throws {
        let f = try XCTUnwrap(fixture)
        for bytes in [Data("{broken".utf8), Data("[]".utf8), Data("{\"stagedTranscriptPath\":\"/tmp/pending\"}".utf8)] {
            try bytes.write(to: f.record(in: f.a))
            XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB))
            XCTAssertEqual(try Data(contentsOf: f.record(in: f.a)), bytes)
            XCTAssertFalse(manager.fileExists(atPath: f.state.path))
        }
        try manager.removeItem(at: f.record(in: f.a))
        let staged = f.a.appendingPathComponent("imported-staging", isDirectory: true)
        try manager.createDirectory(at: staged, withIntermediateDirectories: false)
        try Data("pending".utf8).write(to: staged.appendingPathComponent("item"))
        XCTAssertThrowsError(try f.store.inspect(profileDirectories: f.profiles))
        XCTAssertFalse(manager.fileExists(atPath: f.state.path))
    }

    func testSymlinkNamespaceRecordAndStateRootAreRejectedWithoutFollowing() throws {
        let f = try XCTUnwrap(fixture)
        let external = root.appendingPathComponent("external", isDirectory: true)
        try manager.createDirectory(at: external, withIntermediateDirectories: false)
        let externalFile = external.appendingPathComponent("secret")
        try Data("preserve".utf8).write(to: externalFile)
        try manager.createSymbolicLink(at: f.record(in: f.a), withDestinationURL: externalFile)
        XCTAssertThrowsError(try f.store.inspect(profileDirectories: f.profiles))
        try manager.removeItem(at: f.record(in: f.a))
        try manager.removeItem(at: f.b)
        try manager.createSymbolicLink(at: f.b, withDestinationURL: external)
        XCTAssertThrowsError(try f.store.inspect(profileDirectories: f.profiles))
        try manager.removeItem(at: f.b)
        try manager.createDirectory(at: f.b, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: f.state, withDestinationURL: external)
        XCTAssertThrowsError(try f.store.hasPendingTransaction())
        XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB))
        XCTAssertEqual(try Data(contentsOf: externalFile), Data("preserve".utf8))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: external.path), ["secret"])
    }

    func testUnexpectedFilesAndSymlinkAccountFailClosed() throws {
        let f = try XCTUnwrap(fixture)
        let unknown = f.a.appendingPathComponent("unknown-new-Claude-format")
        try Data("future".utf8).write(to: unknown)
        XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB))
        try manager.removeItem(at: unknown)
        let account = f.a.deletingLastPathComponent()
        let parked = root.appendingPathComponent("parked-account")
        try manager.moveItem(at: account, to: parked)
        try manager.createSymbolicLink(at: account, withDestinationURL: parked)
        XCTAssertThrowsError(try f.store.inspect(profileDirectories: f.profiles))
        XCTAssertFalse(manager.fileExists(atPath: f.state.path))
    }

    func testBackupFailureLeavesOriginalsAndRecoverableJournal() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        try manager.createDirectory(at: f.state, withIntermediateDirectories: false)
        let obstacle = f.state.appendingPathComponent("Backups")
        try Data("blocked".utf8).write(to: obstacle)
        let beforeA = try files(in: f.a), beforeB = try files(in: f.b)
        XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB))
        XCTAssertTrue(try f.store.hasPendingTransaction())
        XCTAssertEqual(try files(in: f.a), beforeA)
        XCTAssertEqual(try files(in: f.b), beforeB)
        try manager.removeItem(at: obstacle)
        XCTAssertTrue(try f.store.recover(profileDirectories: f.profiles))
        XCTAssertEqual(try Data(contentsOf: f.record(in: f.b)), f.recordData)
        try assertSchedules(f)
    }

    func testRecoveryAtEveryDurableBoundaryPreservesInodesAndSchedules() throws {
        for point in SharedSessionStore.Checkpoint.allCases {
            let f = try Fixture(root: root.appendingPathComponent(point.rawValue, isDirectory: true))
            try f.addHistory()
            try f.addPools()
            let originalDirectory = try inode(f.a)
            let originalPool = try inode(f.pool(in: f.profileA))
            let originalFiles = try files(in: f.a, excludingSchedule: true)
            let interrupted = SharedSessionStore(rootDirectory: f.state) { current in
                if current == point { throw TestError.interrupted }
            }
            XCTAssertThrowsError(try interrupted.activate(profileDirectories: f.profiles, destination: f.profileB), point.rawValue)
            if point == .committed {
                XCTAssertFalse(try f.store.recover(profileDirectories: f.profiles))
            } else {
                XCTAssertTrue(try f.store.hasPendingTransaction(), point.rawValue)
                XCTAssertThrowsError(try f.store.inspect(profileDirectories: f.profiles), point.rawValue)
                XCTAssertTrue(try f.store.recover(profileDirectories: f.profiles), point.rawValue)
            }
            XCTAssertEqual(try inode(f.b), originalDirectory, point.rawValue)
            XCTAssertEqual(try files(in: f.b, excludingSchedule: true), originalFiles, point.rawValue)
            XCTAssertEqual(try inode(f.pool(in: f.profileB)), originalPool, point.rawValue)
            XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileB)), f.fullPool, point.rawValue)
            XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileA)), f.emptyPool, point.rawValue)
            try assertSchedules(f)
            XCTAssertFalse(try f.store.recover(profileDirectories: f.profiles), point.rawValue)
            XCTAssertEqual(try f.store.inspect(profileDirectories: f.profiles).activeProfileDirectory, f.profileB)
        }
    }

    func testChangedDestinationAfterJournalIsPreservedAndRecoveryRefuses() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        let interrupted = SharedSessionStore(rootDirectory: f.state) { point in
            if point == .backupWritten { throw TestError.interrupted }
        }
        XCTAssertThrowsError(try interrupted.activate(profileDirectories: f.profiles, destination: f.profileB))
        let unexpected = Data("{\"title\":\"Created by an external app\"}".utf8)
        try unexpected.write(to: f.record(in: f.b))
        XCTAssertThrowsError(try f.store.recover(profileDirectories: f.profiles))
        XCTAssertTrue(try f.store.hasPendingTransaction())
        XCTAssertEqual(try Data(contentsOf: f.record(in: f.b)), unexpected)
        XCTAssertEqual(try Data(contentsOf: f.record(in: f.a)), f.recordData)
        try assertSchedules(f)
    }

    func testVerifierPreventsMutationAndPreservesJournalDuringRecovery() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB, verifyStopped: { throw TestError.running }))
        XCTAssertFalse(manager.fileExists(atPath: f.state.path))

        let gate = StopGate()
        let interrupted = SharedSessionStore(rootDirectory: f.state) { point in
            if point == .backupWritten { gate.setRunning() }
        }
        XCTAssertThrowsError(try interrupted.activate(profileDirectories: f.profiles, destination: f.profileB, verifyStopped: { try gate.verify() }))
        XCTAssertTrue(try f.store.hasPendingTransaction())
        let journal = try Data(contentsOf: f.state.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try f.store.recover(profileDirectories: f.profiles, verifyStopped: { throw TestError.running }))
        XCTAssertEqual(try Data(contentsOf: f.state.appendingPathComponent("journal.json")), journal)
        XCTAssertEqual(try Data(contentsOf: f.record(in: f.a)), f.recordData)
        XCTAssertFalse(manager.fileExists(atPath: f.record(in: f.b).path))
        XCTAssertTrue(try f.store.recover(profileDirectories: f.profiles))
        try assertSchedules(f)
    }

    func testCorruptOrUnconfiguredRecoveryJournalCannotMoveData() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        let interrupted = SharedSessionStore(rootDirectory: f.state) { point in
            if point == .journalWritten { throw TestError.interrupted }
        }
        XCTAssertThrowsError(try interrupted.activate(profileDirectories: f.profiles, destination: f.profileB))
        XCTAssertThrowsError(try f.store.recover(profileDirectories: [f.profileB]))
        XCTAssertEqual(try Data(contentsOf: f.record(in: f.a)), f.recordData)
        let journal = f.state.appendingPathComponent("journal.json")
        let broken = Data("{broken".utf8)
        try broken.write(to: journal)
        XCTAssertThrowsError(try f.store.recover(profileDirectories: f.profiles))
        XCTAssertEqual(try Data(contentsOf: journal), broken)
        XCTAssertEqual(try Data(contentsOf: f.record(in: f.a)), f.recordData)
    }

    func testMissingSchedulesRoundTripWithoutInventingFiles() throws {
        let f = try XCTUnwrap(fixture)
        try f.addHistory()
        for directory in [f.a, f.b] { try manager.removeItem(at: f.schedule(in: directory)) }
        XCTAssertTrue(try f.store.activate(profileDirectories: f.profiles, destination: f.profileB).didMove)
        XCTAssertTrue(try f.store.activate(profileDirectories: f.profiles, destination: f.profileA).didMove)
        for directory in [f.a, f.b] { XCTAssertFalse(manager.fileExists(atPath: f.schedule(in: directory).path)) }
    }

    func testRecoveryRefusesSymlinkTransactionAndBackupParentsBeforeFollowingThem() throws {
        for parentName in ["Transactions", "Backups"] {
            let f = try Fixture(root: root.appendingPathComponent(parentName, isDirectory: true))
            try f.addHistory()
            try f.addPools()
            let interrupted = SharedSessionStore(rootDirectory: f.state) { point in
                if point == .journalWritten { throw TestError.interrupted }
            }
            XCTAssertThrowsError(try interrupted.activate(profileDirectories: f.profiles, destination: f.profileB))
            let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.state.appendingPathComponent("journal.json"))) as? [String: Any])
            let id = try XCTUnwrap(journal["id"] as? String)
            let external = root.appendingPathComponent("external-\(parentName)", isDirectory: true)
            try manager.createDirectory(at: external.appendingPathComponent(id), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: f.state.appendingPathComponent(parentName), withDestinationURL: external)
            XCTAssertThrowsError(try f.store.recover(profileDirectories: f.profiles))
            XCTAssertTrue(try f.store.hasPendingTransaction())
            XCTAssertTrue(try manager.contentsOfDirectory(atPath: external.appendingPathComponent(id).path).isEmpty)
            XCTAssertEqual(try Data(contentsOf: f.record(in: f.a)), f.recordData)
            XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileA)), f.fullPool)
            try assertSchedules(f)
        }
    }

    func testMissingOrResizedInitialBackupPayloadStopsLaterSwitchBeforeMutation() throws {
        for remove in [true, false] {
            let f = try Fixture(root: root.appendingPathComponent("backup-\(remove)", isDirectory: true))
            try f.addHistory()
            try f.addPools()
            let result = try f.store.activate(profileDirectories: f.profiles, destination: f.profileB)
            let backup = try XCTUnwrap(result.backupDirectory)
            let payload = backup.appendingPathComponent("0/\(f.recordName)")
            if remove { try manager.removeItem(at: payload) }
            else { try Data("truncated".utf8).write(to: payload) }
            XCTAssertThrowsError(try f.store.activate(profileDirectories: f.profiles, destination: f.profileA))
            XCTAssertFalse(try f.store.hasPendingTransaction())
            XCTAssertEqual(try Data(contentsOf: f.record(in: f.b)), f.recordData)
            XCTAssertEqual(try Data(contentsOf: f.pool(in: f.profileB)), f.fullPool)
            try assertSchedules(f)
        }
    }

    private func assertSchedules(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: f.schedule(in: f.a)), f.scheduleA, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: f.schedule(in: f.b)), f.scheduleB, file: file, line: line)
    }

    private func files(in directory: URL, excludingSchedule: Bool = false) throws -> [String: Data] {
        var result: [String: Data] = [:]
        func visit(_ current: URL, prefix: String) throws {
            for name in try manager.contentsOfDirectory(atPath: current.path) {
                let url = current.appendingPathComponent(name)
                let relative = prefix + name
                let kind = try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                if kind == .typeDirectory { try visit(url, prefix: relative + "/"); continue }
                if excludingSchedule, relative == "scheduled-tasks.json" { continue }
                result[relative] = try Data(contentsOf: url)
            }
        }
        try visit(directory, prefix: "")
        return result
    }

    private func inode(_ url: URL) throws -> UInt64 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return UInt64(status.st_ino)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    private enum TestError: Error { case interrupted, running }

    private final class StopGate: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        func setRunning() { lock.lock(); running = true; lock.unlock() }
        func verify() throws {
            lock.lock()
            let value = running
            lock.unlock()
            if value { throw TestError.running }
        }
    }

    private struct Fixture {
        let state: URL
        let profileA: URL
        let profileB: URL
        let a: URL
        let b: URL
        let sessionID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let scheduleA = Data("{\n  \"scheduledTasks\": [{\"id\": \"account-a-only\"}]\n}\n".utf8)
        let scheduleB = Data("{\"scheduledTasks\":[{\"id\":\"account-b-only\"}],\"recordedSkips\":[]}".utf8)
        let recordData = Data("{\"sessionId\":\"native-id\",\"cliSessionId\":\"cli-id\",\"priorCliSessionIds\":[\"old-cli\"],\"rewindEdges\":[{\"from\":\"old-cli\"}],\"worktreePath\":\"/existing-worktree\",\"permissionMode\":\"default\",\"scheduledTaskId\":\"historical-id\",\"stagedTranscriptPath\":null}".utf8)
        let fullPool = Data("{\n\"schemaVersion\":2,\"worktrees\":{\"retained\":{\"path\":\"/existing-worktree\",\"sessionId\":\"cli-id\"}},\"originUrls\":{\"repo\":\"git@example.test/repo\"},\"originPins\":{},\"pendingTombstones\":[],\"untrackedDirGc\":{\"sightings\":{},\"roots\":{},\"cwds\":{}}\n}".utf8)
        let emptyPool = Data("{ \"schemaVersion\": 2, \"worktrees\": {}, \"originUrls\": {}, \"originPins\": {}, \"pendingTombstones\": [], \"untrackedDirGc\": {\"sightings\":{},\"roots\":{},\"cwds\":{}} }\n".utf8)
        var profiles: [URL] { [profileA, profileB] }
        var store: SharedSessionStore { SharedSessionStore(rootDirectory: state) }
        var recordName: String { "local_\(sessionID).json" }
        func record(in directory: URL) -> URL { directory.appendingPathComponent(recordName) }
        func schedule(in directory: URL) -> URL { directory.appendingPathComponent("scheduled-tasks.json") }
        func pool(in profile: URL) -> URL { profile.appendingPathComponent("git-worktrees.json") }

        init(root: URL) throws {
            state = root.appendingPathComponent("SharedSessions", isDirectory: true)
            profileA = root.appendingPathComponent("A", isDirectory: true)
            profileB = root.appendingPathComponent("B", isDirectory: true)
            a = profileA.appendingPathComponent("claude-code-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111", isDirectory: true)
            b = profileB.appendingPathComponent("claude-code-sessions/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/22222222-2222-4222-8222-222222222222", isDirectory: true)
            for directory in [a, b] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            try scheduleA.write(to: schedule(in: a))
            try scheduleB.write(to: schedule(in: b))
        }

        func addHistory() throws {
            try recordData.write(to: record(in: a))
            try Data("{\"v\":1,\"archived\":[\"local_\(sessionID)\"]}".utf8).write(to: a.appendingPathComponent("archived-sessions.idx"))
            try Data("1790000000000".utf8).write(to: a.appendingPathComponent("deleted_eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"))
            for name in ["backlog", "waiting-input", "imported-staging"] {
                try FileManager.default.createDirectory(at: a.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            try Data("{\"tasks\":[\"retained pending input\"]}".utf8).write(to: a.appendingPathComponent("backlog/tasks.json"))
            try Data("retained SSH input".utf8).write(to: a.appendingPathComponent("waiting-input/pending.json"))
        }

        func addPools() throws {
            try fullPool.write(to: pool(in: profileA))
            try emptyPool.write(to: pool(in: profileB))
        }
    }
}
