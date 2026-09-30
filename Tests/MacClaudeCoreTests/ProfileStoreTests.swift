import Foundation
import XCTest
@testable import MacClaudeCore

final class ProfileStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacClaudeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = ProfileStore(rootDirectory: temporaryDirectory.appendingPathComponent("Store"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testMissingConfigurationCreatesOnlyInMemoryPersonalAccount() throws {
        let configuration = try store.load()
        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.profiles.count, 1)
        XCTAssertEqual(configuration.profiles[0].name, "Personal")
        XCTAssertTrue(configuration.profiles[0].isDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootDirectory.path))
    }

    func testSaveRoundTripAndPrivatePermissions() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let profiles = [AccountProfile(id: "default", name: "Personal", createdAt: date), AccountProfile(name: "Work", createdAt: date)]
        let configuration = AppConfiguration(profiles: profiles, claudeApplicationPath: "/Applications/Claude.app", lastOpenedProfileID: profiles[1].id)
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: store.rootDirectory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.configurationURL.path)
        XCTAssertEqual((rootAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.rootDirectory.path), ["config.json"])
    }

    func testMalformedExistingConfigurationIsNeverResetOrOverwritten() throws {
        try FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        let original = Data("{ broken configuration".utf8)
        try original.write(to: store.configurationURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(AppConfiguration()))
        XCTAssertEqual(try Data(contentsOf: store.configurationURL), original)
    }

    func testUnknownSchemaCannotBeReadOrOverwritten() throws {
        try store.save(AppConfiguration())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.configurationURL)) as? [String: Any])
        object["schemaVersion"] = 99
        let original = try JSONSerialization.data(withJSONObject: object)
        try original.write(to: store.configurationURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ProfileStoreError, .unsupportedSchema(99))
        }
        XCTAssertThrowsError(try store.save(AppConfiguration()))
        XCTAssertEqual(try Data(contentsOf: store.configurationURL), original)
    }

    func testRejectsTraversalAndMalformedIdentifiersBeforeWriting() throws {
        for id in ["../outside", "/tmp/outside", "name/child", "not-a-uuid", "", "DEFAULT"] {
            let configuration = AppConfiguration(profiles: [.personal, AccountProfile(id: id, name: "Work")])
            XCTAssertThrowsError(try store.save(configuration), "Accepted identifier: \(id)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootDirectory.path))
    }

    func testRejectsStoredTraversalWithoutModifyingFile() throws {
        try store.save(AppConfiguration())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.configurationURL)) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        var unsafe = profiles[0]
        unsafe["id"] = "../../Claude"
        profiles.append(unsafe)
        object["profiles"] = profiles
        let original = try JSONSerialization.data(withJSONObject: object)
        try original.write(to: store.configurationURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.configurationURL), original)
    }

    func testRejectsDuplicateIDsIncludingCaseVariants() throws {
        let id = UUID().uuidString
        XCTAssertThrowsError(try store.save(AppConfiguration(profiles: [
            .personal,
            AccountProfile(id: id, name: "Work"),
            AccountProfile(id: id.lowercased(), name: "Other")
        ])))
        XCTAssertThrowsError(try store.save(AppConfiguration(profiles: [.personal, .personal])))
    }

    func testDefaultAndLastOpenedReferentialIntegrity() throws {
        XCTAssertThrowsError(try store.save(AppConfiguration(profiles: [])))
        XCTAssertThrowsError(try store.save(AppConfiguration(profiles: [AccountProfile(name: "Work")])))
        XCTAssertThrowsError(try store.save(AppConfiguration(lastOpenedProfileID: UUID().uuidString)))
    }

    func testNameValidationTrimsAndRejectsUnusableNames() throws {
        XCTAssertEqual(try ProfileStore.validatedName("  Work  \n"), "Work")
        XCTAssertEqual(try ProfileStore.validatedName("Økonomi 🦊"), "Økonomi 🦊")
        for name in ["", " \n\t", String(repeating: "a", count: 61), "Work\nAccount", "Work\0"] {
            XCTAssertThrowsError(try ProfileStore.validatedName(name))
        }
        XCTAssertThrowsError(try store.save(AppConfiguration(profiles: [AccountProfile(id: "default", name: " Personal ")])))
    }

    func testSaveNeverDeletesRemovedProfilesData() throws {
        let profile = AccountProfile(name: "Work")
        try store.save(AppConfiguration(profiles: [.personal, profile]))
        let profileDirectory = ProfilePaths(rootDirectory: store.rootDirectory, homeDirectory: temporaryDirectory).userDataDirectory(for: profile)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let document = profileDirectory.appendingPathComponent("preserved.txt")
        try Data("keep".utf8).write(to: document)
        try store.save(AppConfiguration())
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "keep")
    }

    func testSymlinkAndOversizedConfigurationFailClosed() throws {
        try FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        let target = temporaryDirectory.appendingPathComponent("target.json")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.configurationURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(AppConfiguration()))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
        try FileManager.default.removeItem(at: store.configurationURL)
        try Data(repeating: 0x20, count: 1_048_577).write(to: store.configurationURL)
        XCTAssertThrowsError(try store.load())
    }

    func testSymlinkStorageRootCannotOverwriteConfigurationOrAlterTargetPermissions() throws {
        let actualRoot = temporaryDirectory.appendingPathComponent("ActualStore")
        let actualStore = ProfileStore(rootDirectory: actualRoot)
        try actualStore.save(AppConfiguration())
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: actualRoot.path)
        let original = try Data(contentsOf: actualStore.configurationURL)
        try FileManager.default.createSymbolicLink(at: store.rootDirectory, withDestinationURL: actualRoot)
        XCTAssertThrowsError(try store.save(AppConfiguration(profiles: [.personal, AccountProfile(name: "Work")])))
        XCTAssertEqual(try Data(contentsOf: actualStore.configurationURL), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: actualRoot.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o750)
    }
}
