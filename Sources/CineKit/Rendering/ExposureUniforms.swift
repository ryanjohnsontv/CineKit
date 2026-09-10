import Foundation

/// Which of the five display modes `tonemapFragment` renders. Raw values
/// mirror the `kDebayer*` constants in `Tonemap.metal`.
public enum DebayerMode: UInt32, Sendable, CaseIterable, Hashable {
    /// Each raw mosaic value shown directly as grayscale.
    case rawSensor = 0
    /// The 2x2 CFA tile's 4 raw values averaged into one luminance value,
    /// at full resolution — removes the checkerboard mosaic texture.
    case greyScale = 1
    /// Real RGB demosaic: each missing channel copied from the nearest
    /// same-colored neighbor.
    case nearestNeighbor = 2
    /// Real RGB demosaic: each missing channel bilinearly averaged from
    /// its nearest same-colored neighbors.
    case bilinear = 3
    /// Real RGB demosaic: Malvar-He-Cutler gradient-corrected linear
    /// interpolation (H.S. Malvar, L. He, R. Cutler, "High-Quality Linear
    /// Interpolation for Demosaicing of Bayer-Patterned Color Images",
    /// ICASSP 2004).
    case highQuality = 4

    /// A short, user-facing label for a mode picker.
    public var displayName: String {
        switch self {
        case .rawSensor: return "Raw Sensor"
        case .greyScale: return "Grey Scale"
        case .nearestNeighbor: return "Nearest Neighbor"
        case .bilinear: return "Bilinear"
        case .highQuality: return "High Quality (Malvar-He-Cutler)"
        }
    }
}

/// One of the 4 possible phase alignments of a Bayer CFA's 2x2 tile,
/// identified by which corner holds the RED sample — Blue always sits at
/// the diagonally-opposite corner, Green fills the other two.
public enum CFAPhase: UInt32, Sendable, Equatable {
    /// Red at (0,0), Blue at (1,1).
    case rggb = 0
    /// Red at (1,0), Blue at (0,1).
    case grbg = 1
    /// Red at (0,1), Blue at (1,0).
    case gbrg = 2
    /// Red at (1,1), Blue at (0,0).
    case bggr = 3

    /// (x, y) parity, each 0 or 1, of the Red sample within its 2x2 tile —
    /// exactly the two values `Tonemap.metal`'s `cfaRedX`/`cfaRedY`
    /// uniforms need.
    public var redOffset: (x: UInt32, y: UInt32) {
        switch self {
        case .rggb: return (0, 0)
        case .grbg: return (1, 0)
        case .gbrg: return (0, 1)
        case .bggr: return (1, 1)
        }
    }

    /// Maps a file's `SETUP.CFA` pattern to the phase alignment its raw
    /// pixel array actually uses. A CFA pattern name alone doesn't pin down
    /// which corner a decoded array's (0,0) starts counting from, so
    /// `.gbrg` for `.bayer` was picked empirically: rendering a real,
    /// high-detail capture in High Quality mode and checking high-contrast
    /// edges for color fringing showed clean edges only at `.gbrg`.
    public static func forCFAPattern(_ cfa: CFAPattern?) -> CFAPhase {
        switch cfa {
        case nil, .some(.none):
            // Monochrome (or field absent) — demosaic is meaningless either way.
            return .rggb
        case .vri:
            // "gbrg / rggb depending on orientation" per CFAPattern's doc
            // comment; untested (no real sample from this camera family).
            return .gbrg
        case .vriV6:
            // "bggr / grbg depending on orientation" — same caveat as .vri.
            return .bggr
        case .bayer:
            return .gbrg
        case .bayerFlip:
            return .rggb
        }
    }
}

/// A row-major 3x3 matrix, laid out as 9 individually-named `Float` fields
/// (not a Swift `Array`, which is heap-indirected and unusable in a struct
/// blitted straight to a GPU uniform buffer) — matches a plain `float[9]`
/// on the Metal side exactly.
public struct ColorMatrix3x3: Equatable, Sendable {
    public var m00: Float
    public var m01: Float
    public var m02: Float
    public var m10: Float
    public var m11: Float
    public var m12: Float
    public var m20: Float
    public var m21: Float
    public var m22: Float

