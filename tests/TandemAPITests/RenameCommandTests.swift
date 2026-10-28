import XCTest
@testable import TandemAPI
@testable import TandemCLI
@testable import TandemCore

/// `tandem rename`: the same rename as the project list's, from the command
/// line, with the app's memory of the project (its place in the recent list,
/// where its timeline and window were) following it.
final class RenameCommandTests: XCTestCase {
    private var folder: URL!
    private var project: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-rename-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project = folder.appendingPathComponent("Read the Code.tandem")
        try ProjectFile.save(Project(id: "prj_short", name: "Read the Code"), revision: 3, to: project)
        suite = "tandem-rename-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ arguments: [String]) async -> Int32 {
        await CLI(arguments: arguments, directory: folder, environment: ["TANDEM_DEFAULTS_SUITE": suite]).run()
    }

    func testRecordsFollowTheRenamedProject() {
        let old = project.standardizedFileURL.path
        let new = folder.appendingPathComponent("01 Read the Code.tandem").standardizedFileURL.path
        defaults.set(["/x/Other.tandem", old, "/x/Third.tandem"], forKey: ProjectPlaces.recentKey)
        defaults.set([old: ["playhead": 4.0, "pixelsPerSecond": 80.0, "scrollSeconds": 0.0, "verticalOffset": 0.0]], forKey: ProjectPlaces.timelinesKey)
        defaults.set([old: "{{0, 0}, {800, 600}}", "/x/Other.tandem": "{{1, 1}, {2, 2}}"], forKey: ProjectPlaces.windowFramesKey)

        ProjectPlaces.moved(from: project, to: URL(fileURLWithPath: new), in: defaults)

        XCTAssertEqual(defaults.stringArray(forKey: ProjectPlaces.recentKey), ["/x/Other.tandem", new, "/x/Third.tandem"], "keeps its place in the list")
        XCTAssertEqual((defaults.dictionary(forKey: ProjectPlaces.timelinesKey) as? [String: [String: Double]])?[new]?["playhead"], 4.0)
        XCTAssertNil((defaults.dictionary(forKey: ProjectPlaces.timelinesKey))?[old])
        let frames = defaults.dictionary(forKey: ProjectPlaces.windowFramesKey) as? [String: String]
        XCTAssertEqual(frames?[new], "{{0, 0}, {800, 600}}")
        XCTAssertEqual(frames?["/x/Other.tandem"], "{{1, 1}, {2, 2}}")
        XCTAssertNil(frames?[old])
    }

    func testAProjectOffTheListIsntAddedToIt() {
        defaults.set(["/x/Other.tandem"], forKey: ProjectPlaces.recentKey)
        ProjectPlaces.moved(from: project, to: folder.appendingPathComponent("New.tandem"), in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: ProjectPlaces.recentKey), ["/x/Other.tandem"])
    }

    func testRenamesTheProjectNamedAfterTheCommand() async throws {
        defaults.set([project.standardizedFileURL.path], forKey: ProjectPlaces.recentKey)
        let code = await run(["rename", "Read the Code.tandem", "01 Read the Code"])
        XCTAssertEqual(code, 0)
        let renamed = folder.appendingPathComponent("01 Read the Code.tandem")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
        XCTAssertEqual(try ProjectFile.load(from: renamed).0.name, "01 Read the Code")
        XCTAssertEqual(defaults.stringArray(forKey: ProjectPlaces.recentKey), [renamed.standardizedFileURL.path])
    }

    func testFindsTheProjectInTheFolderAndTakesANameWithTheExtension() async throws {
        let code = await run(["rename", "02 Read the Code.tandem"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("02 Read the Code.tandem").path))
    }

    func testRefusesWhileTheProjectIsOpen() async throws {
        // A lock from another process: one this process holds counts as its own.
        let lockURL = ProjectSession.lockURL(for: project)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard case .acquired(let lock) = try LockHandle.acquire(lockURL, lock: ProjectSession.Lock(pid: 1, owner: .app, started: Date())) else {
            return XCTFail("couldn't take the lock")
        }
        defer { lock.release() }
        let code = await run(["rename", "Read the Code.tandem", "01 Read the Code"])
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path), "left where it was")
    }

    func testUsageErrors() async {
        let none = await run(["rename"])
        XCTAssertEqual(none, 2)
        let tooMany = await run(["rename", "a.tandem", "b", "c"])
        XCTAssertEqual(tooMany, 2)
    }
}
