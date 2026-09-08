import Foundation

/// Errors from parsing an Adobe `.cube` 3D color lookup table (LUT) file.
public enum CubeLUTError: Error, CustomStringConvertible {
    /// Neither `LUT_3D_SIZE` nor `LUT_1D_SIZE` was found anywhere in the file.
    case missingSizeDirective
    /// The file declares `LUT_1D_SIZE` — this project's v1 only supports 3D
    /// LUTs (the standard case for real creative/camera-look LUTs).
    case unsupported1DLUT
    /// The file declares a `DOMAIN_MIN`/`DOMAIN_MAX` other than the standard
    /// [0,1] default — v1 does not attempt to rescale a non-default domain.
    case unsupportedDomain
    /// A data line didn't parse as exactly three whitespace-separated
    /// floating point numbers.
    case malformedDataLine(lineNumber: Int)
    /// The number of data lines actually found didn't equal `N*N*N` for the
    /// declared `LUT_3D_SIZE N`.
    case rowCountMismatch(expected: Int, found: Int)
    /// `init(contentsOf:)` failed to read/decode the file itself.
    case fileReadFailed(Error)

    public var description: String {
        switch self {
        case .missingSizeDirective:
            return "No LUT_3D_SIZE (or LUT_1D_SIZE) directive found in the .cube file."
        case .unsupported1DLUT:
            return "This .cube file declares a 1D LUT (LUT_1D_SIZE) — only 3D LUTs (LUT_3D_SIZE) are supported."
        case .unsupportedDomain:
            return "This .cube file declares a non-default DOMAIN_MIN/DOMAIN_MAX — only the standard [0,1] domain is supported; rescaling a custom domain is not implemented."
        case .malformedDataLine(let lineNumber):
            return "Malformed data line at line \(lineNumber): expected three whitespace-separated floating point numbers."
        case .rowCountMismatch(let expected, let found):
            return "Expected \(expected) data lines (N*N*N for the declared LUT_3D_SIZE) but found \(found)."
        case .fileReadFailed(let error):
            return "Failed to read .cube file: \(error)"
        }
    }
}

/// A parsed Adobe `.cube` 3D color lookup table (the standard format used by
/// DaVinci Resolve/Premiere/etc. for camera-look LUTs).
///
/// Pure Swift parsing over a plain `String` — Foundation-only, no Metal/
/// AppKit — matching this package's convention that file-format
/// parsing/decoding stays independent of any rendering framework. Turning
/// a parsed `CubeLUT` into a GPU-sampleable texture (e.g. a Metal 3D
/// texture) is a rendering-layer concern left entirely to the consumer.
public struct CubeLUT {
    /// N — the LUT's dimension along each axis (the file's `LUT_3D_SIZE`).
    public let size: Int

    /// Flat array of exactly `size * size * size * 3` floats (R,G,B per
    /// entry), in the file's own on-disk order — NOT reordered or expanded
    /// to RGBA here. Per the Adobe `.cube` spec, the file's Nth data line's
    /// flat index `i` maps to `r = i % N, g = (i / N) % N, b = i / (N * N)`
    /// (RED varies fastest, then GREEN, then BLUE).
    public let values: [Float]

    /// Parses `text` as a `.cube` file's contents. Exists as a String-based
    /// initializer (rather than only a URL-based one) specifically so unit
    /// tests can construct small synthetic LUTs inline as string literals,
    /// with no temp files needed.
    public init(text: String) throws {
        var declaredSize: Int?
        var dataValues: [Float] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("TITLE") {
                continue
            }
            if line.hasPrefix("LUT_1D_SIZE") {
                throw CubeLUTError.unsupported1DLUT
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let tokens = line.split(whereSeparator: { $0.isWhitespace })
                guard tokens.count == 2, let n = Int(tokens[1]) else {
                    throw CubeLUTError.malformedDataLine(lineNumber: lineNumber)
                }
                declaredSize = n
                continue
            }
            if line.hasPrefix("DOMAIN_MIN") {
                let values = try parseThreeFloats(line: line, lineNumber: lineNumber)
                if values != (0, 0, 0) {
                    throw CubeLUTError.unsupportedDomain
                }
                continue
            }
            if line.hasPrefix("DOMAIN_MAX") {
                let values = try parseThreeFloats(line: line, lineNumber: lineNumber)
                if values != (1, 1, 1) {
                    throw CubeLUTError.unsupportedDomain
                }
                continue
            }

            // Anything else is expected to be a plain "R G B" data line.
            let (r, g, b) = try parseThreeFloats(line: line, lineNumber: lineNumber)
            dataValues.append(r)
            dataValues.append(g)
            dataValues.append(b)
        }

        guard let n = declaredSize else {
            throw CubeLUTError.missingSizeDirective
        }

        let expectedCount = n * n * n
        let foundCount = dataValues.count / 3
        guard foundCount == expectedCount else {
            throw CubeLUTError.rowCountMismatch(expected: expectedCount, found: foundCount)
        }

        self.size = n
        self.values = dataValues
    }

    /// Thin wrapper around `init(text:)` that reads `url`'s contents as
    /// UTF-8 text first, wrapping any file-read failure in
    /// `.fileReadFailed`.
    public init(contentsOf url: URL) throws {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CubeLUTError.fileReadFailed(error)
        }
        try self.init(text: text)
    }

    /// Serializes this LUT back out to `.cube` text — the exact shape
    /// `init(text:)` parses back: a `LUT_3D_SIZE N` directive followed by
    /// `N*N*N` "R G B" data lines in `values`'s own flat order (red varies
    /// fastest, then green, then blue). Always the standard `[0,1]` domain
    /// (no `DOMAIN_MIN`/`DOMAIN_MAX` lines) — the only domain this type can
    /// represent in the first place, since `init(text:)` rejects any other.
    /// No `TITLE` line: this type never stores one from the file it was
    /// parsed from, so there's nothing to round-trip here.
    public var cubeText: String {
        var lines = ["LUT_3D_SIZE \(size)"]
        lines.reserveCapacity(1 + size * size * size)
        for i in stride(from: 0, to: values.count, by: 3) {
            lines.append("\(values[i]) \(values[i + 1]) \(values[i + 2])")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `cubeText` to `url` as UTF-8.
    public func write(to url: URL) throws {
        try cubeText.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Splits `line` on whitespace and parses exactly three `Float`s from it —
/// shared by data-line parsing and `DOMAIN_MIN`/`DOMAIN_MAX` parsing (the
/// latter skipping the leading directive token first).
private func parseThreeFloats(line: String, lineNumber: Int) throws -> (Float, Float, Float) {
    var tokens = line.split(whereSeparator: { $0.isWhitespace })
    // DOMAIN_MIN/DOMAIN_MAX lines carry a leading directive token before the
    // three numbers; plain data lines don't. Dropping any non-numeric
    // leading token handles both uniformly.
    if let first = tokens.first, Float(first) == nil {
        tokens.removeFirst()
    }
    guard tokens.count == 3,
          let r = Float(tokens[0]),
          let g = Float(tokens[1]),
          let b = Float(tokens[2])
    else {
        throw CubeLUTError.malformedDataLine(lineNumber: lineNumber)
    }
    return (r, g, b)
}