    public static let identity = ColorMatrix3x3(rowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// - Parameter rowMajor: exactly 9 elements, row-major (matches
    ///   `ColorCalibration.matrix`'s layout).
    public init(rowMajor values: [Float]) {
        precondition(values.count == 9, "color matrix must have exactly 9 (3x3 row-major) elements")
        self.m00 = values[0]; self.m01 = values[1]; self.m02 = values[2]
        self.m10 = values[3]; self.m11 = values[4]; self.m12 = values[5]
        self.m20 = values[6]; self.m21 = values[7]; self.m22 = values[8]
    }
}

/// Vetoes a file's recorded `cmCalib`/`WBGain` color calibration when
/// applying it would measurably push the frame *away* from neutral rather
/// than toward it — some real Vision Research capture files carry
/// calibration metadata left over from an earlier session that doesn't
/// describe their own footage (confirmed by comparing several real
/// captures' `cmCalib` against their independently-stored `WBGain[0]`).
/// Falls back to a generic (or per-camera) correction instead of the raw,
/// uncorrected sensor data.
///
/// Blind spot: an extremely over- or under-exposed frame makes the
/// gray-world comparison meaningless (nothing but clipped highlights or
/// noise-floor to measure), so `vetoedCalibration` skips the check
/// entirely — trusting the recorded calibration — whenever too much of the
/// sampled frame is clipped or at the noise floor.
public enum CalibrationPlausibility {
    /// Every 4th grid point in both dimensions — an even multiple of the
    /// Bayer tile's 2-pixel period, so `nativeChannelAverages` visits every
    /// CFA role each step regardless of phase, at ~1/4 the cost of a full scan.
    static let stride = 4

    /// How close (as a fraction of the black-to-white range) a raw sample
    /// must sit to `blackLevel`/`whiteLevel` to count as clipped/noise-floor.
    private static let clippingMargin: Float = 0.02

    /// Fraction of sampled pixels at/above which the frame is treated as too
    /// degenerate (clipped or noise-floor) to trust a gray-world measurement —
    /// comfortably covers both diagnosed real cases (~99% clipped; near-all
    /// noise-floor) without discarding a frame that's merely partly clipped.
    private static let degenerateFractionThreshold: Float = 0.5

    /// Per-CFA-role mean of the raw mosaic (black-level subtracted) over a
    /// `stride`-sampled grid, plus the fraction of samples that were
    /// clipped or noise-floor before subtraction.
    struct NativeChannelAverages {
        let r: Float
        let g: Float
        let b: Float
        let degenerateFraction: Float
    }

    static func nativeChannelAverages(frame: DecodedFrame, cfaPhase: CFAPhase, blackLevel: Float, whiteLevel: Float) -> NativeChannelAverages {
        let redOffset = cfaPhase.redOffset
        let redX = Int(redOffset.x), redY = Int(redOffset.y)
        let blueX = 1 - redX, blueY = 1 - redY
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var countR = 0, countG = 0, countB = 0
        var degenerateCount = 0
        var totalCount = 0
        let margin = (whiteLevel - blackLevel) * clippingMargin
        let nearBlackCeiling = blackLevel + margin
        let nearWhiteFloor = whiteLevel - margin

        func accumulate(x: Int, y: Int) {
            guard x < frame.width, y < frame.height else { return }
            let raw = frame.pixels[y * frame.width + x]
            totalCount += 1
            if Float(raw) <= nearBlackCeiling || Float(raw) >= nearWhiteFloor {
                degenerateCount += 1
            }
            let v = Double(raw)
            let px = x & 1
            let py = y & 1
            if px == redX && py == redY {
                sumR += v; countR += 1
            } else if px == blueX && py == blueY {
                sumB += v; countB += 1
            } else {
                sumG += v; countG += 1
            }
        }

        var y = 0
        while y < frame.height {
            var x = 0
            while x < frame.width {
                // Sample the whole 2x2 tile, not just (x, y): stride being an
                // even multiple of the tile period means x/y alone always
                // land on the same phase, silently skipping 2 of 3 colors.
                accumulate(x: x, y: y)
                accumulate(x: x + 1, y: y)
                accumulate(x: x, y: y + 1)
                accumulate(x: x + 1, y: y + 1)
                x += stride
            }
            y += stride
        }
        let bl = Double(blackLevel)
        let r = countR > 0 ? Float(sumR / Double(countR) - bl) : 0
        let g = countG > 0 ? Float(sumG / Double(countG) - bl) : 0
        let b = countB > 0 ? Float(sumB / Double(countB) - bl) : 0
        let degenerateFraction = totalCount > 0 ? Float(degenerateCount) / Float(totalCount) : 0
        return NativeChannelAverages(r: r, g: g, b: b, degenerateFraction: degenerateFraction)
    }

