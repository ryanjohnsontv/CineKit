import Foundation
import Testing
@testable import CineKit

@Suite(.enabled(if: TestFixtures.samplesAvailable))
struct CineFileWriterTests {
    /// Writes each trimmed file into a fresh temp directory that's removed
    /// afterward, so repeated test runs never accumulate stale output.
    private func withTrimmedFile<T>(
        of sourceName: String,
        range: ClosedRange<Int>,
        _ body: (_ source: CineFile, _ trimmed: CineFile, _ outURL: URL) throws -> T
    ) throws -> T {
        let source = try CineFile(url: TestFixtures.url(sourceName))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outURL = dir.appendingPathComponent("trimmed.cine")
        try source.writeTrimmed(range: range, to: outURL)
        let trimmed = try CineFile(url: outURL)
        return try body(source, trimmed, outURL)
    }

    /// The full acceptance test: trims a real 100-frame sub-range out of a
    /// longer real sample, re-opens the written file with CineKit's own
    /// reader, and checks every claim in the task's verification bar —
    /// frame count, pixel-for-pixel equality against the original for every
    /// frame in range (not just the first), SETUP-derived fields, and exact
    /// predicted on-disk byte size. Run against two real sample files.
    @Test(arguments: [
        (file: "Point Sourse Light + under Exposed (1000FPS).cine", inIndex: 50, outIndex: 149),
        (file: "Noise on Complex Image.cine", inIndex: 50, outIndex: 149),
    ])
    func trimmedFileRoundTripsExactly(_ c: (file: String, inIndex: Int, outIndex: Int)) throws {
        try withTrimmedFile(of: c.file, range: c.inIndex...c.outIndex) { source, trimmed, outURL in
            let expectedCount = c.outIndex - c.inIndex + 1

            // (1) frameCount equals the trim's frame count exactly.
            #expect(trimmed.frameCount == expectedCount, "\(c.file)")
            #expect(trimmed.header.imageCount == UInt32(expectedCount), "\(c.file)")

            // (2) every frame's decoded pixels match the corresponding
            // original frame's decoded pixels, exactly, for every frame in
            // the range (not just the first).
            for i in 0..<expectedCount {
                let originalFrame = try source.decodeFrame(at: c.inIndex + i)
                let trimmedFrame = try trimmed.decodeFrame(at: i)
                #expect(trimmedFrame.pixels == originalFrame.pixels, "\(c.file) frame \(i) (source frame \(c.inIndex + i))")
                #expect(trimmedFrame.width == originalFrame.width, "\(c.file)")
                #expect(trimmedFrame.height == originalFrame.height, "\(c.file)")
                #expect(trimmedFrame.needsVerticalFlip == originalFrame.needsVerticalFlip, "\(c.file)")
            }

            // (3) every SETUP-derived field of interest reads back
            // identically between original and trimmed.
            #expect(trimmed.setup.frameRate == source.setup.frameRate, "\(c.file)")
            #expect(trimmed.setup.cfa == source.setup.cfa, "\(c.file)")
            #expect(trimmed.setup.blackLevel == source.setup.blackLevel, "\(c.file)")
            #expect(trimmed.setup.whiteLevel == source.setup.whiteLevel, "\(c.file)")
            #expect(trimmed.setup.realBPP == source.setup.realBPP, "\(c.file)")
            #expect(trimmed.setup.cmCalib == source.setup.cmCalib, "\(c.file)")
            #expect(trimmed.setup.colorCalibration?.matrix == source.setup.colorCalibration?.matrix, "\(c.file)")
            #expect(trimmed.setup.colorCalibration?.whiteBalanceR == source.setup.colorCalibration?.whiteBalanceR, "\(c.file)")
            #expect(trimmed.setup.colorCalibration?.whiteBalanceB == source.setup.colorCalibration?.whiteBalanceB, "\(c.file)")
            #expect(trimmed.setup.mark == source.setup.mark, "\(c.file)")
            #expect(trimmed.setup.length == source.setup.length, "\(c.file)")
            #expect(trimmed.bitmapInfo.width == source.bitmapInfo.width, "\(c.file)")
            #expect(trimmed.bitmapInfo.height == source.bitmapInfo.height, "\(c.file)")
            #expect(trimmed.bitmapInfo.bitCount == source.bitmapInfo.bitCount, "\(c.file)")
            #expect(trimmed.bitmapInfo.compression == source.bitmapInfo.compression, "\(c.file)")
            #expect(trimmed.bitmapInfo.sizeImage == source.bitmapInfo.sizeImage, "\(c.file)")

            // (4) exact predicted on-disk byte size: header + bitmap header
            // + setup + trimmed tagged-block region + offset table + sum of
            // frame block sizes, no stray padding or truncation.
            var predictedSize = CineFileHeader.byteSize + BitmapInfoHeader.byteSize + source.setup.length
            predictedSize += TaggedBlockRegion.trimmed(
                try source.rawTaggedBlockRegionBytes(),
                sourceFrameCount: source.frameCount,
                to: c.inIndex...c.outIndex
            ).count
            predictedSize += expectedCount * MemoryLayout<Int64>.size
            for i in 0..<expectedCount {
                predictedSize += try source.rawFrameBlockSize(at: c.inIndex + i)
            }
            let actualSize = try FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int
            #expect(actualSize == predictedSize, "\(c.file)")
        }
    }

