import Foundation
import XCTest
@testable import MacClaudeCore

final class InstanceProfileTests: XCTestCase {
    private let paths = ProfilePaths(rootDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support/MacClaude"), homeDirectory: URL(fileURLWithPath: "/Users/test"))

    func testDefaultUsesExistingClaudeDataWithoutLaunchOverrides() {
        XCTAssertEqual(paths.userDataDirectory(for: .personal).path, "/Users/test/Library/Application Support/Claude")
        XCTAssertEqual(paths.launchArguments(for: .personal), [])
        XCTAssertEqual(InstanceProfile.classify(arguments: ["/Applications/Claude.app/Contents/MacOS/Claude"]), .defaultProfile)
        XCTAssertTrue(InstanceProfile.defaultProfile.matches(profile: .personal, paths: paths))
    }

    func testManagedProfileArgumentIsSingleLiteralArgumentWithSpaces() {
        let profile = AccountProfile(id: "A449BF16-5C47-4236-B2B5-9642EB25AC87", name: "Work")
        let directory = "/Users/test/Library/Application Support/MacClaude/Profiles/a449bf16-5c47-4236-b2b5-9642eb25ac87"
        XCTAssertEqual(paths.userDataDirectory(for: profile).path, directory)
        XCTAssertEqual(paths.launchArguments(for: profile), ["--user-data-dir=\(directory)"])
        XCTAssertTrue(InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(directory)"]).matches(profile: profile, paths: paths))
    }

    func testBothSupportedFlagFormsNormalizeDirectory() {
        let base = "/__MacClaudeTests_NoSuchDirectory__"
        XCTAssertEqual(InstanceProfile.classify(arguments: ["Claude", "--user-data-dir", "\(base)/example/"]), .directory("\(base)/example"))
        XCTAssertEqual(InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(base)/one/../example"]), .directory("\(base)/example"))
        XCTAssertEqual(InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(base)/example", "--user-data-dir", "\(base)/example/"]), .directory("\(base)/example"))
    }

    func testMissingUnreadableEmptyRelativeOrConflictingArgumentsAreUnknown() {
        XCTAssertEqual(InstanceProfile.classify(arguments: nil), .unknown)
        for arguments in [
            ["Claude", "--user-data-dir"],
            ["Claude", "--user-data-dir="],
            ["Claude", "--user-data-dir", ""],
            ["Claude", "--user-data-dir", "--other-flag"],
            ["Claude", "--user-data-dir=relative/path"],
            ["Claude", "--user-data-dir=/tmp/one", "--user-data-dir=/tmp/two"],
            ["Claude", "--user-data-dir=/tmp/one", "--user-data-dir="],
            ["Claude", "--user-data-dir=/tmp/\0invalid"]
        ] {
            XCTAssertEqual(InstanceProfile.classify(arguments: arguments), .unknown, "\(arguments)")
        }
    }

    func testUnknownAndOtherProfilesNeverMatch() {
        let work = AccountProfile(name: "Work")
        XCTAssertFalse(InstanceProfile.unknown.matches(profile: .personal, paths: paths))
        XCTAssertFalse(InstanceProfile.defaultProfile.matches(profile: work, paths: paths))
        XCTAssertFalse(InstanceProfile.directory("/tmp/other").matches(profile: work, paths: paths))
        XCTAssertTrue(InstanceProfile.directory(paths.userDataDirectory(for: .personal).path).matches(profile: .personal, paths: paths))
    }

    func testUnvalidatedPathTraversalStaysContainedAndNeverMatches() {
        let unsafe = AccountProfile(id: "../../../../other", name: "Unsafe")
        let directory = paths.userDataDirectory(for: unsafe)
        XCTAssertEqual(directory.path, paths.rootDirectory.appendingPathComponent("Profiles/.invalid-profile").path)
        XCTAssertFalse(InstanceProfile.directory(directory.path).matches(profile: unsafe, paths: paths))
    }

    func testSymlinkAliasesIdentifyBothDefaultAndManagedProfiles() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacClaudeIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = ProfilePaths(rootDirectory: temporary.appendingPathComponent("Store"), homeDirectory: temporary.appendingPathComponent("Home"))
        for profile in [AccountProfile.personal, AccountProfile(name: "Work")] {
            let directory = paths.userDataDirectory(for: profile)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let alias = temporary.appendingPathComponent("alias-\(profile.id)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            XCTAssertTrue(InstanceProfile.directory(alias.path).matches(profile: profile, paths: paths))
            XCTAssertTrue(InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(alias.path)"]).matches(profile: profile, paths: paths))
            XCTAssertEqual(InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(alias.path)", "--user-data-dir=\(directory.path)"]), InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(directory.path)"]))
        }
    }

    func testSymlinkParentTraversalUsesFilesystemSemantics() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacClaudeTraversalTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let profile = AccountProfile(name: "Work")
        let paths = ProfilePaths(rootDirectory: temporary.appendingPathComponent("Store"), homeDirectory: temporary.appendingPathComponent("Home"))
        let directory = paths.userDataDirectory(for: profile)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = temporary.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        let instance = InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(alias.path)/.."])
        XCTAssertTrue(instance.matches(profile: profile, paths: paths))
        XCTAssertNotEqual(instance, .directory(temporary.path))
    }

    func testCaseInsensitiveFilesystemAliasIdentifiesManagedProfile() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacClaudeCaseTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let profile = AccountProfile(name: "Work")
        let paths = ProfilePaths(rootDirectory: temporary.appendingPathComponent("Store"), homeDirectory: temporary.appendingPathComponent("Home"))
        let directory = paths.userDataDirectory(for: profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alias = directory.deletingLastPathComponent().appendingPathComponent(profile.id.uppercased())
        guard FileManager.default.fileExists(atPath: alias.path) else { throw XCTSkip("Temporary volume is case-sensitive.") }
        XCTAssertTrue(InstanceProfile.directory(alias.path).matches(profile: profile, paths: paths))
        XCTAssertTrue(InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(alias.path)"]).matches(profile: profile, paths: paths))
        XCTAssertNotEqual(InstanceProfile.classify(arguments: ["Claude", "--user-data-dir=\(alias.path)", "--user-data-dir=\(directory.path)"]), .unknown)
    }

    func testExistingRegularFileCannotIdentifyProfileDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacClaudeFileIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let profile = AccountProfile(name: "Work")
        let paths = ProfilePaths(rootDirectory: temporary.appendingPathComponent("Store"), homeDirectory: temporary.appendingPathComponent("Home"))
        let directory = paths.userDataDirectory(for: profile)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: directory)
        XCTAssertFalse(InstanceProfile.directory(directory.path).matches(profile: profile, paths: paths))
    }
}