    /// Max minus min of the 3 channels — 0 for a perfectly neutral triple.
    private static func spread(_ v: (Float, Float, Float)) -> Float {
        let mx = max(v.0, max(v.1, v.2))
        let mn = min(v.0, min(v.1, v.2))
        return mx - mn
    }

    /// Whether applying `calibration` moves `native`'s bulk statistics closer
    /// to neutral than leaving them alone.
    static func isPlausible(_ calibration: ColorCalibration, for native: (r: Float, g: Float, b: Float)) -> Bool {
        let uncorrectedSpread = spread(native)
        let wb = (native.r * calibration.whiteBalanceR, native.g * calibration.whiteBalanceG, native.b * calibration.whiteBalanceB)
        let m = calibration.matrix
        let corrected = (
            m[0] * wb.0 + m[1] * wb.1 + m[2] * wb.2,
            m[3] * wb.0 + m[4] * wb.1 + m[5] * wb.2,
            m[6] * wb.0 + m[7] * wb.1 + m[8] * wb.2
        )
        // `<=`, not `<`: an already-neutral no-op calibration (spread 0 both
        // sides) must pass, not be wrongly vetoed.
        return spread(corrected) <= uncorrectedSpread
    }

    /// Per-2x2-CFA-tile native (r, g, b) triples, same sampling grid as
    /// `nativeChannelAverages` — kept per-tile (not collapsed to one
    /// average) so `clippingFraction` can catch a calibration that looks
    /// fine on average but clips specific tonal regions.
    static func nativeChannelTriples(frame: DecodedFrame, cfaPhase: CFAPhase, blackLevel: Float) -> [(r: Float, g: Float, b: Float)] {
        let redOffset = cfaPhase.redOffset
        let redX = Int(redOffset.x), redY = Int(redOffset.y)
        let blueX = 1 - redX, blueY = 1 - redY

        func sample(x: Int, y: Int) -> UInt16? {
            guard x < frame.width, y < frame.height else { return nil }
            return frame.pixels[y * frame.width + x]
        }

        var triples: [(r: Float, g: Float, b: Float)] = []
        var y = 0
        while y < frame.height {
            var x = 0
            while x < frame.width {
                var r: UInt16?
                var b: UInt16?
                var gSum = 0.0
                var gCount = 0
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    guard let raw = sample(x: x + dx, y: y + dy) else { continue }
                    if dx == redX && dy == redY {
                        r = raw
                    } else if dx == blueX && dy == blueY {
                        b = raw
                    } else {
                        gSum += Double(raw)
                        gCount += 1
                    }
                }
                if let r, let b, gCount > 0 {
                    let bl = Double(blackLevel)
                    triples.append((
                        r: Float(Double(r) - bl),
                        g: Float(gSum / Double(gCount) - bl),
                        b: Float(Double(b) - bl)
                    ))
                }
                x += stride
            }
            y += stride
        }
        return triples
    }

    /// Fraction of sampled tiles at/above which `vetoedCalibration` distrusts
    /// `calibration` even though it passed `isPlausible`'s average check —
    /// above the low single-digit percentage ordinary sensor noise can push
    /// negative for a genuinely correct calibration, below the ~9%+ observed
    /// on a real file with an independently-confirmed-bad calibration.
    private static let clippingFractionThreshold: Float = 0.05

