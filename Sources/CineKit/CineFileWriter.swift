import Foundation

public extension CineFile {
    /// Writes a new, independently-openable `.cine` file to `url` containing
    /// only the frames in `range` (both bounds inclusive, 0-based — same
    /// indexing as `decodeFrame(at:)`). A purely structural trim: no pixel
    /// data is decoded, demosaiced, or re-encoded — see `CineFileWriter`'s
    /// doc comment for the on-disk layout and header-field semantics.
    ///
    /// Throws `CineError.invalidTrimRange` if `range` isn't fully contained
    /// in `0..<frameCount`, and `CineError.writeFailed` if the output file
    /// can't be written to `url`.
    func writeTrimmed(range: ClosedRange<Int>, to url: URL) throws {
        try CineFileWriter.writeTrimmed(from: self, range: range, to: url)
    }
}

/// Writes a trimmed copy of a `.cine` file: a contiguous frame range from an
/// already-open `CineFile`, laid out as a fresh, compact file —
/// `writeTrimmed(range:to:)` is the public entry point.
///
/// ```
/// [CINEFILEHEADER][BITMAPINFOHEADER][SETUP][tagged blocks][frame offset table][frame block 0]...[frame block N-1]
/// ```
///
/// `BITMAPINFOHEADER`/`SETUP` are copied verbatim — dimensions, compression,
/// and every calibration/black-level/frame-rate/CFA field stay valid for
/// any contiguous subset of the same clip. Each selected frame's raw
/// on-disk block is likewise copied verbatim into a position computed from
/// the cumulative size written so far; the frame offset table records
/// those new positions. Original byte offsets/gaps are not preserved —
/// this is a fresh, compact layout, not an in-place edit.
///
/// A tagged-block region between `SETUP` and the offset table (real sample
/// files carry per-frame TIME64/exposure arrays there, see `TaggedBlock`)
/// is trimmed by `TaggedBlockRegion.trimmed`, which slices every per-frame
/// array down to `range`'s records; a block shape it can't attribute to
/// frames is carried through unchanged rather than dropped.
///
/// ## `CINEFILEHEADER` field semantics
///
/// Verified against Vision Research's "Phantom Cine File Format" spec
/// (June 2011, §3.1/§3.4.2) and cross-checked against real sample files:
///
/// - **`TotalImageCount`** ("images recorded in camera memory") is the
///   *original full acquisition* size, independent of any one saved file's
///   `ImageCount` per §3.4.2 — confirmed by all 4 real samples sharing the
///   same `TotalImageCount` (4094) despite 4 different `ImageCount`s
///   (450/729/377/717). **Copied verbatim**: trimming doesn't change the
///   acquisition a file came from.
/// - **`FirstMovieImage`** ("first recorded image, relative to trigger") is
///   the trigger-relative number of that same acquisition's first buffered
///   frame — confirmed distinct from `FirstImageNo` by hex inspection (e.g.
///   "Noise on Complex Image.cine": `FirstMovieImage == -4093` but
///   `FirstImageNo == -2658`, since that file already saved a subset
///   starting partway in). **Copied verbatim**, same reasoning.
/// - **`FirstImageNo`** ("first image saved to this file, relative to
///   trigger") is the one field that legitimately changes: becomes
///   `source.firstImageNo + range.lowerBound`, so output frame 0 keeps the
///   correct trigger-relative number.
/// - **`ImageCount`** becomes `range.count`, the trimmed frame count.
/// - `TriggerTime` (same physical trigger event) and
///   `Type`/`Headersize`/`Compression`/`Version` (format/version markers)
///   are copied verbatim — untouched by a frame-range trim.
///
/// `OffImageHeader`/`OffSetup`/`OffImageOffsets` are recomputed for this
/// fresh layout.
enum CineFileWriter {
    static func writeTrimmed(from source: CineFile, range: ClosedRange<Int>, to url: URL) throws {
        guard range.lowerBound >= 0, range.upperBound < source.frameCount else {
            throw CineError.invalidTrimRange(range: range, frameCount: source.frameCount)
        }

        let frameCount = range.count
        let setupBytes = try source.rawSetupBytes()
        let bitmapBytes = try source.rawBitmapInfoBytes()
        let taggedBlockBytes = TaggedBlockRegion.trimmed(
            try source.rawTaggedBlockRegionBytes(),
            sourceFrameCount: source.frameCount,
            to: range
        )

        let offImageHeader = CineFileHeader.byteSize
        let offSetup = offImageHeader + BitmapInfoHeader.byteSize
        let offImageOffsets = offSetup + setupBytes.count + taggedBlockBytes.count
        let firstFrameBlockOffset = offImageOffsets + frameCount * MemoryLayout<Int64>.size

        // Read before the offset table is built, since the table needs
        // each block's size to lay out the cumulative offsets.
        let blocks = try (0..<frameCount).map { try source.rawFrameBlock(at: range.lowerBound + $0) }

        var newOffsets = [Int64](repeating: 0, count: frameCount)
        var cursor = firstFrameBlockOffset
        for i in 0..<frameCount {
            newOffsets[i] = Int64(cursor)
            cursor += blocks[i].count
        }
        let totalFileSize = cursor

        var writer = DataWriter()
        writer.appendUInt16(CineFileHeader.magic)
        writer.appendUInt16(source.header.headerSize)
        writer.appendUInt16(source.header.compression)
        writer.appendUInt16(source.header.version)
        writer.appendInt32(source.header.firstMovieImage)
        writer.appendUInt32(source.header.totalImageCount)
        writer.appendInt32(source.header.firstImageNo + Int32(range.lowerBound))
        writer.appendUInt32(UInt32(frameCount))
        writer.appendUInt32(UInt32(offImageHeader))
        writer.appendUInt32(UInt32(offSetup))
        writer.appendUInt32(UInt32(offImageOffsets))
        writer.appendUInt32(source.header.triggerTimeFractions)
        writer.appendUInt32(source.header.triggerTimeSeconds)
        assert(writer.data.count == CineFileHeader.byteSize)

        writer.append(bitmapBytes)
        writer.append(setupBytes)
        writer.append(taggedBlockBytes)
        for offset in newOffsets {
            writer.appendInt64(offset)
        }
        for block in blocks {
            writer.append(block)
        }
        assert(writer.data.count == totalFileSize)

        do {
            try writer.data.write(to: url, options: .atomic)
        } catch {
            throw CineError.writeFailed("\(error)")
        }
    }
}
