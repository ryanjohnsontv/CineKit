import Foundation

/// Reads little-endian, unaligned fixed-width fields out of a `Data` buffer.
///
/// `.cine` structs are declared with 1-byte packing on the wire, so field
/// offsets never land on their natural alignment — every read here must be
/// unaligned, and every multi-byte field must be explicitly byte-swapped
/// from little-endian regardless of host endianness.
struct DataReader {
    let data: Data

    func uint8(_ offset: Int) -> UInt8 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self) }
    }

    func uint16(_ offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func int16(_ offset: Int) -> Int16 {
        data.withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self)) }
    }

    func uint32(_ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func int32(_ offset: Int) -> Int32 {
        data.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int32.self)) }
    }

    func uint64(_ offset: Int) -> UInt64 {
        data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }

    func int64(_ offset: Int) -> Int64 {
        data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int64.self)) }
    }

    func float32(_ offset: Int) -> Float {
        Float(bitPattern: uint32(offset))
    }

    func float64(_ offset: Int) -> Double {
        Double(bitPattern: uint64(offset))
    }

    /// Reads up to `maxLength` bytes starting at `offset` and decodes them as a
    /// NUL-terminated (or maxLength-bounded) ASCII/UTF-8 string.
    func fixedString(_ offset: Int, maxLength: Int) -> String {
        let bytes = data.withUnsafeBytes { raw -> [UInt8] in
            let slice = raw.loadUnalignedBytes(fromByteOffset: offset, count: maxLength)
            if let nulIndex = slice.firstIndex(of: 0) {
                return Array(slice[0..<nulIndex])
            }
            return slice
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension UnsafeRawBufferPointer {
    fileprivate func loadUnalignedBytes(fromByteOffset offset: Int, count: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = loadUnaligned(fromByteOffset: offset + i, as: UInt8.self)
        }
        return result
    }
}