    /// Whether `calibration` pushes any output channel negative (clamped to
    /// black by `Tonemap.metal`) for `triple`.
    private static func clips(_ calibration: ColorCalibration, _ triple: (r: Float, g: Float, b: Float)) -> Bool {
        let wb = (
            triple.r * calibration.whiteBalanceR,
            triple.g * calibration.whiteBalanceG,
            triple.b * calibration.whiteBalanceB
        )
        let m = calibration.matrix
        let r = m[0] * wb.0 + m[1] * wb.1 + m[2] * wb.2
        let g = m[3] * wb.0 + m[4] * wb.1 + m[5] * wb.2
        let b = m[6] * wb.0 + m[7] * wb.1 + m[8] * wb.2
        return r < 0 || g < 0 || b < 0
    }

    /// Fraction of `triples` that clip for `calibration` — the per-location
    /// counterpart to `isPlausible`'s frame-average comparison.
    static func clippingFraction(_ calibration: ColorCalibration, for triples: [(r: Float, g: Float, b: Float)]) -> Float {
        guard !triples.isEmpty else { return 0 }
        let clippedCount = triples.reduce(into: 0) { count, triple in
            if clips(calibration, triple) { count += 1 }
        }
        return Float(clippedCount) / Float(triples.count)
    }

    /// A generic, scene-independent fallback for a vetoed calibration —
    /// identity alone would leave the sensor's raw spectral response
    /// (never Rec.709-matched) uncorrected, producing a persistent
    /// green/washed-out look.
    ///
    /// Derived by regressing raw bilinear-demosaiced sensor RGB against a
    /// real DaVinci Resolve "zero grading" render (6 hand-picked regions of
    /// one scene): a diagonal white-balance gain, then a ridge-regularized
    /// residual 3x3 matrix (unregularized matched color accuracy but
    /// amplified noise). Validated against a held-out frame of the same
    /// file.
    ///
    /// **Caveat**: fit from one file under one lighting condition — a real
    /// improvement over no correction, not a universal calibration. Also
    /// fit against gamma-encoded rather than true linear values (the
    /// domain mismatch later fixed for `veoFallback` below); not redone
    /// since the reference material is no longer available.
    private static let genericFallback = ColorCalibration(
        whiteBalanceR: 0.7468678858351011,
        whiteBalanceG: 0.5895917817539703,
        whiteBalanceB: 0.8536762111530525,
        matrix: [
            1.9765740714583142, -1.6167489396545385, 0.5028913041710531,
            -0.2163544403921644, -0.4770827906953295, 1.5508117575574976,
            -0.8419404627467321, -1.038717405074019, 2.7472224997552472,
        ]
    )

    /// A fallback for one specific Phantom hardware revision
    /// (`CineSetup.cameraVersion`, distinct from `serial`) whose own
    /// `cmCalib` fails both plausibility checks (clips ~9% of frame 0
    /// alone, farther from a real Resolve reference than doing nothing) —
    /// `genericFallback`, fit from unrelated hardware, has no reason to
    /// correct for that either.
    ///
    /// Derived like `genericFallback` but in the correct domain: true
    /// linear camera-native RGB (demosaiced, identity-calibrated, Rec.709
    /// OETF and P10 companding both inverted out) against the Resolve
    /// reference's own linear values, sampled across 3 frames rather than
    /// one still frame's hand-picked regions.
    ///
    /// **Validated on a held-out frame**: mean absolute error against the
    /// Resolve reference is 6.1 (0-255 scale) vs. 21.4 for `.identity`, a
    /// ~71% reduction — close enough to the fit frames' own error that this
    /// isn't overfitting. Fit from one hardware revision under one shoot's
    /// lighting, keyed by `cameraVersion`; not independently verified
    /// beyond that.
    private static let veoFallback = ColorCalibration(
        whiteBalanceR: 2.0308789512110796,
        whiteBalanceG: 0.9099304067476847,
        whiteBalanceB: 1.4673041969484928,
        matrix: [
            1.000192723667483, 0.0007430503053335955, -0.001199720125065869,
            -0.002204117987742132, 0.9985447050892037, 0.006007552953927219,
            -0.003647393783310004, -0.0020861312597412886, 1.003340758888242,
        ]
    )

