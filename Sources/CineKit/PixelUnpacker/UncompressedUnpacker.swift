import Foundation

/// `biCompression == 0`: pixels stored directly as 8-bit or 16-bit samples.
/// Rows are stored bottom-up, like a Windows DIB.
struct UncompressedUnpacker: PixelUnpacker {
    let bitCount: UInt16
    var needsVerticalFlip: Bool { true }

    init(bitCount: UInt16) throws {
        guard bitCount == 8 || bitCount == 16 else {
            throw CineError.unsupportedBitCount(bitCount)
        }
        self.bitCount = bitCount
    }

    func unpack(raw: UnsafeRawBufferPointer, width: Int, height: Int, into destination: UnsafeMutableBufferPointer<UInt16>) {
        let pixelCount = width * height
        switch bitCount {
        case 16:
            for i in 0..<pixelCount {
                destination[i] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            }
        case 8:
            for i in 0..<pixelCount {
                destination[i] = UInt16(raw.loadUnaligned(fromByteOffset: i, as: UInt8.self))
            }
        default:
            // Unreachable: `init` already validated bitCount.
            break
        }
    }
}
