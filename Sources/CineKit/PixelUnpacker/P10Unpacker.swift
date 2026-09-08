import Foundation

/// `biCompression == 256`: Vision Research's "P10" 10-bit packed format —
/// every 5 bytes encode 4 pixels. Bit layout and vertical-flip behavior were
/// confirmed by visually validating decoded frames against real sample
/// files (a point-source-light target produced a correct radially-symmetric
/// bloom; a natural scene rendered right-side-up with readable text only
/// when NOT flipped).
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

            destination[pixelIndex]     = (b0 << 2) | (b1 >> 6)
            destination[pixelIndex + 1] = ((b1 & 0x3F) << 4) | (b2 >> 4)
            destination[pixelIndex + 2] = ((b2 & 0x0F) << 6) | (b3 >> 2)
            destination[pixelIndex + 3] = ((b3 & 0x03) << 8) | b4

            pixelIndex += 4
            byteOffset += 5
        }
    }
}