    /// Header-field semantics (see `CineFileWriter`'s doc comment): the
    /// fields that describe the *original full acquisition*
    /// (`TotalImageCount`, `FirstMovieImage`, `TriggerTime`) are copied
    /// verbatim; `FirstImageNo` shifts by `inIndex` to keep trigger-relative
    /// frame numbering correct for the new file's frame 0.
    @Test func headerFieldSemantics() throws {
        try withTrimmedFile(of: "Underexposed (240fps).cine", range: 50...149) { source, trimmed, _ in
            #expect(trimmed.header.totalImageCount == source.header.totalImageCount)
            #expect(trimmed.header.firstMovieImage == source.header.firstMovieImage)
            #expect(trimmed.header.triggerTimeFractions == source.header.triggerTimeFractions)
            #expect(trimmed.header.triggerTimeSeconds == source.header.triggerTimeSeconds)
            #expect(trimmed.header.firstImageNo == source.header.firstImageNo + 50)
            #expect(trimmed.header.imageCount == 100)
            #expect(trimmed.header.headerSize == source.header.headerSize)
            #expect(trimmed.header.compression == source.header.compression)
            #expect(trimmed.header.version == source.header.version)
        }
    }

    /// The tagged-block region between `SETUP` and the frame offset table
    /// (real sample files carry per-frame TIME64/exposure arrays there —
    /// see `TaggedBlock`'s doc comment) must be trimmed, not dropped: each
    /// block's payload in the trimmed file must equal the *exact* byte
    /// slice of the source's corresponding block's payload for `range`,
    /// record for record, not just be the right overall size.
    @Test(arguments: [
        "Point Sourse Light + under Exposed (1000FPS).cine",
        "Noise on Complex Image.cine",
        "Over Exposed (1000FPS).cine",
        "Underexposed (240fps).cine",
    ])
    func taggedBlockRegionTrimsPerFrameArraysExactly(_ file: String) throws {
        let inIndex = 50, outIndex = 149
        try withTrimmedFile(of: file, range: inIndex...outIndex) { source, trimmed, _ in
            let sourceRegion = try source.rawTaggedBlockRegionBytes()
            let trimmedRegion = try trimmed.rawTaggedBlockRegionBytes()

            // Every real sample file has a nonzero gap here; if this ever
            // regresses to 0 the rest of this test would vacuously pass, so
            // assert the source actually has something to trim first.
            #expect(!sourceRegion.isEmpty, "\(file)")

            let (sourceBlocks, sourceTrailing) = TaggedBlockRegion.parse(sourceRegion)
            let (trimmedBlocks, trimmedTrailing) = TaggedBlockRegion.parse(trimmedRegion)

            #expect(sourceTrailing.isEmpty, "\(file): unparsed trailing bytes in source region")
            #expect(trimmedTrailing.isEmpty, "\(file): unparsed trailing bytes in trimmed region")
            #expect(sourceBlocks.count == trimmedBlocks.count, "\(file)")

            for (sourceBlock, trimmedBlock) in zip(sourceBlocks, trimmedBlocks) {
                #expect(trimmedBlock.type == sourceBlock.type, "\(file)")
                #expect(trimmedBlock.reserved == sourceBlock.reserved, "\(file)")

                // Every block in every real sample divides evenly into a
                // per-frame stride (8 bytes for the TIME64 array, 4 for the
                // exposure array) — confirm the trimmed payload is exactly
                // the [inIndex...outIndex] record slice of the source's,
                // not merely the right length.
                #expect(sourceBlock.payload.count % source.frameCount == 0, "\(file)")
                let stride = sourceBlock.payload.count / source.frameCount
                #expect(trimmedBlock.payload.count == (outIndex - inIndex + 1) * stride, "\(file)")

                let expectedSlice = sourceBlock.payload.subdata(
                    in: (inIndex * stride)..<((outIndex + 1) * stride)
                )
                #expect(trimmedBlock.payload == expectedSlice, "\(file) type \(sourceBlock.type)")
            }
        }
    }

    @Test func invalidRangeThrows() throws {
        let source = try CineFile(url: TestFixtures.url("Underexposed (240fps).cine"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("trimmed.cine")

        #expect(throws: CineError.self) {
            try source.writeTrimmed(range: (-1)...10, to: outURL)
        }
        #expect(throws: CineError.self) {
            try source.writeTrimmed(range: (source.frameCount - 1)...source.frameCount, to: outURL)
        }
    }
}
