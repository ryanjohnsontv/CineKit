import Foundation

/// Resolves the real `.cine` sample files used for validation, via the
/// `CINE_SAMPLES_DIR` environment variable, so these large binary files
/// never need to live in the git repo. Test suites gate themselves on
/// `samplesAvailable` via a `.enabled(if:)` trait so they report as
/// *skipped* (not failed) on machines without the samples.
enum TestFixtures {
    static var samplesDirectory: URL? {
        ProcessInfo.processInfo.environment["CINE_SAMPLES_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static let knownFiles = [
        "Noise on Complex Image.cine",
        "Over Exposed (1000FPS).cine",
        "Point Sourse Light + under Exposed (1000FPS).cine",
        "Underexposed (240fps).cine",
    ]

    static var samplesAvailable: Bool {
        guard let dir = samplesDirectory else { return false }
        return knownFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    static func url(_ name: String) -> URL {
        samplesDirectory!.appendingPathComponent(name)
    }
}
