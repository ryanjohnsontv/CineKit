import Foundation

/// Top-level entry point: opens a `.cine` file and exposes its parsed
/// headers plus per-frame decoding.
///
/// `Sendable`: a checked (not `@unchecked`) conformance — `CineFile` is
/// `final` with every stored property `let`-bound to a Sendable type
/// (immutable structs, or existentials over `Sendable`-constrained
/// protocols). Nothing is mutated after `init`, so sharing one `CineFile`
/// across actors is safe and compiler-verified.
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

    /// The general entry point behind `init(url:)` — takes any
    /// `FileBackingStore` conformer so callers can plug in their own (e.g.
    /// a buffered/chunked store for files on a network volume).
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

    /// `setup.effectiveBlackWhiteLevels`, re-expressed in the domain
    /// `decodeFrame(at:)`'s pixel output is actually in — use this (not
    /// `setup`'s own property) for tone-mapping decoded pixels. For a
    /// P10-packed file, `SETUP.BlackLevel`/`WhiteLevel` are recorded in the
    /// pre-linearization *packed* domain, so they're run through the same
    /// `P10Linearization` table `P10Unpacker` applies to pixel data. Every
    /// other compression is uncompanded, so `setup`'s levels are already
    /// correct and returned unchanged.
    public var effectiveBlackWhiteLevels: (black: Int32, white: Int32) {
        let raw = setup.effectiveBlackWhiteLevels
        guard bitmapInfo.compression == .p10Packed else { return raw }
        func linearized(_ level: Int32) -> Int32 {
            Int32(P10Linearization.linearize(UInt16(clamping: max(0, level))))
        }
        return (linearized(raw.black), linearized(raw.white))
    }

    /// The absolute on-disk byte offset of frame `index`'s block — exposed
    /// so a caller (e.g. `primeFileCache(at:startOffset:)`) can bias disk
    /// readahead toward a specific frame without its own copy of the
    /// otherwise-private `FrameOffsetTable`.
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
    // Internal, not `public`: lets `CineFileWriter` (same module, separate
    // file) copy bytes verbatim during a trim without exposing raw file
    // access as public API.

    /// The exact on-disk `BITMAPINFOHEADER` bytes (`BitmapInfoHeader.byteSize`
    /// bytes, starting at `header.offImageHeader`), unparsed.
    func rawBitmapInfoBytes() throws -> Data {
        try store.read(at: header.offImageHeader, count: BitmapInfoHeader.byteSize)
    }

    /// The exact on-disk `SETUP` bytes (`setup.length` bytes at
    /// `header.offSetup`), unparsed. Reads only `setup.length` bytes, not
    /// the possibly-larger buffer `CineSetup` reads internally for its own
    /// field parsing — this must be exactly the real on-disk SETUP block.
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
