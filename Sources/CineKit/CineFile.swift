import Foundation

/// Top-level entry point: opens a `.cine` file and exposes its parsed
/// headers plus per-frame decoding.
///
/// `Sendable`: this is a checked (not `@unchecked`) conformance — `CineFile`
/// is `final`, and every stored property is `let`-bound to a type that is
/// itself Sendable (`CineFileHeader`/`BitmapInfoHeader`/`CineSetup`/
/// `FrameOffsetTable`/`FrameReader` are plain immutable structs; `store` and
/// `unpacker` are existentials over `FileBackingStore`/`PixelUnpacker`,
/// both of which now require `Sendable` of their conformers). Nothing here
/// is mutated after `init` returns, so sharing one `CineFile` across actors
/// (e.g. handing it into an actor-isolated frame cache) is genuinely safe,
/// and the compiler can verify that itself.
public final class CineFile: Sendable {
    public let header: CineFileHeader
    public let bitmapInfo: BitmapInfoHeader
    public let setup: CineSetup
    public let frameCount: Int

    private let store: FileBackingStore
    private let offsetTable: FrameOffsetTable
    private let frameReader: FrameReader
    private let unpacker: PixelUnpacker

    public convenience init(url: URL) throws {
        try self.init(store: MappedFileBackingStore(url: url))
    }

    /// The general entry point behind `init(url:)` above — takes any
    /// `FileBackingStore` conformer, not just the memory-mapped default, so
    /// a consumer can plug in their own (e.g. a buffered/chunked store for
    /// files on a network volume; see `FileBackingStore`'s own doc comment).
    public init(store: FileBackingStore) throws {
        let headerData = try store.read(at: 0, count: CineFileHeader.byteSize)
        let header = try CineFileHeader(data: headerData)

        let bitmapData = try store.read(at: header.offImageHeader, count: BitmapInfoHeader.byteSize)
        let bitmapInfo = try BitmapInfoHeader(data: bitmapData)

        let setupReadSize = min(SetupFieldLayout.maxKnownSize, store.count - header.offSetup)
        let setupData = try store.read(at: header.offSetup, count: max(0, setupReadSize))
        let setup = CineSetup(data: setupData)

        self.header = header
        self.bitmapInfo = bitmapInfo
        self.setup = setup
        self.frameCount = Int(header.imageCount)
        self.store = store
        self.offsetTable = try FrameOffsetTable(store: store, header: header)
        self.frameReader = FrameReader(store: store)
        self.unpacker = try PixelUnpackerFactory.make(compression: bitmapInfo.compression, bitCount: bitmapInfo.bitCount)
    }

    /// Whether the consumer must vertically flip decoded frames from this
    /// file before display.
    public var needsVerticalFlip: Bool { unpacker.needsVerticalFlip }

    /// `setup.effectiveBlackWhiteLevels`, re-expressed in whatever domain
    /// `decodeFrame(at:)`'s own pixel output is actually in — the version
    /// to use for tone-mapping real decoded pixels, as opposed to `setup`'s
    /// own property, which is only ever "what SETUP itself literally
    /// records." For a P10-packed file those two domains differ (see
    /// `P10Unpacker`'s own doc comment): `SETUP.BlackLevel`/`WhiteLevel` are
    /// recorded in the pre-linearization *packed* domain, so this passes
    /// them through the exact same `P10Linearization` table `P10Unpacker`
    /// itself applies to pixel data, landing both back in the same domain.
    /// Every other compression's pixel data was never companded in the
    /// first place, so `setup`'s own recorded levels are already correct
    /// and are returned unchanged.
    public var effectiveBlackWhiteLevels: (black: Int32, white: Int32) {
        let raw = setup.effectiveBlackWhiteLevels
        guard bitmapInfo.compression == .p10Packed else { return raw }
        func linearized(_ level: Int32) -> Int32 {
            Int32(P10Linearization.linearize(UInt16(clamping: max(0, level))))
        }
        return (linearized(raw.black), linearized(raw.white))
    }

    /// The absolute on-disk byte offset of frame `index`'s block — the same
    /// value `decodeFrame(at:)` reads from internally, exposed so a caller
    /// that needs to bias disk-level readahead toward a specific frame (see
    /// `primeFileCache(at:startOffset:)`) doesn't need its own copy of
    /// `FrameOffsetTable`, which is otherwise private to this type.
    public func byteOffset(ofFrame index: Int) throws -> Int {
        guard index >= 0 && index < frameCount else {
            throw CineError.frameIndexOutOfRange(index: index, count: frameCount)
        }
        return Int(offsetTable[index])
    }

