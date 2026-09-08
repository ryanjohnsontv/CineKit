import Foundation

/// Writes little-endian, fixed-width fields into a growing `Data` buffer —
/// the write-side mirror of `DataReader`.
///
/// `.cine` structs are declared with 1-byte packing and every multi-byte
/// field on the wire is little-endian regardless of host endianness (see
/// `DataReader`'s doc comment). `DataReader` makes that explicit on the read
/// side via `UInt32(littleEndian: rawLoadedBits)`; this is the same
/// convention run in reverse: `value.littleEndian` produces a same-typed
/// value whose in-memory byte representation (as read by `withUnsafeBytes`)
/// is the little-endian encoding, so appending those bytes is correct on
/// any host byte order, not just the little-endian machines this actually
/// runs on today.
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
