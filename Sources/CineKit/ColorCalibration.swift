import Foundation

/// Camera color calibration decomposed from `CineSetup.cmCalib`.
///
/// Mathematically exact (verified against the bundled sample files'
/// independently-stored `WBGain[0]`, matching to 4+ decimal places) and
/// self-consistent: `whiteBalanceR/G/B` applied before demosaic, then
/// `matrix` after, reconstructs `cmCalib @ raw` exactly (up to a harmless
/// positive scale). It is *not* a guarantee that a file's recorded
/// `cmCalib`/`WBGain` actually suits its own content — some real sample
/// files carry calibration left over from a different session that
/// provably pushes already-neutral footage further from neutral. Catching
/// that needs real frame pixels, which this type has no access to; see
/// `CalibrationPlausibility` for that check.
///
/// Vision Research's field documentation for `cmCalib` says the matrix
/// "bring[s] camera pixels to rec 709. It includes the white balance... The
/// cine player should decompose this matrix in two components: a diagonal
/// one with the white balance to be applied before interpolation [demosaic]
/// and a normalized one to be applied after interpolation." This type is
/// exactly that decomposition.
///
/// Ported faithfully from the open-source `pycine` project's `color.py`
/// `decompose_cmatrix` (numpy):
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

    /// No-op calibration (unity white balance, identity matrix) — the
    /// fallback when `cmCalib` is absent (older firmware, untested VRI/
    /// VRI-v6 families) or degenerate, so the render pipeline can apply
    /// "calibration" unconditionally with no separate absent-case path.
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
