import Foundation

/// Writes little-endian, fixed-width fields into a growing `Data` buffer —
/// the write-side mirror of `DataReader`.
///
/// `.cine` structs use 1-byte packing and little-endian fields on the wire
/// regardless of host endianness (see `DataReader`). `value.littleEndian`
/// produces a same-typed value whose in-memory bytes (as read by
/// `withUnsafeBytes`) are the little-endian encoding, so appending them is
/// correct on any host byte order.
struct DataWriter {
    private(set) var data = Data()

    mutating func appendUInt16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendInt64(_ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Appends raw bytes verbatim, with no byte-order transformation —
    /// for copying already-on-disk regions (SETUP, BITMAPINFOHEADER, frame
    /// blocks) that must pass through unchanged.
    mutating func append(_ other: Data) {
        data.append(other)
    }
}
