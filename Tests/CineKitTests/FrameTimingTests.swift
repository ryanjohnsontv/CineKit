import Testing
@testable import CineKit

@Suite(.enabled(if: TestFixtures.samplesAvailable))
struct FrameTimingTests {
    @Test func frameCaptureTimesAreMonotonicAndNeverAfterTriggerTimeAcrossAllSamples() throws {
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            guard let times = try file.frameCaptureTimes() else {
                Issue.record("expected frameCaptureTimes to be present for \(name)")
                continue
            }
            #expect(times.count == file.frameCount, "\(name)")

            let monotonic = zip(times, times.dropFirst()).allSatisfy { a, b in
                (a.seconds, a.fractions) <= (b.seconds, b.fractions)
            }
            #expect(monotonic, "\(name)")

            // Every real sample here is a pre-trigger buffer: no frame's
            // capture time is ever recorded after the header's own
            // TriggerTime — see `TaggedBlock`'s doc comment for why the
            // actual per-file gap varies and isn't a tight bound.
            for time in times {
                #expect(time.seconds <= file.header.triggerTimeSeconds, "\(name)")
            }
        }
    }

    @Test func frameExposureNanosecondsIsConstantAndMatchesKnownValues() throws {
        // Every real sample here is a fixed-shutter recording (no per-frame
        // exposure ramping), so the whole array collapses to one repeated
        // value — a real, if narrow, regression signal that the array is
        // being decoded correctly (a byte-order or stride bug would produce
        // wildly varying "exposure" values instead of a flat one).
        let cases: [(file: String, expectedNs: UInt32)] = [
            ("Noise on Complex Image.cine", 536_870),
            ("Over Exposed (1000FPS).cine", 339_302),
            ("Point Sourse Light + under Exposed (1000FPS).cine", 339_302),
            ("Underexposed (240fps).cine", 2_233_382),
        ]
        for c in cases {
            let file = try CineFile(url: TestFixtures.url(c.file))
            guard let exposures = try file.frameExposureNanoseconds() else {
                Issue.record("expected frameExposureNanoseconds to be present for \(c.file)")
                continue
            }
            #expect(exposures.count == file.frameCount, "\(c.file)")
            #expect(Set(exposures) == [c.expectedNs], "\(c.file)")
        }
    }

    @Test func shutter16RoughlyMatchesShutterNsAcrossAllSamples() throws {
        // shutter16 is a truncated legacy microseconds-unit predecessor of
        // shutterNs (nanoseconds) — not bit-exact, but should round-trip to
        // within 1 microsecond of shutterNs when converted.
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            guard let shutterNs = file.setup.shutterNs, let shutter16 = file.setup.shutter16 else {
                Issue.record("expected both shutterNs and shutter16 to be present for \(name)")
                continue
            }
            let diff = Int64(shutterNs) - Int64(shutter16) * 1000
            #expect(abs(diff) < 1000, "\(name)")
        }
    }

    @Test func dFrameRateIsAbsentFromEveryRealSample() throws {
        // At offset 13472, right against the 13484-byte maxKnownSize
        // ceiling — none of these 4 real files have a SETUP block anywhere
        // near that long (see SetupParsingTests's own length checks), so
        // this must always read back nil here, never garbage.
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            #expect(file.setup.dFrameRate == nil, "\(name)")
        }
    }
}
