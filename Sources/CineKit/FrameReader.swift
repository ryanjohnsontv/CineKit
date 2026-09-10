import Foundation

/// A single frame's data straight off disk, before any pixel unpacking.
struct RawFrame {
    let annotation: Data
    let pixelData: Data
}

/// Reads the per-frame block found at each entry of `FrameOffsetTable`:
///
/// ```
/// u32 AnnotationSize      // total size of this header block, >= 8
/// u8[AnnotationSize - 8]  // annotation payload (commonly empty)
/// u32 ImageSize           // size of the pixel data that follows
/// u8[ImageSize]           // raw pixel data
/// ```
///
/// `AnnotationSize` covers the field itself, the annotation payload, AND
/// the trailing `ImageSize` field — the pixel data starts exactly
/// `AnnotationSize` bytes after the frame's base offset. Easy to get
/// wrong: an earlier version assumed `ImageSize` immediately followed
/// `AnnotationSize`, which only happens to work when `AnnotationSize == 8`.
struct FrameReader {
    let store: FileBackingStore

    func readRawFrame(at absoluteOffset: Int64) throws -> RawFrame {
        let base = Int(absoluteOffset)
        let sizeFieldData = try store.read(at: base, count: 4)
        let annotationSize = Int(DataReader(data: sizeFieldData).uint32(0))
        guard annotationSize >= 8 else {
            throw CineError.corruptFrame(index: -1, reason: "AnnotationSize \(annotationSize) < 8")
        }

        let annotationPayloadSize = annotationSize - 8
        let annotation = annotationPayloadSize > 0
            ? try store.read(at: base + 4, count: annotationPayloadSize)
            : Data()

        let imageSizeFieldOffset = base + 4 + annotationPayloadSize
        let imageSizeFieldData = try store.read(at: imageSizeFieldOffset, count: 4)
        let imageSize = Int(DataReader(data: imageSizeFieldData).uint32(0))

        let pixelData = try store.read(at: imageSizeFieldOffset + 4, count: imageSize)
        return RawFrame(annotation: annotation, pixelData: pixelData)
    }
}
