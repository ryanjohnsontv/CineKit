import Foundation

/// Converts a frame's raw on-disk bytes into `width*height` raw sensor
/// values (one `UInt16` per pixel, no demosaicing, no tone-mapping — those
/// happen later, in the rendering layer, so exposure/LUT adjustments never
/// require re-decoding a frame).
///
/// `Sendable`: every conformer (`P10Unpacker`, `P12LUnpacker`,
/// `UncompressedUnpacker`) is a stateless or immutable-after-init struct, and
/// `CineFile` needs its `unpacker` property to cross actor boundaries under
/// Swift 6 strict concurrency (see `FileBackingStore`'s doc comment for the
/// same reasoning applied there).
public protocol PixelUnpacker: Sendable {
    /// Whether rows are stored bottom-up on disk (like a Windows DIB) and
    /// need a vertical flip to display right-side-up. Confirmed empirically:
    /// true for uncompressed frames, false for both packed formats.
    var needsVerticalFlip: Bool { get }

    func unpack(raw: UnsafeRawBufferPointer, width: Int, height: Int, into destination: UnsafeMutableBufferPointer<UInt16>)
}

extension PixelUnpacker {
    /// Convenience wrapper for tests and other non-performance-critical call
    /// sites. The playback/render path should call `unpack(raw:width:height:into:)`
    /// directly against a reused buffer instead of allocating a fresh array
    /// per frame.
    func unpack(raw: Data, width: Int, height: Int) -> [UInt16] {
        var destination = [UInt16](repeating: 0, count: width * height)
        raw.withUnsafeBytes { rawBuffer in
            destination.withUnsafeMutableBufferPointer { destBuffer in
                unpack(raw: rawBuffer, width: width, height: height, into: destBuffer)
            }
        }
        return destination
    }
}

enum PixelUnpackerFactory {
    static func make(compression: BitmapCompression, bitCount: UInt16) throws -> PixelUnpacker {
        switch compression {
        case .uncompressed:
            return try UncompressedUnpacker(bitCount: bitCount)
        case .p10Packed:
            return P10Unpacker()
        case .p12LPacked:
            return P12LUnpacker()
        case .unknown(let code):
            throw CineError.unsupportedCompression(code)
        }
    }
}
