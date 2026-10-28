import XCTest
@testable import TandemMedia

/// SAM Audio stems in the cache, by file and prompt.
final class SeparationStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-separation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testCommitsAndFindsStemsByFileAndPrompt() throws {
        let store = SeparationStore(cacheRoot: folder.appendingPathComponent("cache"))
        XCTAssertNil(store.stems(fingerprint: "fp1", prompt: "speech"))
        let info = SeparationInfo(prompt: "speech", model: SeparationStore.model, mediaPath: "audio/Mic.wav", seconds: 154, gpu: "RTX 5090", costUSD: 0.26)
        let stems = try store.commit(fingerprint: "fp1", target: try file("t.wav", "target"), residual: try file("r.wav", "rest"), info: info)
        XCTAssertEqual(try String(contentsOf: stems.target, encoding: .utf8), "target")
        XCTAssertEqual(store.stems(fingerprint: "fp1", prompt: "  Speech "), stems, "the prompt is normalised")
        XCTAssertNil(store.stems(fingerprint: "fp1", prompt: "crowd chatter"))
        XCTAssertNil(store.stems(fingerprint: "fp2", prompt: "speech"), "another file")
        XCTAssertEqual(store.info(fingerprint: "fp1", prompt: "speech")?.costUSD, 0.26)
        XCTAssertEqual(store.root.lastPathComponent, "separation")

        // Separating again by the same prompt replaces it.
        try store.commit(fingerprint: "fp1", target: try file("t2.wav", "newer"), residual: try file("r2.wav", "rest"), info: info)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(store.stems(fingerprint: "fp1", prompt: "speech")).target, encoding: .utf8), "newer")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".tmp-") }
        XCTAssertEqual(leftovers, [])
    }

    func testAFolderWithoutItsInfoIsntFinished() throws {
        let store = SeparationStore(cacheRoot: folder)
        let half = store.folder(fingerprint: "fp", prompt: "speech")
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        try Data().write(to: half.appendingPathComponent("target.wav"))
        try Data().write(to: half.appendingPathComponent("residual.wav"))
        XCTAssertNil(store.stems(fingerprint: "fp", prompt: "speech"))
    }
}
