import Testing
@testable import CineKit

@Suite(.enabled(if: TestFixtures.samplesAvailable))
struct CineFileHeaderTests {
    /// All 4 real samples share the same capture resolution/format, so a lot
    /// of this is common across files — verified once per file to catch any
    /// per-file surprises.
    @Test func commonHeaderFieldsAcrossAllSamples() throws {
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))

            #expect(file.header.headerSize == 44, "\(name)")
            #expect(file.header.version == 1, "\(name)")
            #expect(file.bitmapInfo.width == 1920, "\(name)")
            #expect(file.bitmapInfo.height == 1080, "\(name)")
            #expect(file.bitmapInfo.bitCount == 16, "\(name)")
            #expect(file.bitmapInfo.compression == .p10Packed, "\(name)")
            #expect(file.bitmapInfo.sizeImage == 2_592_000, "\(name)")
            #expect(!file.needsVerticalFlip, "P10 frames should not need a vertical flip: \(name)")
        }
    }

    @Test func perFileImageCountsAndOffsets() throws {
        let cases: [(file: String, imageCount: UInt32, totalImageCount: UInt32, firstImageNo: Int32, offImageOffsets: Int)] = [
            ("Noise on Complex Image.cine", 450, 4094, -2658, 15912),
            ("Over Exposed (1000FPS).cine", 729, 4094, -4084, 18192),
            ("Point Sourse Light + under Exposed (1000FPS).cine", 377, 4094, -941, 13968),
            ("Underexposed (240fps).cine", 717, 4094, -2984, 18048),
        ]

        for c in cases {
            let file = try CineFile(url: TestFixtures.url(c.file))

            #expect(file.header.imageCount == c.imageCount, "\(c.file)")
            #expect(file.header.totalImageCount == c.totalImageCount, "\(c.file)")
            #expect(file.header.firstImageNo == c.firstImageNo, "\(c.file)")
            #expect(file.header.offImageOffsets == c.offImageOffsets, "\(c.file)")
            #expect(file.frameCount == Int(c.imageCount), "\(c.file)")
        }
    }
}
