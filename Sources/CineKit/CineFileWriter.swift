import Foundation

public extension CineFile {
    /// Writes a new, independently-openable `.cine` file to `url` containing
    /// only the frames in `range` (both bounds inclusive, 0-based — the same
    /// indexing as `decodeFrame(at:)`, independent of `header.firstImageNo`).
    ///
    /// This is a purely structural trim: no pixel data is decoded,
    /// demosaiced, or re-encoded. See `CineFileWriter`'s doc comment for the
    /// exact on-disk layout this produces and the header-field semantics
    /// chosen for `TotalImageCount`/`FirstMovieImage`/`FirstImageNo`.
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
/// `writeTrimmed(range:to:)` is the public entry point; see that doc comment
/// for the caller-facing contract.
///
/// ```
/// [CINEFILEHEADER][BITMAPINFOHEADER][SETUP][tagged blocks][frame offset table][frame block 0]...[frame block N-1]
/// ```
///
/// `BITMAPINFOHEADER` and `SETUP` are copied verbatim, byte-for-byte, from
/// the source — dimensions/compression/bit-depth and every
/// calibration/black-level/frame-rate/CFA field remain valid for any
/// contiguous subset of the same clip's frames, nothing in either needs to
/// change. Each selected frame's raw on-disk block bytes (`AnnotationSize`
/// field through the end of its `ImageSize`-declared pixel data — see
/// `FrameReader`'s doc comment) are likewise copied verbatim into fresh
/// positions computed from the cumulative size of the blocks written so
/// far; the frame offset table records those new absolute positions. This
/// file intentionally does not preserve the source's original byte offsets
/// or gaps — it's a fresh, compact layout.
///
/// Between `SETUP` and the frame offset table, the source may have a
/// tagged-block region — real sample files carry per-frame TIME64
/// (capture-time) and exposure arrays there; see `TaggedBlock`'s doc
/// comment for the confirmed on-disk shape. `TaggedBlockRegion.trimmed`
/// slices every per-frame array it finds down to just `range`'s records,
/// the same frame subset selected for pixel blocks, and the result is
/// written here verbatim; any block shape it can't attribute to frames is
/// instead carried through unchanged (see that type's doc comment for why
/// that's a deliberate lossless fallback, not data loss).
///
/// ## `CINEFILEHEADER` field semantics
///
/// Verified against Vision Research's own "Phantom Cine File Format" spec
/// (June 2011 edition — section 3.1's field descriptions plus section
/// 3.4.2's tagged-block note), not assumed — and cross-checked against the
/// real sample files' actual on-disk values:
///
/// - **`TotalImageCount`** — "Total count of images, recorded in the camera
///   memory": the size of the *original full acquisition*, not of any
///   individual saved file. Section 3.4.2 spells out the independence from
///   `ImageCount` explicitly (an image-time tagged block's item count "is
///   TotalImageCount (even if you saved only a smaller range of images:
///   ImageCount)"). All 4 real sample files confirm this in practice: each
///   has a different `ImageCount` (450/729/377/717) but the *same*
///   `TotalImageCount` (4094) — all four were saved out of a same-sized
///   camera memory buffer. **Copied verbatim** from the source: trimming an
///   already-saved file doesn't change the acquisition it came from.
/// - **`FirstMovieImage`** — "First recorded image number, relative to
///   trigger": the trigger-relative number of the *first frame the camera
///   ever buffered* in that same original acquisition, analogous to
///   `TotalImageCount`. Confirmed distinct from `FirstImageNo` in real
///   samples by direct hex inspection (e.g. "Noise on Complex Image.cine"
///   has `FirstMovieImage == -4093` but `FirstImageNo == -2658` — that file
///   already saved a subset starting partway into the acquisition, so the
///   two fields diverge exactly as the spec's distinct definitions predict).
///   **Copied verbatim** from the source for the same reason as
///   `TotalImageCount`.
/// - **`FirstImageNo`** — "First image saved to this file, relative to
///   trigger": this is the one field that legitimately changes. It becomes
///   `source.firstImageNo + range.lowerBound`, so the output file's frame 0
///   (== source frame `range.lowerBound`) keeps the correct trigger-relative
///   frame number instead of being reset to 0 or left pointing at the
///   source's original starting frame.
/// - **`ImageCount`** — "Count of images saved to this file": becomes
///   `range.count`, the trimmed frame count.
/// - `TriggerTime` is copied verbatim (same physical trigger event; a trim
///   doesn't change when the camera was triggered).
/// - `Type`/`Headersize`/`Compression`/`Version` are copied verbatim — pure
///   format/version markers, unaffected by a frame-range trim.
///
/// `OffImageHeader`/`OffSetup`/`OffImageOffsets` are recomputed to point at
/// their new positions in this fresh layout.
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

        // Every selected frame's raw on-disk block, verbatim, in source
        // order — read before the offset table is built, since the table
        // needs each block's size to lay out the cumulative offsets.
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