    /// The hardware revision `veoFallback` was fit for — see its doc comment.
    private static let veoCameraVersion: UInt32 = 7011

    /// The fallback for a vetoed calibration on a file identified by
    /// `cameraVersion` — `veoFallback` for `veoCameraVersion`, `genericFallback`
    /// (fit from different hardware) for everything else.
    private static func fallback(forCameraVersion cameraVersion: UInt32?) -> ColorCalibration {
        switch cameraVersion {
        case veoCameraVersion: return veoFallback
        default: return genericFallback
        }
    }

    /// Why `assess` did or didn't trust a calibration — surfaceable to a UI
    /// as a "Black Balance Assist"-style hint (à la Séance), distinct from
    /// `vetoedCalibration`'s silent behind-the-scenes fallback substitution.
    public enum Assessment: Equatable, Sendable {
        /// Passed both checks, or was `.identity` (trivially trusted).
        case trusted
        /// Moves the frame's bulk statistics away from neutral rather than
        /// toward it — the calibration likely doesn't describe this footage.
        case movesAwayFromNeutral
        /// Passes on average but clips specific tonal regions to black.
        case clipsLocally
        /// Too much of the frame is clipped or at the noise floor to measure
        /// either check — `calibration` is trusted by default, not assessed.
        case indeterminate
    }

    /// Diagnoses `calibration` against `frame`'s own statistics without
    /// picking a replacement — the read-only counterpart to
    /// `vetoedCalibration`, for UI that wants to *tell the user* a
    /// recalibration may be needed rather than silently substituting one.
    public static func assess(
        _ calibration: ColorCalibration,
        frame: DecodedFrame,
        cfaPhase: CFAPhase,
        blackLevel: Float,
        whiteLevel: Float
    ) -> Assessment {
        guard calibration != .identity else { return .trusted }
        let native = nativeChannelAverages(frame: frame, cfaPhase: cfaPhase, blackLevel: blackLevel, whiteLevel: whiteLevel)
        guard native.degenerateFraction < degenerateFractionThreshold else { return .indeterminate }
        guard isPlausible(calibration, for: (native.r, native.g, native.b)) else { return .movesAwayFromNeutral }
        let triples = nativeChannelTriples(frame: frame, cfaPhase: cfaPhase, blackLevel: blackLevel)
        guard clippingFraction(calibration, for: triples) < clippingFractionThreshold else { return .clipsLocally }
        return .trusted
    }

    /// `calibration`, or a per-camera fallback if `assess` finds it
    /// implausible for `frame` — the single shared veto decision every
    /// renderer caller uses, so none can drift out of sync. `.indeterminate`
    /// trusts `calibration` outright, same as `.trusted`.
    public static func vetoedCalibration(
        _ calibration: ColorCalibration,
        frame: DecodedFrame,
        cfaPhase: CFAPhase,
        blackLevel: Float,
        whiteLevel: Float,
        cameraVersion: UInt32? = nil
    ) -> ColorCalibration {
        switch assess(calibration, frame: frame, cfaPhase: cfaPhase, blackLevel: blackLevel, whiteLevel: whiteLevel) {
        case .trusted, .indeterminate:
            return calibration
        case .movesAwayFromNeutral, .clipsLocally:
            return fallback(forCameraVersion: cameraVersion)
        }
    }
}

