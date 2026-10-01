import Foundation
import XCTest
@testable import MacClaudeCore

final class LocalUsageTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacClaudeUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testLatestRecordedSampleUsesMillisecondsAndDoesNotMergeOlderFields() throws {
        try write(["version": 2, "samples": [
            ["t": 1_799_999_990_000, "org": "one", "u": ["fh": 12.5]],
            ["t": 1_799_999_000_000, "org": "one", "u": ["fh": 3, "sd": 8]]
        ]])
        let snapshot = try XCTUnwrap(LocalUsageReader.read(from: directory, now: now))
        XCTAssertEqual(snapshot.observedAt, Date(timeIntervalSince1970: 1_799_999_990))
        XCTAssertEqual(snapshot.sessionPercent, 12.5)
        XCTAssertNil(snapshot.weeklyPercent)
        XCTAssertFalse(snapshot.isStale(at: now))
    }

    func testUnknownUsageKeysAreIgnoredAndActualWeeklyValueIsRead() throws {
        try write(["version": 2, "samples": [["t": 1_799_999_990_000, "org": NSNull(), "u": ["fh": 0, "sd": 100, "so": 20]]]])
        let snapshot = try XCTUnwrap(LocalUsageReader.read(from: directory, now: now))
        XCTAssertEqual(snapshot.sessionPercent, 0)
        XCTAssertEqual(snapshot.weeklyPercent, 100)
    }

    func testFutureSampleFromClockSkewDoesNotHideRecordedUsage() throws {
        try write(["version": 2, "samples": [
            ["t": 1_800_000_500_000, "org": "one", "u": ["fh": 99]],
            ["t": 1_799_999_990_000, "org": "one", "u": ["fh": 40, "sd": 10]]
        ]])
        let snapshot = try XCTUnwrap(LocalUsageReader.read(from: directory, now: now))
        XCTAssertEqual(snapshot.sessionPercent, 40)
        XCTAssertEqual(snapshot.weeklyPercent, 10)
    }

    func testMixedOrganizationsOmitUsageRatherThanGuessActiveAccount() throws {
        try write(["version": 2, "samples": [
            ["t": 1_799_999_990_000, "org": "one", "u": ["fh": 12]],
            ["t": 1_799_999_000_000, "org": "two", "u": ["fh": 3]]
        ]])
        XCTAssertNil(LocalUsageReader.read(from: directory, now: now))
    }

    func testMissingMalformedUnknownSchemaAndInvalidValuesAreOmitted() throws {
        XCTAssertNil(LocalUsageReader.read(from: directory, now: now))
        try Data("{broken".utf8).write(to: directory.appendingPathComponent(LocalUsageReader.historyFilename))
        XCTAssertNil(LocalUsageReader.read(from: directory, now: now))
        for object: [String: Any] in [
            ["version": 99, "samples": [["t": 1_799_999_990_000, "org": "one", "u": ["fh": 12]]]],
            ["version": 2, "samples": []],
            ["version": 2, "samples": [["t": 1_799_999_990_000, "u": ["fh": 12]]]],
            ["version": 2, "samples": [["t": 1_799_999_990_000, "org": "one", "u": ["fh": -1]]]],
            ["version": 2, "samples": [["t": 1_799_999_990_000, "org": "one", "u": ["fh": 101]]]],
            ["version": 2, "samples": [["t": 1_799_999_990_000, "org": "one", "u": ["fh": "12"]]]],
            ["version": 2, "samples": [["t": 1_800_000_001_000, "org": "one", "u": ["fh": 12]]]],
            ["version": 2, "samples": [["t": 0, "org": "one", "u": ["fh": 12]]]],
            ["version": 2, "samples": [["t": 1_799_999_990_000, "org": "one", "u": ["future": 12]]]]
        ] {
            try write(object)
            XCTAssertNil(LocalUsageReader.read(from: directory, now: now), "\(object)")
        }
    }

    func testOldSampleIsPreservedButMarkedStale() throws {
        try write(["version": 2, "samples": [["t": 1_799_000_000_000, "org": "one", "u": ["fh": 12, "sd": 15]]]])
        let snapshot = try XCTUnwrap(LocalUsageReader.read(from: directory, now: now))
        XCTAssertTrue(snapshot.isStale(at: now))
        XCTAssertTrue(snapshot.isStale(at: snapshot.observedAt.addingTimeInterval(-1)))
        XCTAssertFalse(snapshot.isStale(at: snapshot.observedAt.addingTimeInterval(900)))
        XCTAssertTrue(snapshot.isStale(at: snapshot.observedAt.addingTimeInterval(901)))
    }

    func testOversizedFileAndSymlinkAreNotRead() throws {
        let file = directory.appendingPathComponent(LocalUsageReader.historyFilename)
        try Data(repeating: 0x20, count: 2_097_153).write(to: file)
        XCTAssertNil(LocalUsageReader.read(from: directory, now: now))
        try FileManager.default.removeItem(at: file)
        let other = directory.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertNil(LocalUsageReader.read(from: directory, now: now))
    }

    private func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(LocalUsageReader.historyFilename))
    }
}
