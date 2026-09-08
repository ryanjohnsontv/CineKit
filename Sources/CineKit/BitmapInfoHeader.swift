import Foundation

/// How pixel data is packed for a given `biCompression` value. `.cine` only
/// ever uses BI_RGB (uncompressed) or one of Vision Research's packed-bit
/// variants — never a "real" video codec.
public enum BitmapCompression: Equatable, Sendable {
    case uncompressed
    case p10Packed
    case p12LPacked
    case unknown(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .uncompressed
        case 256: self = .p10Packed
        case 1024: self = .p12LPacked
        default: self = .unknown(rawValue)
        }
    }
}

/// The 40-byte standard Windows `BITMAPINFOHEADER` found at `CineFileHeader.offImageHeader`.
///
/// `Sendable`: same reasoning as `CineFileHeader` — an immutable value type
/// over Sendable fields, explicitly annotated because `public` types don't
/// get Sendable inferred automatically.
public struct BitmapInfoHeader: Sendable {
    public static let byteSize = 40

    public let biSize: UInt32
    public let width: Int
    public let height: Int
    public let planes: UInt16
    public let bitCount: UInt16
    public let compression: BitmapCompression
    public let sizeImage: Int
    public let xPelsPerMeter: Int32
    public let yPelsPerMeter: Int32
    public let clrUsed: UInt32
    public let clrImportant: UInt32

    init(data: Data) throws {
        guard data.count >= Self.byteSize else { throw CineError.fileTooSmall }
        let r = DataReader(data: data)

        biSize = r.uint32(0)
        width = Int(r.int32(4))
        height = Int(r.int32(8))
        planes = r.uint16(12)
        bitCount = r.uint16(14)
        compression = BitmapCompression(rawValue: r.uint32(16))
        sizeImage = Int(r.uint32(20))
        xPelsPerMeter = r.int32(24)
        yPelsPerMeter = r.int32(28)
        clrUsed = r.uint32(32)
        clrImportant = r.uint32(36)
    }
}
