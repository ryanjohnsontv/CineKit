import Foundation

/// Abstracts random-access reads over a `.cine` file so the parsing layer
/// never assumes how the bytes got into memory (memory-mapped today; a
/// buffered/chunked implementation could be swapped in for network volumes
/// without touching any parsing code). `Sendable` conformance is pushed
/// down to each conformer rather than making `CineFile` `@unchecked Sendable`.
public protocol FileBackingStore: Sendable {
    var count: Int { get }
    func read(at offset: Int, count: Int) throws -> Data
}

/// Default backing store: memory-maps the whole file, so slicing a small
/// range only touches the pages actually read — cheap even for
/// multi-gigabyte files. The tradeoff: nothing here warms pages ahead of
/// time, so the first real reader of a page (typically
/// `CineFile.decodeFrame`) pays its disk-I/O cost synchronously — see
/// `primeFileCache(at:)`.
public struct MappedFileBackingStore: FileBackingStore {
    private let data: Data

    public init(url: URL) throws {
        self.data = try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public var count: Int { data.count }

    public func read(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw CineError.fileTooSmall
        }
        // subdata copies into a fresh 0-indexed Data, sidestepping Data's
        // slice-preserves-original-indices behavior.
        return data.subdata(in: offset..<(offset + count))
    }
}

/// Best-effort background cache warmer: sequentially reads `url` front to
/// back, discarding each chunk, purely to pull its bytes into the OS page
/// cache before anything else needs them.
///
/// `MappedFileBackingStore` only maps a file's address space — pages fault
/// in lazily on first touch, so a just-opened, never-read file pays real
/// synchronous per-page disk-I/O on every frame. Measured impact: a cold
/// file can show real-time playback displaying under 1% of a clip's
/// frames, versus 80-100%+ once warm — confirmed causally, since a plain
/// `cat file > /dev/null` alone (no app code) turns the cold case into the
/// warm one. `CineDocumentModel.open` fires this in the background the
/// moment a file opens, to give the OS a head start before the user can
/// reach for play.
///
/// Uses a buffered `read(2)` loop rather than walking a mapped `Data`:
/// matches `cat`/`dd`'s access pattern (kernel readahead-friendly) and
/// warms the same page cache a later `mmap` read will hit. Has no
/// dependency on `.cine` structure, so it can start before
/// `CineFile(url:)` parses a single header field. Cooperatively
/// cancellable (checked between chunks), best-effort (any I/O error is
/// silently swallowed — never a user-visible failure), and bounded to one
/// `chunkSize` buffer regardless of file size.
///
/// - Parameter startOffset: byte offset to warm from first, then wraps
///   around to cover the rest — lets a caller re-bias toward a frame the
///   user just jumped to while an earlier warm is still in flight. Past
///   EOF degrades gracefully to warming from `0`.
public func primeFileCache(at url: URL, startOffset: Int = 0, chunkSize: Int = 4 << 20) async {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }

    let clampedStart = max(0, startOffset)
    if clampedStart > 0 {
        guard (try? handle.seek(toOffset: UInt64(clampedStart))) != nil else { return }
    }
    while !Task.isCancelled {
        guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
    }
    guard clampedStart > 0, !Task.isCancelled else { return }

    // Wrap around: `0..<clampedStart` still needs warming too, just after
    // the region nearer whatever the caller cares about right now.
    guard (try? handle.seek(toOffset: 0)) != nil else { return }
    var remaining = clampedStart
    while !Task.isCancelled, remaining > 0 {
        guard let chunk = try? handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else { break }
        remaining -= chunk.count
    }
}
