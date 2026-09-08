import Foundation

/// One TIME64 timestamp — the exact on-disk shape of
/// `CineFileHeader.triggerTimeFractions`/`triggerTimeSeconds`, and of each
/// record in a `Type == 1002` per-frame capture-time block (see
/// `TaggedBlock`'s doc comment): seconds since the Unix epoch, plus a
/// sub-second fraction expressed as a fraction of 2^32.
public struct CineTimestamp: Sendable, Equatable {
    public let seconds: UInt32
    public let fractions: UInt32

    public init(seconds: UInt32, fractions: UInt32) {
        self.seconds = seconds
        self.fractions = fractions
    }

    /// `seconds` + `fractions / 2^32`, as a `Date` — a convenience
    /// interpretation; `seconds`/`fractions` above are the authoritative
    /// on-disk values.
    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(fractions) / TimeInterval(UInt32.max))
    }
}

extension CineFile {
    /// Per-frame capture timestamps, parsed from the file's tagged-block
    /// region (the `Type == 1002` TIME64 array — see `TaggedBlock`'s doc
    /// comment for the confirmed on-disk shape and the real-sample evidence
    /// behind it). `nil` if this file has no such block, or if its payload
    /// doesn't divide evenly into exactly `frameCount` 8-byte records (the
    /// same "don't guess at a shape we don't recognize" standard
    /// `TaggedBlockRegion` itself already applies).
    ///
    /// When non-`nil`, frame-index-aligned with `decodeFrame(at:)` — same
    /// 0-based indexing, one entry per frame.
    public func frameCaptureTimes() throws -> [CineTimestamp]? {
        try perFrameTaggedRecords(type: 1002, recordSize: 8) { record in
            let reader = DataReader(data: record)
            // Fractions first, then seconds — the same field order as
            // `CineFileHeader.triggerTimeFractions`/`triggerTimeSeconds`.
            return CineTimestamp(seconds: reader.uint32(4), fractions: reader.uint32(0))
        }
    }

    /// Per-frame exposure duration, in nanoseconds — the `Type == 1003`
    /// array (see `TaggedBlock`'s doc comment). `nil` under the same
    /// conditions as `frameCaptureTimes()` above.
    ///
    /// When non-`nil`, frame-index-aligned with `decodeFrame(at:)`.
    public func frameExposureNanoseconds() throws -> [UInt32]? {
        try perFrameTaggedRecords(type: 1003, recordSize: 4) { record in
            DataReader(data: record).uint32(0)
        }
    }

    /// Shared lookup behind `frameCaptureTimes()`/`frameExposureNanoseconds()`
    /// above: finds the first tagged block of `type` in this file's tagged-
    /// block region, confirms its payload is exactly `frameCount` records of
    /// `recordSize` bytes each, and decodes every record with `decode`.
    /// Returns `nil` (never throws for "not found"/"wrong shape") whenever
    /// this file simply doesn't have that data — only a real I/O failure
    /// reading the region itself throws.
    private func perFrameTaggedRecords<T>(
        type: UInt16,
        recordSize: Int,
        decode: (Data) -> T
    ) throws -> [T]? {
        let regionBytes = try rawTaggedBlockRegionBytes()
        guard !regionBytes.isEmpty else { return nil }
        let (blocks, _) = TaggedBlockRegion.parse(regionBytes)
        guard let block = blocks.first(where: { $0.type == type }) else { return nil }
        guard block.payload.count == recordSize * frameCount else { return nil }
        return stride(from: 0, to: block.payload.count, by: recordSize).map { offset in
            decode(block.payload.subdata(in: offset..<(offset + recordSize)))
        }
    }
}
