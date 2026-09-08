import Foundation

/// The `ImageCount`-element array of absolute file offsets (one per frame),
/// located at `CineFileHeader.offImageOffsets`.
struct FrameOffsetTable {
    private let offsets: [Int64]

    init(store: FileBackingStore, header: CineFileHeader) throws {
        let count = Int(header.imageCount)
        let byteCount = count * MemoryLayout<Int64>.size
        let data = try store.read(at: header.offImageOffsets, count: byteCount)
        let reader = DataReader(data: data)
        var values = [Int64](repeating: 0, count: count)
        for i in 0..<count {
            values[i] = reader.int64(i * MemoryLayout<Int64>.size)
        }
        self.offsets = values
    }

    var count: Int { offsets.count }

    subscript(frameIndex: Int) -> Int64 {
        offsets[frameIndex]
    }
}
