import Foundation

/// `biCompression == 1024`: Vision Research's "P12L" 12-bit packed format —
/// every 3 bytes encode 2 pixels. Bit layout ported from a working
/// open-source reference implementation; unlike P10, this path has **not**
/// yet been exercised against a real `.cine` file (none of our 4 samples
/// use it) — treat as unverified until tested against real P12L data.
struct P12LUnpacker: PixelUnpacker {
    var needsVerticalFlip: Bool { false }

    func unpack(raw: UnsafeRawBufferPointer, width: Int, height: Int, into destination: UnsafeMutableBufferPointer<UInt16>) {
        let pixelCount = width * height
        var pixelIndex = 0
        var byteOffset = 0

        while pixelIndex + 2 <= pixelCount {
            let b0 = UInt16(raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt8.self))
            let b1 = UInt16(raw.loadUnaligned(fromByteOffset: byteOffset + 1, as: UInt8.self))
            let b2 = UInt16(raw.loadUnaligned(fromByteOffset: byteOffset + 2, as: UInt8.self))

            destination[pixelIndex]     = (b0 << 4) | (b1 >> 4)
            destination[pixelIndex + 1] = ((b1 & 0x0F) << 8) | b2

            pixelIndex += 2
            byteOffset += 3
        }
    }
}
