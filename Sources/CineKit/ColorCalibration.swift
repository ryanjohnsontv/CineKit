import Foundation

/// Camera color calibration decomposed from `CineSetup.cmCalib`.
///
/// The decomposition below is mathematically exact (verified against the
/// bundled sample files' independently-stored `WBGain[0]` field, which
/// agrees with `whiteBalanceR`/`B` derived here to 4+ decimal places) and
/// self-consistent by construction — `whiteBalanceR/G/B` applied before
/// demosaic, followed by `matrix` after, reconstructs `cmCalib @ raw`
/// exactly (up to a harmless positive scale), for any invertible `cmCalib`.
/// It is *not*, however, a guarantee that a given file's recorded
/// `cmCalib`/`WBGain` actually describes a valid correction for that
/// file's own content — some real Vision Research sample files carry
/// calibration metadata left over from a different session that, applied
/// here, provably pushes already-reasonably-neutral footage further from
/// neutral rather than closer. Guarding against that requires actual frame
/// pixels to check the result against, which this type deliberately has no
/// access to — that check belongs in a consumer's own render pipeline, not
/// here.
///
/// Vision Research's own field documentation for `cmCalib` (copied into
/// this project's SDK-header source comments) says the matrix "bring[s]
/// camera pixels to rec 709. It includes the white balance... The cine
/// player should decompose this matrix in two components: a diagonal one
/// with the white balance to be applied before interpolation [demosaic]
/// and a normalized one to be applied after interpolation." This type is
/// exactly that decomposition, applied in that order by the render
/// pipeline: `whiteBalanceR`/`G`/`B` scale each raw mosaic sample (by its
/// CFA color role) *before* demosaicing, and `matrix` is applied to the
/// resulting RGB triple *after*.
///
/// The decomposition algorithm is ported faithfully from the open-source
/// `pycine` project's `color.py` `decompose_cmatrix` (numpy):
/// ```python
/// def decompose_cmatrix(calibration_matrix):
///     iwb = np.linalg.inv(calibration_matrix).dot(np.ones(3))
///     iwb /= iwb.max()
///     white_balance = np.zeros((3, 3))
///     np.fill_diagonal(white_balance, iwb)
///     color_matrix = calibration_matrix @ white_balance
///     diagonal = white_balance.diagonal().copy()
///     for i in range(3):
///         if iwb[i] != 0:
///             diagonal[i] = 1 / iwb[i]
///     np.fill_diagonal(white_balance, diagonal)
///     color_matrix /= color_matrix[0].sum()
///     return white_balance, color_matrix
/// ```
///
/// `Sendable`/`Equatable`: plain value type, every stored property is a
/// `Float` or `[Float]` of immutable, independently-owned data.
public struct ColorCalibration: Sendable, Equatable {
    /// Per-channel gain applied to a raw mosaic sample of that CFA color,
    /// before demosaicing.
    public let whiteBalanceR: Float
    public let whiteBalanceG: Float
    public let whiteBalanceB: Float

    /// Normalized color matrix (row-major, 9 elements), applied to the
    /// demosaiced RGB triple after interpolation, before tone-mapping.
    public let matrix: [Float]

    /// No-op calibration: unity white balance and an identity color
    /// matrix. The correct fallback whenever `cmCalib` isn't present in a
    /// file (older camera software, or one of the two untested VRI/
    /// VRI-v6 camera families) or turns out to be degenerate — so the
    /// render pipeline can apply "calibration" unconditionally without a
    /// separate code path for the absent case.
    public static let identity = ColorCalibration(
        whiteBalanceR: 1, whiteBalanceG: 1, whiteBalanceB: 1,
        matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
    )

    public init(whiteBalanceR: Float, whiteBalanceG: Float, whiteBalanceB: Float, matrix: [Float]) {
        precondition(matrix.count == 9, "color matrix must have exactly 9 (3x3 row-major) elements")
        self.whiteBalanceR = whiteBalanceR
        self.whiteBalanceG = whiteBalanceG
        self.whiteBalanceB = whiteBalanceB
        self.matrix = matrix
    }

    /// Decomposes a row-major 3x3 `cmCalib` matrix per the algorithm in
    /// this type's doc comment. Returns `nil` if `cmCalib` is singular
    /// (can't be inverted) or its row-sum normalization would divide by
    /// zero — callers should fall back to `.identity` in that case rather
    /// than propagating garbage.
    public static func decompose(cmCalib: [Float]) -> ColorCalibration? {
        precondition(cmCalib.count == 9, "cmCalib must have exactly 9 (3x3 row-major) elements")
        guard let inv = invert3x3(cmCalib) else { return nil }

        // iwb = inverse(cmCalib) . [1, 1, 1] -- i.e. each row of the
        // inverse summed.
        var iwb = [Float](repeating: 0, count: 3)
        for row in 0..<3 {
            iwb[row] = inv[row * 3 + 0] + inv[row * 3 + 1] + inv[row * 3 + 2]
        }

        let maxIwb = iwb.max() ?? 0
        guard maxIwb != 0 else { return nil }
        for i in 0..<3 { iwb[i] /= maxIwb }

        // color_matrix = cmCalib @ diag(iwb): scale column `col` of
        // cmCalib by iwb[col].
        var colorMatrix = [Float](repeating: 0, count: 9)
        for row in 0..<3 {
            for col in 0..<3 {
                colorMatrix[row * 3 + col] = cmCalib[row * 3 + col] * iwb[col]
            }
        }

        // The diagonal actually returned as "white_balance" is the
        // reciprocal of the (max-normalized) iwb -- these are the
        // per-channel gains applied to the raw mosaic, before demosaicing.
        var wb = iwb
        for i in 0..<3 where iwb[i] != 0 {
            wb[i] = 1 / iwb[i]
        }

        // Normalize so the color matrix's first row sums to 1.
        let row0Sum = colorMatrix[0] + colorMatrix[1] + colorMatrix[2]
        guard row0Sum != 0 else { return nil }
        for k in 0..<9 { colorMatrix[k] /= row0Sum }

        return ColorCalibration(whiteBalanceR: wb[0], whiteBalanceG: wb[1], whiteBalanceB: wb[2], matrix: colorMatrix)
    }

    /// Closed-form inverse of a row-major 3x3 matrix via the adjugate/
    /// cofactor method -- a general linear-algebra dependency isn't worth
    /// pulling in for a fixed 3x3. Returns `nil` if `m` is singular
    /// (determinant approximately 0).
    private static func invert3x3(_ m: [Float]) -> [Float]? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]

        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-9 else { return nil }
        let invDet = 1 / det

        return [
            (e * i - f * h) * invDet, (c * h - b * i) * invDet, (b * f - c * e) * invDet,
            (f * g - d * i) * invDet, (a * i - c * g) * invDet, (c * d - a * f) * invDet,
            (d * h - e * g) * invDet, (b * g - a * h) * invDet, (a * e - b * d) * invDet,
        ]
    }
}
