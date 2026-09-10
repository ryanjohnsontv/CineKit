import Testing
@testable import CineKit

@Suite(.enabled(if: TestFixtures.samplesAvailable))
struct FrameDecodeTests {
    @Test func firstFrameOffsetsMatchKnownValues() throws {
        let cases: [(file: String, firstThreeOffsets: [Int64])] = [
            ("Noise on Complex Image.cine", [19512, 2_611_520, 5_203_528]),
            ("Over Exposed (1000FPS).cine", [24024, 2_616_032, 5_208_040]),
            ("Point Sourse Light + under Exposed (1000FPS).cine", [16984, 2_608_992, 5_201_000]),
            ("Underexposed (240fps).cine", [23784, 2_615_792, 5_207_800]),
        ]

        for c in cases {
            let url = TestFixtures.url(c.file)
            let file = try CineFile(url: url)
            let store = try MappedFileBackingStore(url: url)
            let table = try FrameOffsetTable(store: store, header: file.header)
            for i in 0..<c.firstThreeOffsets.count {
                #expect(table[i] == c.firstThreeOffsets[i], "\(c.file) frame \(i)")
            }
        }
    }

    @Test func frameBlockPixelDataSizeMatchesBitmapSizeImage() throws {
        // Every real sample has a minimal (8-byte) per-frame annotation block,
        // so pixel data should start exactly 8 bytes after each frame offset
        // and its declared size should exactly equal biSizeImage.
        for name in TestFixtures.knownFiles {
            let url = TestFixtures.url(name)
            let file = try CineFile(url: url)
            let store = try MappedFileBackingStore(url: url)
            let table = try FrameOffsetTable(store: store, header: file.header)
            let reader = FrameReader(store: store)

            let raw = try reader.readRawFrame(at: table[0])
            #expect(raw.annotation.count == 0, "\(name)")
            #expect(raw.pixelData.count == file.bitmapInfo.sizeImage, "\(name)")
        }
    }

