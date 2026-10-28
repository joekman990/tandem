import AVFoundation
import CryptoKit
import Foundation
import TandemCore

/// The two halves of one SAM Audio separation of a file: what the prompt
/// describes (`target`) and everything else (`residual`). Both are 48 kHz
/// mono, as long as the file, starting at media time zero.
public struct SeparationStems: Equatable, Sendable {
    public var target: URL
    public var residual: URL

    public init(target: URL, residual: URL) {
        self.target = target
        self.residual = residual
    }
}

/// What made a separation, kept beside the stems.
public struct SeparationInfo: Codable, Equatable, Sendable {
    public var prompt: String
    public var model: String
    /// The file's path in the project folder when it was separated.
    public var mediaPath: String
    public var seconds: Double
    public var gpu: String?
    public var costUSD: Double?
    public var created: Date

    public init(prompt: String, model: String, mediaPath: String, seconds: Double, gpu: String? = nil, costUSD: Double? = nil, created: Date = Date()) {
        self.prompt = prompt
        self.model = model
        self.mediaPath = mediaPath
        self.seconds = seconds
        self.gpu = gpu
        self.costUSD = costUSD
        self.created = created
    }
}

/// SAM Audio separations, by file and prompt, in `.tandem/cache/separation/`:
///
///     separation/<key>/
///       target.wav  residual.wav  separation.json
///
/// `key = sha256(fingerprint|prompt|model)`, so a renamed file keeps its
/// separations and a different prompt or model makes new ones.
///
/// Not an `AnalysisKind`: a separation runs on a rented GPU and costs money,
/// so it's only ever made when someone asks (`tandem separate`), never in the
/// background. For the same reason the cache never evicts these (eviction
/// walks the analysis kinds) and archives keep them.
public struct SeparationStore: Sendable {
    public static let folderName = "separation"
    /// The model and how its candidates are ranked: part of the key, so a
    /// better setup makes new stems instead of reusing these.
    public static let model = "facebook/sam-audio-large, CLAP reranking"
    static let infoName = "separation.json"

    public let root: URL

    public init(cacheRoot: URL) {
        root = cacheRoot.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public init(folder: ProjectFolder) {
        self.init(cacheRoot: folder.cacheFolder)
    }

    /// SAM wants a short lowercase noun phrase; "Speech " and "speech" are
    /// the same separation.
    public static func normalized(_ prompt: String) -> String {
        prompt.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func key(fingerprint: String, prompt: String, model: String = SeparationStore.model) -> String {
        let text = "\(fingerprint)|\(normalized(prompt))|\(model)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func folder(fingerprint: String, prompt: String) -> URL {
        root.appendingPathComponent(Self.key(fingerprint: fingerprint, prompt: prompt), isDirectory: true)
    }

    /// The stems, once both are on disk.
    public func stems(fingerprint: String, prompt: String) -> SeparationStems? {
        let folder = folder(fingerprint: fingerprint, prompt: prompt)
        let stems = SeparationStems(target: folder.appendingPathComponent("target.wav"), residual: folder.appendingPathComponent("residual.wav"))
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folder.appendingPathComponent(Self.infoName).path),
              fileManager.fileExists(atPath: stems.target.path), fileManager.fileExists(atPath: stems.residual.path) else { return nil }
        return stems
    }

    public func info(fingerprint: String, prompt: String) -> SeparationInfo? {
        let url = folder(fingerprint: fingerprint, prompt: prompt).appendingPathComponent(Self.infoName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SeparationInfo.self, from: data)
    }

    /// Every finished separation of a file, by any prompt.
    public func all(fingerprint: String) -> [SeparationInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { name -> SeparationInfo? in
            let url = root.appendingPathComponent(name).appendingPathComponent(Self.infoName)
            guard let data = try? Data(contentsOf: url), let info = try? Self.decoder.decode(SeparationInfo.self, from: data),
                  Self.key(fingerprint: fingerprint, prompt: info.prompt, model: info.model) == name else { return nil }
            return info
        }.sorted { $0.created < $1.created }
    }

    /// Moves finished stems into place, replacing an older separation by the
    /// same prompt. The info file goes last, so a half-written folder is never
    /// taken for a finished one.
    @discardableResult
    public func commit(fingerprint: String, target: URL, residual: URL, info: SeparationInfo) throws -> SeparationStems {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(at: target, to: staging.appendingPathComponent("target.wav"))
            try fileManager.copyItem(at: residual, to: staging.appendingPathComponent("residual.wav"))
            try Self.encoder.encode(info).write(to: staging.appendingPathComponent(Self.infoName))
            let destination = folder(fingerprint: fingerprint, prompt: info.prompt)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        guard let stems = stems(fingerprint: fingerprint, prompt: info.prompt) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return stems
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension MediaAnalysis {
    public var separations: SeparationStore { SeparationStore(folder: folder) }

    /// The stems of `item` separated by `prompt`, if they've been made.
    public func separation(for item: MediaItem, prompt: String) -> SeparationStems? {
        guard let fingerprint = fingerprint(for: item) else { return nil }
        return separations.stems(fingerprint: fingerprint, prompt: prompt)
    }

    public func separationFingerprint(for item: MediaItem) -> String? {
        fingerprint(for: item)
    }
}

/// The sound SAM Audio separates: the file's audio as 48 kHz mono 32-bit
/// float WAV, starting at media time zero (silence in front of audio that
/// starts late, as the isolated voice does), so sample n of a stem lines up
/// with media time n / 48,000 and the render plan can play it like the file.
public enum SeparationInput {
    public static let sampleRate = 48_000.0

    /// Writes the WAV and returns its length in seconds.
    @discardableResult
    public static func write(source: URL, to url: URL) async throws -> Double {
        let reader = try await AudioReader(url: source, sampleRate: sampleRate, channels: 1)
        let feed = PlanarFeed(reader: reader, channels: 1, rangeStart: 0)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw MediaError.failed("Couldn't make an audio buffer")
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let expected = Int((reader.duration * sampleRate).rounded())
        var written = 0
        while written < expected {
            let count = min(4096, expected - written)
            buffer.frameLength = AVAudioFrameCount(count)
            feed.fill(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: count)
            if let error = feed.error { throw error }
            try file.write(from: buffer)
            written += count
        }
        return Double(written) / sampleRate
    }
}