/// Uniform parameters passed to the Tonemap vertex/fragment shader pair.
/// Memory layout must exactly mirror the `ExposureUniforms` struct in
/// `Shaders/Tonemap.metal` (twenty 4-byte fields, no padding).
///
/// `blackLevel`/`whiteLevel` drive the linear stretch applied to every
/// mode. `flipVertically` orients the full-screen triangle's UVs for frames
/// where `DecodedFrame.needsVerticalFlip == true`. `debayerMode`/`cfaRedX`/
/// `cfaRedY` select the display mode and (for the 3 real demosaic modes)
/// the Bayer phase to demosaic against. `wbGainR/G/B` and `colorMatrix` are
/// the color calibration pipeline — white balance applied per-channel to
/// the raw mosaic before demosaicing, the matrix to the demosaiced RGB
/// after; both ignored by `.rawSensor`/`.greyScale`. Default values (unity
/// gains, identity matrix) are themselves a correct no-op.
///
/// `gamma` rides along in the buffer but isn't currently read by the
/// shader — `Tonemap.metal` uses the fixed Rec.709 OETF instead of a
/// tunable power law — kept as a slot for a possible future custom-gamma
/// mode rather than reworking the buffer layout for no current benefit.
public struct ExposureUniforms: Equatable {
    public var blackLevel: Float
    public var whiteLevel: Float
    /// 0 or 1. Non-zero when the source frame must be vertically flipped
    /// before display (mirrors `DecodedFrame.needsVerticalFlip`).
    public var flipVertically: UInt32
    /// Mirrors `DebayerMode.rawValue`.
    public var debayerMode: UInt32
    /// (x, y) parity of the Red sample within its 2x2 CFA tile — mirrors
    /// `CFAPhase.redOffset`. Only meaningful for the 3 real demosaic modes.
    public var cfaRedX: UInt32
    public var cfaRedY: UInt32
    public var wbGainR: Float
    public var wbGainG: Float
    public var wbGainB: Float
    public var colorMatrix: ColorMatrix3x3
    public var gamma: Float
    /// 0 or 1. Non-zero enables `tonemapFragment`'s post-gamma 3D LUT
    /// sampling stage (see `LUTTexture`/`CineRenderer.render`'s `lutTexture`
    /// parameter).
    public var lutEnabled: UInt32

    public init(
        blackLevel: Float,
        whiteLevel: Float,
        flipVertically: Bool = false,
        debayerMode: DebayerMode = .rawSensor,
        cfaPhase: CFAPhase = .rggb,
        colorCalibration: ColorCalibration = .identity,
        gamma: Float = 2.2,
        lutEnabled: Bool = false
    ) {
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.flipVertically = flipVertically ? 1 : 0
        self.debayerMode = debayerMode.rawValue
        let redOffset = cfaPhase.redOffset
        self.cfaRedX = redOffset.x
        self.cfaRedY = redOffset.y
        self.wbGainR = colorCalibration.whiteBalanceR
        self.wbGainG = colorCalibration.whiteBalanceG
        self.wbGainB = colorCalibration.whiteBalanceB
        self.colorMatrix = ColorMatrix3x3(rowMajor: colorCalibration.matrix)
        // Not currently read by the shader (see type doc comment) — guard
        // against a degenerate on-disk value the same way
        // effectiveBlackWhiteLevels guards its own divisor.
        self.gamma = gamma > 0 ? gamma : 2.2
        self.lutEnabled = lutEnabled ? 1 : 0
    }

    /// Derives the black/white points, CFA phase, and color calibration
    /// from `cineFile` and carries forward `frame.needsVerticalFlip` — the
    /// one place this mapping is defined, so every caller stays in sync.
    ///
    /// Takes the whole `CineFile`, not just `cineFile.setup`, so
    /// `CineFile.effectiveBlackWhiteLevels` (not `CineSetup`'s lower-level
    /// property of the same name) supplies the black/white points — see
    /// that property's doc comment for why a P10-packed file's raw
    /// `SETUP.BlackLevel`/`WhiteLevel` alone aren't the right numbers here.
    public init(
        cineFile: CineFile,
        frame: DecodedFrame,
        debayerMode: DebayerMode = .rawSensor,
        lutEnabled: Bool = false
    ) {
        let setup = cineFile.setup
        let levels = cineFile.effectiveBlackWhiteLevels
        let cfaPhase = CFAPhase.forCFAPattern(setup.cfa)
        let calibration = CalibrationPlausibility.vetoedCalibration(
            setup.colorCalibration ?? .identity,
            frame: frame,
            cfaPhase: cfaPhase,
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            cameraVersion: setup.cameraVersion
        )
        self.init(
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            flipVertically: frame.needsVerticalFlip,
            debayerMode: debayerMode,
            cfaPhase: cfaPhase,
            colorCalibration: calibration,
            gamma: setup.fGamma ?? 2.2,
            lutEnabled: lutEnabled
        )
    }
}
