import Foundation

/// The 44-byte `CINEFILEHEADER` at the start of every `.cine` file.
///
/// `Sendable`: a plain immutable value type over primitive numeric fields —
/// Swift's automatic Sendable inference for structs doesn't extend to
/// `public` types (their conformances are part of the API surface, so the
/// language requires opting in explicitly rather than inferring it), so this
/// is declared explicitly for `CineFile` (which stores one) to be Sendable.
public struct CineFileHeader: Sendable {
    public static let byteSize = 44
    /// ASCII "CI", read (or written) as a little-endian UInt16. Not
    /// `private`: `CineFileWriter` (same module, different file) needs this
    /// exact constant to stamp a valid magic into freshly-written headers
    /// rather than duplicating the literal.
    static let magic: UInt16 = 0x4943

    public let headerSize: UInt16
    public let compression: UInt16
    public let version: UInt16
    public let firstMovieImage: Int32
    public let totalImageCount: UInt32
    public let firstImageNo: Int32
    public let imageCount: UInt32
    public let offImageHeader: Int
    public let offSetup: Int
    public let offImageOffsets: Int
    public let triggerTimeFractions: UInt32
    public let triggerTimeSeconds: UInt32

    init(data: Data) throws {
        guard data.count >= Self.byteSize else { throw CineError.fileTooSmall }
        let r = DataReader(data: data)

        let type = r.uint16(0)
        guard type == Self.magic else { throw CineError.invalidMagic(found: type) }

        headerSize = r.uint16(2)
        compression = r.uint16(4)
        version = r.uint16(6)
        firstMovieImage = r.int32(8)
        totalImageCount = r.uint32(12)
        firstImageNo = r.int32(16)
        imageCount = r.uint32(20)
        offImageHeader = Int(r.uint32(24))
        offSetup = Int(r.uint32(28))
        offImageOffsets = Int(r.uint32(32))
        triggerTimeFractions = r.uint32(36)
        triggerTimeSeconds = r.uint32(40)
    }
}
