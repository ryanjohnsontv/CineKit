import Testing
import Foundation
@testable import CineKit

/// Synthetic, hand-built byte vectors, same style as
/// `UncompressedUnpackerTests` — not gated behind `TestFixtures
/// .samplesAvailable`, since these exercise the bit-unpacking/
/// linearization math directly rather than needing a real file.
struct P10UnpackerTests {
    @Test func needsVerticalFlipIsFalse() {
        // Confirmed empirically for P10 frames — see
        // `PixelUnpacker.needsVerticalFlip`'s own doc comment.
        #expect(P10Unpacker().needsVerticalFlip == false)
    }

    /// 5 bytes chosen (by hand, working backward from the bit-packing
    /// formula) so the 4 packed 10-bit codes are exactly 0, 64, 511, and
    /// 1023 (the all-ones maximum) — deliberately spanning the table's
    /// bottom, its documented black-point fixed point, a mid-range value,
    /// and its saturating top, rather than 4 arbitrary codes.
    @Test func unpackAppliesLinearizationNotJustBitUnpacking() {
        let unpacker = P10Unpacker()
        let raw = Data([0x00, 0x04, 0x07, 0xFF, 0xFF])
        let pixels = unpacker.unpack(raw: raw, width: 4, height: 1)
        // If this ever regressed to plain bit-unpacking with no
        // linearization, these would read back as the raw codes themselves
        // (0, 64, 511, 1023) instead.
        #expect(pixels == [
            P10Linearization.lut[0],
            P10Linearization.lut[64],
            P10Linearization.lut[511],
            P10Linearization.lut[1023],
        ])
        #expect(pixels == [2, 64, 994, 4095])
    }

    /// `P10Linearization.lut[64] == 64` and `lut[1014] == 4064` are the
    /// spec's own stated fixed points ("Black level is at 64 and white
    /// level at 1014 in the 10 bits packed representation. In the 12 bits
    /// representation the levels are 64 and 4064.") — pin them directly, so
    /// a transcription error in the 1024-entry table would be caught even
    /// without a real sample file.
    @Test func linearizationTableMatchesDocumentedFixedPoints() {
        #expect(P10Linearization.lut.count == 1024)
        #expect(P10Linearization.lut[64] == 64)
        #expect(P10Linearization.lut[1014] == 4064)
        #expect(P10Linearization.lut[1023] == 4095)
    }

    @Test func linearizeClampsOutOfRangeCodesRatherThanCrashing() {
        // Geometrically impossible from 4 real 10-bit-packed pixels (the
        // unpacking formula can never produce more than 10 bits), but
        // costs nothing to guard defensively — see `linearize`'s own doc
        // comment.
        #expect(P10Linearization.linearize(1023) == P10Linearization.lut[1023])
        #expect(P10Linearization.linearize(UInt16.max) == P10Linearization.lut[1023])
    }

    @Test func unpacksMultipleGroupsOfFourPixels() {
        // Two back-to-back 5-byte groups (8 pixels), all-zero bytes in the
        // second group — confirms the byteOffset/pixelIndex stride (5
        // bytes -> 4 pixels) advances correctly across more than one group,
        // not just within the first.
        let unpacker = P10Unpacker()
        let raw = Data([0x00, 0x04, 0x07, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00])
        let pixels = unpacker.unpack(raw: raw, width: 8, height: 1)
        #expect(pixels == [2, 64, 994, 4095, 2, 2, 2, 2])
    }
}
