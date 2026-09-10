import Foundation

/// `biCompression == 256`: Vision Research's "P10" 10-bit packed format —
/// every 5 bytes encode 4 pixels. Bit layout and vertical-flip behavior
/// confirmed by visually validating decoded frames against real samples (a
/// point-source light target produced a correct radially-symmetric bloom;
/// a natural scene read right-side-up only when NOT flipped).
///
/// P10 isn't a plain bit-truncation of the sensor's native 12-bit linear
/// reading — the spec documents a "compander-expander scheme": a
/// Rec.709-style gamma (2.2) curve compresses 12-bit linear into 10 bits
/// before storage (less shadow precision loss than plain truncation), and
/// "the inverse function should be applied at the linearization" via the
/// exact lookup table `P10Linearization` provides (spec Appendix 1). Every
/// value below is run through that table immediately after unpacking, so
/// output here is always genuinely linear-referred (`P12LUnpacker`/
/// `UncompressedUnpacker` need no such step; neither format compands).
/// Skipping it — as an earlier version did — leaves every downstream
/// linear operation (white balance, demosaic, color matrix) silently
/// running on gamma-encoded data; see `CineFile.effectiveBlackWhiteLevels`
/// for the other half of that fix (recorded `SETUP.BlackLevel`/
/// `WhiteLevel` need the same table to land in this domain).
struct P10Unpacker: PixelUnpacker {
    var needsVerticalFlip: Bool { false }

    func unpack(raw: UnsafeRawBufferPointer, width: Int, height: Int, into destination: UnsafeMutableBufferPointer<UInt16>) {
        let pixelCount = width * height
        var pixelIndex = 0
        var byteOffset = 0

        while pixelIndex + 4 <= pixelCount {
            let b0 = UInt16(raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt8.self))
            let b1 = UInt16(raw.loadUnaligned(fromByteOffset: byteOffset + 1, as: UInt8.self))
            let b2 = UInt16(raw.loadUnaligned(fromByteOffset: byteOffset + 2, as: UInt8.self))
            let b3 = UInt16(raw.loadUnaligned(fromByteOffset: byteOffset + 3, as: UInt8.self))
            let b4 = UInt16(raw.loadUnaligned(fromByteOffset: byteOffset + 4, as: UInt8.self))

            destination[pixelIndex]     = P10Linearization.linearize((b0 << 2) | (b1 >> 6))
            destination[pixelIndex + 1] = P10Linearization.linearize(((b1 & 0x3F) << 4) | (b2 >> 4))
            destination[pixelIndex + 2] = P10Linearization.linearize(((b2 & 0x0F) << 6) | (b3 >> 2))
            destination[pixelIndex + 3] = P10Linearization.linearize(((b3 & 0x03) << 8) | b4)

            pixelIndex += 4
            byteOffset += 5
        }
    }
}
