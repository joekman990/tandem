import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCLI
@testable import TandemCore
@testable import TandemMedia

/// `tandem separate` with a stand-in for render-box: what it sends the pod,
/// what it keeps, and that a prompt it has already paid for isn't run again.
final class SeparateCommandTests: XCTestCase {
    private var folder: URL!
    private var runner: URL!
    private var calls: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-separate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try writeTone(to: folder.appendingPathComponent("audio/Mic.wav"), seconds: 1.5)
        calls = folder.appendingPathComponent("runner-calls.txt")
        runner = folder.appendingPathComponent("fake-render-box")
        // Plays the pod: each prompt's stems are the input, a report and a cost.
        // With a "fail-once" file beside it, the first call finds no 5090.
        try """
        #!/bin/bash
        set -e
        here="$(dirname "$0")"
        echo "$@" >> "$here/runner-calls.txt"
        if [ -f "$here/fail-once" ]; then rm "$here/fail-once"; echo "render-box: No capacity in any allowed tier"; exit 1; fi
        up=""; down=""; cmd=""
        while [ $# -gt 0 ]; do
          case "$1" in --up) up="$2"; shift 2;; --down) down="${2#stems/:}"; shift 2;; --) cmd="$2"; shift; shift;; *) shift;; esac
        done
        mkdir -p "$down"
        for p in $(echo "$cmd" | grep -o "'p[0-9]*=" | tr -d "'="); do
          cp "$up/input.wav" "$down/$p.target.wav"; cp "$up/input.wav" "$down/$p.residual.wav"
        done
        echo '{"gpu": "NVIDIA GeForce RTX 5090"}' > "$down/report.json"
        echo '{"estimated_cost_usd": 0.3}' > "$here/job.json"
        echo "speech: window 1/1 done (20s, rerank 2)"
        echo "render-box: metrics: $here/job.json"
        """.write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let made = await CLI(arguments: ["new", folder.appendingPathComponent("Test.tandem").path], directory: folder, environment: [:]).run()
        XCTAssertEqual(made, 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 220 / 48_000) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func run(_ arguments: [String]) async -> Int32 {
        await CLI(arguments: arguments + ["--project", "Test.tandem"], directory: folder, environment: ["TANDEM_SEPARATE_RUNNER": runner.path]).run()
    }

    private var callCount: Int {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func testSeparatesEveryPromptInOneJobAndKeepsTheStems() async throws {
        let code = await run(["separate", "audio/Mic.wav", "Speech", "crowd chatter"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(callCount, 1, "one pod for both prompts")
        let call = try String(contentsOf: calls, encoding: .utf8)
        for part in ["--gpu 5090", "--plain", "--secret HF_TOKEN=huggingface", "--disk-gb 80", "--max-minutes", "'p0=speech'", "'p1=crowd chatter'"] {
            XCTAssertTrue(call.contains(part), "\(part) in \(call)")
        }
        XCTAssertFalse(call.contains("hf_"), "no token on the command line")

        let project = try ProjectFile.load(from: folder.appendingPathComponent("Test.tandem")).0
        let item = try XCTUnwrap(project.media.first { $0.path == "audio/Mic.wav" })
        let analysis = MediaAnalysis(folder: ProjectFolder(root: folder))
        let stems = try XCTUnwrap(analysis.separation(for: item, prompt: "speech"))
        XCTAssertNotNil(analysis.separation(for: item, prompt: "crowd chatter"))
        // The stems are the file's sound at 48 kHz mono, as long as the file.
        let target = try AVAudioFile(forReading: stems.target)
        XCTAssertEqual(target.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(Double(target.length) / 48_000, 1.5, accuracy: 0.01)
        let info = try XCTUnwrap(analysis.separations.info(fingerprint: XCTUnwrap(analysis.separationFingerprint(for: item)), prompt: "speech"))
        XCTAssertEqual(info.gpu, "RTX 5090")
        XCTAssertEqual(try XCTUnwrap(info.costUSD), 0.15, accuracy: 1e-9, "the job's cost shared between its prompts")

        // Asking again doesn't pay again; --again does.
        let again = await run(["separate", "audio/Mic.wav", "speech"])
        XCTAssertEqual(again, 0)
        XCTAssertEqual(callCount, 1)
        let forced = await run(["separate", "audio/Mic.wav", "speech", "--again"])
        XCTAssertEqual(forced, 0)
        XCTAssertEqual(callCount, 2)

        // Without prompts it lists what's there.
        let list = await run(["separate", item.id])
        XCTAssertEqual(list, 0)
    }

    func testTriesAnother5090WhenOneHasNoSSH() async throws {
        try Data().write(to: folder.appendingPathComponent("fail-once"))
        let code = await run(["separate", "audio/Mic.wav", "speech"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(callCount, 2)
    }

    func testRefusesSomethingThatIsntInTheProject() async {
        let code = await run(["separate", "audio/Nope.wav", "speech"])
        XCTAssertNotEqual(code, 0)
        XCTAssertEqual(callCount, 0)
    }

    func testMaxMinutesCoverSetupAndEveryPrompt() {
        XCTAssertEqual(Separator.maxMinutes(seconds: 45, prompts: 3), 18 + 4)
        XCTAssertEqual(Separator.maxMinutes(seconds: 360, prompts: 1), 18 + 10)
        XCTAssertEqual(Separator.maxMinutes(seconds: 3_600, prompts: 4), 240)
    }
}