    /// Bootstrapped regression baselines: these exact statistics were
    /// computed once from the already visually-validated decode pipeline
    /// (confirmed via rendered preview PNGs — a correct point-source bloom
    /// and a correctly-oriented, recognizable scene), since no independent
    /// external oracle for pixel values exists for this proprietary format.
    ///
    /// Re-bootstrapped after adding `P10Linearization` to `P10Unpacker` (all
    /// 4 real samples are P10-packed — see `SetupParsingTests`) — that fix
    /// is a deliberate, documented, spec-mandated behavior change (P10's
    /// packed codes are gamma-companded, not linear; see `P10Unpacker`'s own
    /// doc comment), not a regression, so these baselines needed updating to
    /// match, not the other way around. `expectedMin` moving from 0 to 2
    /// specifically matches `P10Linearization.lut[0] == 2` exactly — the
    /// darkest possible packed code no longer decodes to a literal zero.
    @Test func decodedPixelStatisticsBaselines() throws {
        struct Case {
            let file: String
            let frameIndex: Int
            let expectedMin: UInt16
            let expectedMax: UInt16
            let expectedMean: Double
        }

        let cases: [Case] = [
            Case(file: "Underexposed (240fps).cine", frameIndex: 0, expectedMin: 2, expectedMax: 366, expectedMean: 62.428636188271604),
            Case(file: "Point Sourse Light + under Exposed (1000FPS).cine", frameIndex: 150, expectedMin: 2, expectedMax: 4048, expectedMean: 662.7911983989197),
            Case(file: "Noise on Complex Image.cine", frameIndex: 100, expectedMin: 2, expectedMax: 4048, expectedMean: 839.1766603973765),
        ]

        for c in cases {
            let file = try CineFile(url: TestFixtures.url(c.file))
            let frame = try file.decodeFrame(at: c.frameIndex)

            #expect(frame.pixels.count == frame.width * frame.height, "\(c.file)")

            var minValue = UInt16.max
            var maxValue = UInt16.min
            var sum: Double = 0
            for value in frame.pixels {
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)
                sum += Double(value)
            }
            let mean = sum / Double(frame.pixels.count)

            #expect(minValue == c.expectedMin, "\(c.file) frame \(c.frameIndex) min")
            #expect(maxValue == c.expectedMax, "\(c.file) frame \(c.frameIndex) max")
            #expect(abs(mean - c.expectedMean) < 0.01, "\(c.file) frame \(c.frameIndex) mean")
        }
    }

    /// All 4 real samples are P10-packed with `SETUP.BlackLevel == 64`/
    /// `WhiteLevel == 1015` (see `SetupParsingTests
    /// .blackAndWhiteLevelsAreConsistentAcrossSamples`) — those are the
    /// pre-linearization packed-domain numbers. `CineFile
    /// .effectiveBlackWhiteLevels` should report them re-expressed in the
    /// same linear domain `decodeFrame(at:)`'s own pixel output is now in:
    /// `P10Linearization.lut[64] == 64` (the documented black-point fixed
    /// point) and `lut[1015] == 4095` (1015 sits one past the spec's own
    /// documented white-point example of 1014, landing in the table's
    /// saturating tail — not the "clean" 4064 the spec's own worked example
    /// would suggest, which is exactly why this needs to look the real
    /// value up rather than assume the documented example applies
    /// verbatim). Deliberately different from `setup
    /// .effectiveBlackWhiteLevels`, which must keep reporting the raw
    /// packed-domain 64/1015 unchanged — see that property's own doc
    /// comment.
    @Test func effectiveBlackWhiteLevelsAreLinearizedForP10Samples() throws {
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            #expect(file.bitmapInfo.compression == .p10Packed, "\(name)")
            let raw = file.setup.effectiveBlackWhiteLevels
            #expect(raw == (64, 1015), "\(name)")
            let linearized = file.effectiveBlackWhiteLevels
            #expect(linearized == (64, 4095), "\(name)")
        }
    }

    @Test func frameIndexOutOfRangeThrows() throws {
        let file = try CineFile(url: TestFixtures.url("Underexposed (240fps).cine"))
        #expect(throws: CineError.self) {
            try file.decodeFrame(at: file.frameCount)
        }
        #expect(throws: CineError.self) {
            try file.decodeFrame(at: -1)
        }
    }

    @Test func byteOffsetOfFrameMatchesFrameOffsetTable() throws {
        // Same known-good offsets as firstFrameOffsetsMatchKnownValues above
        // — byteOffset(ofFrame:) is meant to be exactly this same value,
        // just through CineFile's public API instead of a private
        // FrameOffsetTable the caller isn't allowed to construct itself.
        let cases: [(file: String, firstThreeOffsets: [Int64])] = [
            ("Noise on Complex Image.cine", [19512, 2_611_520, 5_203_528]),
            ("Over Exposed (1000FPS).cine", [24024, 2_616_032, 5_208_040]),
            ("Point Sourse Light + under Exposed (1000FPS).cine", [16984, 2_608_992, 5_201_000]),
            ("Underexposed (240fps).cine", [23784, 2_615_792, 5_207_800]),
        ]

        for c in cases {
            let file = try CineFile(url: TestFixtures.url(c.file))
            for i in 0..<c.firstThreeOffsets.count {
                #expect(try file.byteOffset(ofFrame: i) == Int(c.firstThreeOffsets[i]), "\(c.file) frame \(i)")
            }
        }
    }

    @Test func byteOffsetOfFrameOutOfRangeThrows() throws {
        let file = try CineFile(url: TestFixtures.url("Underexposed (240fps).cine"))
        #expect(throws: CineError.self) {
            _ = try file.byteOffset(ofFrame: file.frameCount)
        }
        #expect(throws: CineError.self) {
            _ = try file.byteOffset(ofFrame: -1)
        }
    }

    /// `primeFileCache(at:startOffset:)`'s whole contract is "eventually
    /// warms the whole file, biased toward `startOffset` first" — it has no
    /// return value to assert on (see its own doc comment on why it's
    /// deliberately best-effort/silent), so the meaningful regression to
    /// guard here is that a biased start doesn't hang or throw its way into
    /// leaving the file only half-read. Reaching the end of this test is the
    /// actual assertion.
    @Test func primeFileCacheWithBiasedStartOffsetCompletes() async throws {
        let url = TestFixtures.url("Underexposed (240fps).cine")
        let file = try CineFile(url: url)
        let midOffset = try file.byteOffset(ofFrame: file.frameCount / 2)
        await primeFileCache(at: url, startOffset: midOffset, chunkSize: 1 << 20)
    }

    /// A `startOffset` past the end of the file should degrade to warming
    /// the whole file from `0`, not hang — see `primeFileCache`'s own doc
    /// comment for why no explicit bounds check is needed for this to be
    /// safe.
    @Test func primeFileCacheWithOutOfRangeStartOffsetCompletes() async throws {
        let url = TestFixtures.url("Underexposed (240fps).cine")
        let store = try MappedFileBackingStore(url: url)
        await primeFileCache(at: url, startOffset: store.count + 1_000_000, chunkSize: 1 << 20)
    }
}
