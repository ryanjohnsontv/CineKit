import Foundation

/// One tagged block from the region between the end of `SETUP` and the
/// frame offset table (`CINEFILEHEADER.OffImageOffsets`).
///
/// Confirmed present, via direct byte-level inspection independent of any
/// parsed field, in every one of the 4 real sample files this package is
/// tested against — immediately after `SETUP`, as exactly two back-to-back
/// blocks: a `Type == 1002` array of one 8-byte `TIME64` record (fractions
/// + seconds, same shape and field order as
/// `CineFileHeader.triggerTimeFractions`/`triggerTimeSeconds` — confirmed
/// by comparing the raw bytes of each file's own records against its own
/// header's `TriggerTime`) per frame — the per-frame image capture time —
/// followed by a `Type == 1003` array of one 4-byte value per frame — the
/// per-frame exposure, in nanoseconds. In all 4 files both arrays' byte
/// counts divide their file's `ImageCount` exactly (stride 8 and 4
/// respectively, with zero remainder), the block boundaries sum exactly to
/// the gap between `SETUP`'s end and `OffImageOffsets`, and the TIME64
/// fractions field increases monotonically frame-over-frame while its
/// seconds field only ever sits AT OR BEFORE the header's own `TriggerTime`
/// (consistent with each of these 4 files being a pre-trigger buffer that
/// ends at, not after, the trigger event) — by a gap that varies per file,
/// from about 1 second up to about 13 seconds across these 4 samples, not
/// a fixed or tight bound. All of this is consistent with a plain per-frame
/// array indexed 0-based in the same frame order as
/// `FrameOffsetTable`/`decodeFrame(at:)`.
///
/// `TaggedBlockRegion` below acts only on this struct's generic shape (a
/// self-describing `Size`/`Type`/`Reserved` header plus payload, and —
/// separately — whether a given block's payload happens to divide evenly
/// into equal-size per-frame records), not on the two specific type codes
/// documented above; any other per-frame-array tag block a future
/// camera/SDK version adds would be trimmed the same way automatically.
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
    /// Parses `bytes` as a sequence of tagged blocks (`Size: UInt32` —
    /// this block's total length, header included — followed by `Type:
    /// UInt16`, `Reserved: UInt16`, then `Size - 8` bytes of payload), back
    /// to back with no padding between.
    ///
    /// Stops the moment a block's 8-byte header doesn't fully fit in what's
    /// left, or a block declares a `Size` that would overrun the remaining
    /// bytes — some layout this doesn't recognize — rather than guessing at
    /// it. Everything from that point to the end of `bytes` is returned as
    /// `trailing`, untouched, so a caller that only ever round-trips
    /// `blocks` + `trailing` back through `serialize` never drops a byte it
    /// didn't understand, even for a hypothetical file this parser gets
    /// wrong.
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

    /// Returns `bytes` (the raw tagged-block region from a source file with
    /// `sourceFrameCount` total frames) re-laid-out for a trim to `range`:
    /// every block whose payload divides evenly into `sourceFrameCount`
    /// equal-size records — i.e. every block this file's real-sample
    /// evidence says is a plain per-frame array, see `TaggedBlock`'s doc
    /// comment — is sliced down to just the records for `range`, the same
    /// selected-frames subset `CineFileWriter` copies pixel blocks for.
    ///
    /// Any block whose payload *doesn't* divide evenly — not a shape this
    /// function can attribute to frames at all — is passed through
    /// unchanged, verbatim, rather than guessed at; likewise `trailing`
    /// (bytes `parse` couldn't make sense of as blocks in the first place).
    /// Both cases are a deliberate lossless fallback for a layout this
    /// function doesn't recognize, not an expected outcome: every real
    /// sample file this package is tested against parses as exactly two
    /// evenly-dividing blocks and empty trailing bytes, so both fallbacks
    /// are unexercised on real data today.
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