    /// Decodes a single frame by its index within this file (0-based,
    /// independent of `CineFileHeader.firstImageNo`).
    public func decodeFrame(at index: Int) throws -> DecodedFrame {
        guard index >= 0 && index < frameCount else {
            throw CineError.frameIndexOutOfRange(index: index, count: frameCount)
        }
        let raw = try frameReader.readRawFrame(at: offsetTable[index])
        let pixels = unpacker.unpack(raw: raw.pixelData, width: bitmapInfo.width, height: bitmapInfo.height)
        return DecodedFrame(
            index: index,
            width: bitmapInfo.width,
            height: bitmapInfo.height,
            pixels: pixels,
            needsVerticalFlip: unpacker.needsVerticalFlip
        )
    }

    // MARK: - Raw-bytes access for CineFileWriter
    //
    // These are `internal` (no access modifier), not `public`: they exist
    // solely so `CineFileWriter` (same module, different file, so it can't
    // see `store`/`offsetTable` below since those are `private`) can copy
    // bytes verbatim during a trim, without exposing "give me raw file
    // bytes" as part of CineKit's public API surface.

    /// The exact on-disk `BITMAPINFOHEADER` bytes (`BitmapInfoHeader.byteSize`
    /// bytes, starting at `header.offImageHeader`), unparsed.
    func rawBitmapInfoBytes() throws -> Data {
        try store.read(at: header.offImageHeader, count: BitmapInfoHeader.byteSize)
    }

    /// The exact on-disk `SETUP` bytes (`setup.length` bytes, starting at
    /// `header.offSetup`), unparsed. Deliberately reads only `setup.length`
    /// bytes, not the possibly-larger buffer `CineSetup` read internally for
    /// its own field parsing (see `CineSetup`'s doc comment) — this must be
    /// exactly the real on-disk SETUP block, no more.
    func rawSetupBytes() throws -> Data {
        try store.read(at: header.offSetup, count: setup.length)
    }

    /// The raw bytes of the tagged-block region between the end of `SETUP`
    /// (`header.offSetup + setup.length`) and the frame offset table
    /// (`header.offImageOffsets`) — see `TaggedBlockRegion`/`TaggedBlock`'s
    /// doc comments for what's actually been confirmed to live here in real
    /// files (per-frame TIME64/exposure arrays). Empty when the source has
    /// no such region, i.e. `offImageOffsets` immediately follows `SETUP`.
    func rawTaggedBlockRegionBytes() throws -> Data {
        let start = header.offSetup + setup.length
        let length = header.offImageOffsets - start
        guard length > 0 else { return Data() }
        return try store.read(at: start, count: length)
    }

    /// The byte length of one frame's on-disk block — `AnnotationSize`
    /// field through the end of its `ImageSize`-declared pixel data (see
    /// `FrameReader`'s doc comment) — without reading the (potentially
    /// large) pixel payload itself.
    func rawFrameBlockSize(at index: Int) throws -> Int {
        guard index >= 0 && index < frameCount else {
            throw CineError.frameIndexOutOfRange(index: index, count: frameCount)
        }
        let base = Int(offsetTable[index])
        let sizeFieldData = try store.read(at: base, count: 4)
        let annotationSize = Int(DataReader(data: sizeFieldData).uint32(0))
        guard annotationSize >= 8 else {
            throw CineError.corruptFrame(index: index, reason: "AnnotationSize \(annotationSize) < 8")
        }
        let annotationPayloadSize = annotationSize - 8
        let imageSizeFieldOffset = base + 4 + annotationPayloadSize
        let imageSizeFieldData = try store.read(at: imageSizeFieldOffset, count: 4)
        let imageSize = Int(DataReader(data: imageSizeFieldData).uint32(0))
        return (imageSizeFieldOffset + 4 + imageSize) - base
    }

    /// One frame's exact raw on-disk block bytes, verbatim — see
    /// `rawFrameBlockSize(at:)`. Used by `CineFileWriter` for byte-for-byte
    /// frame copies during a trim; pixel data is never interpreted.
    func rawFrameBlock(at index: Int) throws -> Data {
        let base = Int(offsetTable[index])
        let size = try rawFrameBlockSize(at: index)
        return try store.read(at: base, count: size)
    }
}
