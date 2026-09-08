import Testing
import Foundation
@testable import CineKit

/// Synthetic, hand-built byte vectors — deliberately not gated behind
/// `TestFixtures.samplesAvailable` like most of this package's other tests,
/// since none of the 4 real sample files use uncompressed pixel data
/// (`biCompression == 0`), so this is the only coverage this unpacker gets
/// at all. Real Vision Research cameras absolutely do produce uncompressed
/// output (typically 16-bit, at very low frame rates), so this path is far
/// from hypothetical — just untested against a real file today.
struct UncompressedUnpackerTests {
    @Test func needsVerticalFlipIsTrue() throws {
        // Confirmed empirically for uncompressed frames — see
        // `PixelUnpacker.needsVerticalFlip`'s own doc comment.
        let unpacker = try UncompressedUnpacker(bitCount: 8)
        #expect(unpacker.needsVerticalFlip)
    }

    @Test func rejectsUnsupportedBitCounts() {
        for bitCount: UInt16 in [1, 4, 10, 12, 32] {
            #expect(throws: CineError.self) {
                _ = try UncompressedUnpacker(bitCount: bitCount)
            }
        }
    }

    @Test func unpacks8BitSamplesDirectly() throws {
        let unpacker = try UncompressedUnpacker(bitCount: 8)
        let raw = Data([0x00, 0x01, 0x7F, 0xFF])
        let pixels = unpacker.unpack(raw: raw, width: 2, height: 2)
        #expect(pixels == [0, 1, 127, 255])
    }

    @Test func unpacks16BitSamplesAsLittleEndian() throws {
        let unpacker = try UncompressedUnpacker(bitCount: 16)
        // Little-endian on disk, low byte first. Values chosen to catch a
        // byte-swap or stride bug: 0x0102, 0x0304, 0xFFFE, 0x0000.
        let raw = Data([0x02, 0x01, 0x04, 0x03, 0xFE, 0xFF, 0x00, 0x00])
        let pixels = unpacker.unpack(raw: raw, width: 2, height: 2)
        #expect(pixels == [0x0102, 0x0304, 0xFFFE, 0x0000])
    }

    @Test func unpackDoesNotFlipRowsItself() throws {
        // `unpack` copies raw disk order straight into `destination` —
        // vertical flipping is the caller's responsibility, signaled by
        // `needsVerticalFlip`, not something this method does on its own.
        // A 2x2 image with a distinct value per row makes an accidental
        // in-place flip here immediately visible.
        let unpacker = try UncompressedUnpacker(bitCount: 8)
        let raw = Data([10, 10, 20, 20]) // "bottom" row = 10,10; "top" row = 20,20 as stored
        let pixels = unpacker.unpack(raw: raw, width: 2, height: 2)
        #expect(pixels == [10, 10, 20, 20])
    }
}
