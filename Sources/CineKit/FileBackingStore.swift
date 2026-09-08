import Foundation

/// Abstracts random-access reads over a `.cine` file so the parsing layer
/// never assumes how the bytes got into memory (memory-mapped today; a
/// buffered/chunked implementation could be swapped in later for files on
/// network volumes without touching any parsing code).
///
/// `Sendable`: every real/plausible conformer (see `MappedFileBackingStore`)
/// is an immutable value type wrapping `Data`, and `CineFile` stores its
/// backing store in a `let` property that needs to cross actor boundaries
/// (e.g. into an actor-isolated frame cache) under Swift 6 strict
/// concurrency. Requiring `Sendable` here — rather than leaving it
/// off and forcing `CineFile` into `@unchecked Sendable` — pushes the
/// thread-safety proof down to each conformer, where the compiler can
/// actually check it structurally.
public protocol FileBackingStore: Sendable {
    var count: Int { get }
    func read(at offset: Int, count: Int) throws -> Data
}

/// Default backing store: memory-maps the whole file. Slicing/copying a
/// small range out of a mapped `Data` only touches the pages actually read,
/// so this stays cheap even for multi-gigabyte files.
///
/// That laziness is exactly the double-edged property `primeFileCache(at:)`
/// below exists to manage: cheap-until-touched also means *nothing* about
/// opening a `MappedFileBackingStore` pulls the pixel-data pages into the
/// kernel's page cache ahead of time — the first real reader of any given
/// page (in practice, `CineFile.decodeFrame`, on whatever frame happens to
/// be requested first) pays that page's disk-I/O cost synchronously, at
/// whatever moment it's least convenient. See `primeFileCache(at:)`'s own
/// doc comment.
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
        // `subdata` copies into a freshly 0-indexed Data, which sidesteps
        // Data's slice-preserves-original-indices behavior and keeps every
        // downstream offset calculation relative to 0.
        return data.subdata(in: offset..<(offset + count))
    }
}

/// Best-effort background cache warmer: sequentially reads the entire file
/// at `url` from front to back, discarding every chunk as it's read, purely
/// to pull its bytes into the OS's page cache ahead of whoever actually
/// needs them next.
///
/// **Why this exists — the gap it closes:** `MappedFileBackingStore` above
/// only maps a file's *address space*; the underlying pages are faulted in
/// (i.e. actually read from disk) one at a time, lazily, the first time each
/// one is touched. For a `.cine` file nobody in this process has read yet —
/// the ordinary "open a file, then immediately press real-time play" flow —
/// that means the *first* pass through the clip pays real, synchronous
/// per-page disk-I/O latency on every frame whose bytes aren't resident yet,
/// layered underneath whatever CPU-side decode/upload cost the rest of the
/// pipeline has. That I/O cost is large enough, and disk-latency-bound
/// enough, that no amount of CPU-side scheduling cleverness downstream (see
/// `DecodedFrameCache`'s doc comment on its own off-actor decode fix) can
/// mask it — moving already-in-hand bytes to a different thread faster
/// doesn't get the bytes there any sooner if they weren't in hand yet.
/// Independently measured: a file whose bytes are not yet page-cache-resident
/// can show real-time playback displaying under 1% of a clip's frames, where
/// the *identical* code against the same file once its bytes are warm
/// displays 80-100%+ of them — a difference entirely attributable to disk
/// I/O / page-cache state, not to anything the decode/scheduling path
/// controls. Confirmed causally: a plain sequential read of the file with
/// zero app/decode/Metal code involved (e.g. `cat file > /dev/null`) turns
/// the cold case into the warm one on its own.
///
/// This function is the app-side fix for that gap: `CineDocumentModel.open`
/// fires it off in the background (see its doc comment) the moment a file
/// is opened, so the OS has as much of the file's runway as possible to
/// warm before the user can reach for a play button — rather than the first
/// real-time pass being the thing that discovers each page is cold, one
/// stall at a time.
///
/// Deliberately reads via a plain buffered `read(2)` loop (`FileHandle`)
/// through the file, not by walking a `MappedFileBackingStore`'s mapped
/// `Data`: one large sequential `read()` per chunk is exactly the same
/// operation `cat`/`dd` perform to warm a file, is friendly to the kernel's
/// own sequential-read-ahead heuristics, and — the whole point — lands in
/// the same process-wide, kernel-owned page cache that a later `mmap` read
/// of the same file will hit regardless of which API warmed it. This
/// function has no dependency on `.cine`'s structure at all (no header/
/// frame-offset parsing); it only ever needs a URL, so it can start racing
/// the disk before `CineFile(url:)` has even parsed a single header field.
///
/// - Cooperatively cancellable: checks `Task.isCancelled` between chunks, so
///   a caller that opens a second file (or is torn down) while this is still
///   running can stop it promptly instead of continuing pointless I/O for a
///   file nobody will read from anymore.
/// - Best-effort, never throws: any error (file replaced/deleted mid-read,
///   permission change, unreadable path) is silently swallowed. Failing to
///   *warm* a cache is never itself a user-visible failure — the worst case
///   is simply that playback is exactly as (un)warmed as it would have been
///   without this function existing, not a crash or a surfaced error for
///   something the user didn't directly ask for.
/// - Bounded memory footprint regardless of file size: only one `chunkSize`
///   buffer is alive at a time (unlike `Data(contentsOf:)` without
///   `.mappedIfSafe`, which would materialize the whole file), so this is
///   safe to run against a multi-gigabyte `.cine` file without itself being
///   a memory concern.
///
/// - Parameter startOffset: byte offset to warm from first, before wrapping
///   around to cover the rest of the file — `0` (the default) is the
///   original strict front-to-back behavior. Exists for a caller (e.g.
///   `CineDocumentModel`'s file-cache-priming logic) that knows the user has
///   jumped to a specific frame while an earlier front-to-back warm for the
///   same file is still in flight: restarting the warm biased at that
///   frame's byte offset gets the region the user actually cares about
///   page-cache-resident first, instead of leaving it to whichever front-to-
///   back pass would have reached there eventually. The file still ends up
///   fully warmed either way — this only changes the *order*, wrapping back
///   to `0` once the tail end (from `startOffset` on) is done, so an
///   in-progress warm is never left with a permanently-cold gap. A
///   `startOffset` at or past the end of the file degrades gracefully to
///   warming the whole file from `0` (the first read loop below finds
///   nothing to read and falls straight through to the wrap-around one,
///   which then runs into real EOF and stops on its own) rather than
///   hanging or needing its own bounds check.
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
