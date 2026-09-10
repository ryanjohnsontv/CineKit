import Foundation

/// One tagged block from the region between the end of `SETUP` and the
/// frame offset table (`CINEFILEHEADER.OffImageOffsets`).
///
/// Confirmed via byte-level inspection in all 4 real sample files: two
/// back-to-back blocks right after `SETUP` — `Type == 1002`, an 8-byte
/// `TIME64` (fractions + seconds) per-frame capture time, then
/// `Type == 1003`, a 4-byte per-frame exposure value in nanoseconds. In all
/// 4 files both arrays' byte counts divide `ImageCount` exactly, block
/// boundaries sum to the `SETUP`-to-`OffImageOffsets` gap, TIME64 fractions
/// increase monotonically, and seconds stays at/before `TriggerTime`
/// (consistent with a pre-trigger buffer ending at the trigger, by a gap of
/// ~1-13s across samples) — all consistent with a plain per-frame array
/// indexed 0-based like `FrameOffsetTable`/`decodeFrame(at:)`.
///
/// `TaggedBlockRegion` below acts only on this struct's generic shape (a
/// self-describing header plus payload that may or may not divide evenly
/// into per-frame records), not on the two specific type codes above, so
/// any future per-frame-array tag block trims the same way automatically.
struct TaggedBlock {
    var type: UInt16
    var reserved: UInt16
    var payload: Data

    /// This block's total on-disk length, header included.
    var totalByteSize: Int { 8 + payload.count }
}

/// Parses, trims, and rebuilds the tagged-block region that sits between
/// `SETUP` and the frame offset table in a `.cine` file — see `TaggedBlock`
/// for what's actually been confirmed to live there in real files.
enum TaggedBlockRegion {
    /// Parses `bytes` as a sequence of tagged blocks (`Size: UInt32` — total
    /// length, header included — followed by `Type: UInt16`, `Reserved:
    /// UInt16`, then `Size - 8` bytes of payload), back to back with no
    /// padding.
    ///
    /// Stops the moment a block's 8-byte header doesn't fully fit in what's
    /// left, or a `Size` would overrun the remaining bytes — rather than
    /// guessing at an unrecognized layout. Everything from that point on is
    /// returned as `trailing`, untouched, so round-tripping `blocks` +
    /// `trailing` through `serialize` never drops a byte, even for a file
    /// this parser gets wrong.
    static func parse(_ bytes: Data) -> (blocks: [TaggedBlock], trailing: Data) {
        let reader = DataReader(data: bytes)
        var blocks: [TaggedBlock] = []
        var pos = 0
        while pos <= bytes.count - 8 {
            let size = Int(reader.uint32(pos))
            guard size >= 8, pos + size <= bytes.count else { break }
            let type = reader.uint16(pos + 4)
            let reserved = reader.uint16(pos + 6)
            let payload = bytes.subdata(in: (pos + 8)..<(pos + size))
            blocks.append(TaggedBlock(type: type, reserved: reserved, payload: payload))
            pos += size
        }
        let trailing = bytes.subdata(in: pos..<bytes.count)
        return (blocks, trailing)
    }

    /// Rebuilds the exact on-disk bytes for `blocks` followed by
    /// `trailing` — the inverse of `parse`.
    static func serialize(blocks: [TaggedBlock], trailing: Data) -> Data {
        var writer = DataWriter()
        for block in blocks {
            writer.appendUInt32(UInt32(block.totalByteSize))
            writer.appendUInt16(block.type)
            writer.appendUInt16(block.reserved)
            writer.append(block.payload)
        }
        writer.append(trailing)
        return writer.data
    }

    /// Returns `bytes` (the tagged-block region from a source file with
    /// `sourceFrameCount` total frames) re-laid-out for a trim to `range`:
    /// every block whose payload divides evenly into `sourceFrameCount`
    /// equal-size records (a plain per-frame array, see `TaggedBlock`) is
    /// sliced down to just `range`'s records, the same subset
    /// `CineFileWriter` copies pixel blocks for.
    ///
    /// A block that doesn't divide evenly, or `trailing` bytes `parse`
    /// couldn't attribute to blocks, pass through unchanged — a deliberate
    /// lossless fallback for an unrecognized layout, not an expected
    /// outcome: every real sample file tested parses as exactly two
    /// evenly-dividing blocks with empty trailing bytes, so this path is
    /// unexercised on real data today.
    static func trimmed(_ bytes: Data, sourceFrameCount: Int, to range: ClosedRange<Int>) -> Data {
        guard sourceFrameCount > 0, !bytes.isEmpty else { return bytes }
        let (blocks, trailing) = parse(bytes)
        let trimmedBlocks = blocks.map { block -> TaggedBlock in
            guard block.payload.count % sourceFrameCount == 0 else { return block }
            let stride = block.payload.count / sourceFrameCount
            guard stride > 0 else { return block }
            let start = range.lowerBound * stride
            let end = (range.upperBound + 1) * stride
            var trimmedBlock = block
            trimmedBlock.payload = block.payload.subdata(in: start..<end)
            return trimmedBlock
        }
        return serialize(blocks: trimmedBlocks, trailing: trailing)
    }
}
