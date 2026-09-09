import Foundation

/// `biCompression == 256`: Vision Research's "P10" 10-bit packed format —
/// every 5 bytes encode 4 pixels. Bit layout and vertical-flip behavior were
/// confirmed by visually validating decoded frames against real sample
/// files (a point-source-light target produced a correct radially-symmetric
/// bloom; a natural scene rendered right-side-up with readable text only
/// when NOT flipped).
///
/// P10 isn't a plain bit-truncation of the sensor's native 12-bit linear
/// reading down to 10 bits — Vision Research's own format spec documents a
/// "compander-expander scheme" applied first: a Rec.709-style gamma
/// (gamma=2.2) curve compresses the 12-bit linear value into 10 bits
/// (trading dynamic range for less quantization noise in the *stored*
/// value, since a plain linear truncation would concentrate all its lost
/// precision in the shadows), and "the inverse function should be applied
/// at the linearization" — via the exact lookup table `P10Linearization`
/// provides (the spec's own Appendix 1). Every value below is therefore run
/// through that table immediately after unpacking, so this unpacker's
/// output is always genuinely linear-referred (still in raw sensor units,
/// just no longer gamma-companded), matching what `PixelUnpacker`'s own
/// doc comment promises and what `P12LUnpacker`/`UncompressedUnpacker`
/// already provide without needing this extra step (neither of those
/// formats compands). Skipping this step (as an earlier version of this
/// unpacker did) leaves every downstream linear operation — white balance,
/// demosaic, color matrix — running on gamma-encoded rather than linear
/// data, silently confusing two different domains as if they were one; see
/// `CineFile.effectiveBlackWhiteLevels` for the other half of this fix
/// (the file's own recorded `SETUP.BlackLevel`/`WhiteLevel` are themselves
/// recorded in the pre-linearization packed domain and need the same
/// table applied to land in the domain this unpacker's output is now in).
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
