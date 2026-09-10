import Foundation

/// A lazy view over the `.cine` file's `SETUP` block.
///
/// The on-disk block is only `Setup.Length` bytes — camera software has
/// appended new fields over two decades, and older files lack the newer
/// trailing ones. Real sample files here had `Length` 9344–10412, far
/// short of the ~13484-byte struct in the newest known schema. Reading
/// past `Length` would return whatever bytes happen to follow (tag blocks,
/// frame data), so every accessor below is `nil` unless its field fits
/// entirely within the bytes actually present.
///
/// `Sendable` is explicit: `bytes`/`reader` are immutable after `init`;
/// `CineFile`, which stores one, needs this to hand a file to an actor.
public struct CineSetup: Sendable {
    /// Exactly `Length` bytes read from `CineFileHeader.offSetup`, 0-indexed.
    private let bytes: Data
    private let reader: DataReader

    /// The number of bytes of SETUP actually present in this file, per the
    /// struct's own `Length` field.
    public let length: Int

    init(data: Data) {
        self.bytes = data
        self.reader = DataReader(data: data)
        // `Length` itself must be readable for this to mean anything; if the
        // file is truncated even before that, treat nothing as present.
        if data.count >= SetupFieldLayout.lengthOffset + SetupFieldLayout.lengthSize {
            self.length = Int(reader.uint16(SetupFieldLayout.lengthOffset))
        } else {
            self.length = 0
        }
    }

    private func present(_ offset: Int, _ size: Int) -> Bool {
        offset + size <= length && offset + size <= bytes.count
    }

    /// The "ST" marker every real SETUP block starts its post-legacy-fields
    /// section with. Used as a sanity/regression canary, not for decoding.
    public var mark: String? {
        guard present(SetupFieldLayout.markOffset, SetupFieldLayout.markSize) else { return nil }
        return reader.fixedString(SetupFieldLayout.markOffset, maxLength: SetupFieldLayout.markSize)
    }

    public var imWidth: UInt16? {
        guard present(SetupFieldLayout.imWidthOffset, SetupFieldLayout.imWidthSize) else { return nil }
        return reader.uint16(SetupFieldLayout.imWidthOffset)
    }

    public var imHeight: UInt16? {
        guard present(SetupFieldLayout.imHeightOffset, SetupFieldLayout.imHeightSize) else { return nil }
        return reader.uint16(SetupFieldLayout.imHeightOffset)
    }

    public var serial: UInt32? {
        guard present(SetupFieldLayout.serialOffset, SetupFieldLayout.serialSize) else { return nil }
        return reader.uint32(SetupFieldLayout.serialOffset)
    }

    /// 32-bit frame rate in frames per second. Prefer this over `frameRate16`
    /// when present (the 16-bit field is retained only for old-file
    /// compatibility and saturates at 65535fps).
    public var frameRate: UInt32? {
        guard present(SetupFieldLayout.frameRateOffset, SetupFieldLayout.frameRateSize) else { return nil }
        return reader.uint32(SetupFieldLayout.frameRateOffset)
    }

    public var frameRate16: UInt16? {
        guard present(SetupFieldLayout.frameRate16Offset, SetupFieldLayout.frameRate16Size) else { return nil }
        return reader.uint16(SetupFieldLayout.frameRate16Offset)
    }

    /// Double-precision frame rate, in the newest known schema only — at
    /// offset 13472, near the 13484-byte `maxKnownSize` ceiling, so only
    /// `present` in a file with close to the longest `SETUP` block Vision
    /// Research has shipped. None of this package's samples reach that
    /// length, so it's untested against real data — but its
    /// offset/size/type (`c_double`, "High precision acquisition frame
    /// rate", ending SETUP as of software version 751) is cross-checked
    /// against `pycine`'s struct definition.
    public var dFrameRate: Double? {
        guard present(SetupFieldLayout.dFrameRateOffset, SetupFieldLayout.dFrameRateSize) else { return nil }
        return reader.float64(SetupFieldLayout.dFrameRateOffset)
    }

    /// Best-available frame rate, preferring the most precise field that's
    /// actually present: the double-precision field, then the modern 32-bit
    /// field, then the legacy 16-bit one.
    public var effectiveFrameRate: Double? {
        if let dFrameRate { return dFrameRate }
        if let frameRate { return Double(frameRate) }
        if let frameRate16 { return Double(frameRate16) }
        return nil
    }

    public var isColorEnabled: Bool? {
        guard present(SetupFieldLayout.bEnableColorOffset, SetupFieldLayout.bEnableColorSize) else { return nil }
        return reader.int32(SetupFieldLayout.bEnableColorOffset) != 0
    }

    /// `SETUP.CameraVersion` — per Vision Research's spec (see `README.md`'s
    /// "Specification" link), "the version of camera hardware": a model/
    /// hardware-revision code shared by every unit of that revision, not a
    /// per-unit id like `serial` and not a firmware/software version
    /// (`FirmwareVersion`/`SoftwareVersion` are separate adjacent fields).
    /// Useful as a stable key for hardware-revision-specific behavior, e.g.
    /// a per-camera-model color calibration fallback.
    public var cameraVersion: UInt32? {
        guard present(SetupFieldLayout.cameraVersionOffset, SetupFieldLayout.cameraVersionSize) else { return nil }
        return reader.uint32(SetupFieldLayout.cameraVersionOffset)
    }

    /// The sensor's Color Filter Array pattern. `nil` if absent from this
    /// file; `.none` is a valid decoded value meaning "monochrome sensor".
    public var cfa: CFAPattern? {
        guard present(SetupFieldLayout.cfaOffset, SetupFieldLayout.cfaSize) else { return nil }
        return CFAPattern(rawValue: reader.uint32(SetupFieldLayout.cfaOffset))
    }

    /// Real sensor bit depth (8/10/12/14), independent of how pixels are
    /// packed on disk.
    public var realBPP: UInt32? {
        guard present(SetupFieldLayout.realBPPOffset, SetupFieldLayout.realBPPSize) else { return nil }
        return reader.uint32(SetupFieldLayout.realBPPOffset)
    }

    public var shutterNs: UInt32? {
        guard present(SetupFieldLayout.shutterNsOffset, SetupFieldLayout.shutterNsSize) else { return nil }
        return reader.uint32(SetupFieldLayout.shutterNsOffset)
    }

    /// Legacy 16-bit shutter/exposure duration, in **microseconds** — per
    /// Vision Research's own field documentation (as transcribed in the
    /// open-source `pycine` project's struct comments): "Shutter field
    /// (exposure duration) was specified initially in microseconds, later
    /// the field ShutterNs was added to store the value in nanoseconds."
    /// Prefer `shutterNs`/`effectiveShutterNs` — this exists only for very
    /// old files that predate it.
    public var shutter16: UInt16? {
        guard present(SetupFieldLayout.shutter16Offset, SetupFieldLayout.shutter16Size) else { return nil }
        return reader.uint16(SetupFieldLayout.shutter16Offset)
    }

    /// Best-available exposure duration, in nanoseconds — preferring the
    /// modern `shutterNs` field, falling back to the legacy 16-bit
    /// microseconds-unit `shutter16` (converted) only when `shutterNs`
    /// itself isn't present in this file's `SETUP` block.
    public var effectiveShutterNs: UInt32? {
        if let shutterNs { return shutterNs }
        if let shutter16 { return UInt32(shutter16) * 1000 }
        return nil
    }

    /// Black point in raw sensor units, for tone-mapping raw pixel values.
    public var blackLevel: Int32? {
        guard present(SetupFieldLayout.blackLevelOffset, SetupFieldLayout.blackLevelSize) else { return nil }
        return reader.int32(SetupFieldLayout.blackLevelOffset)
    }

    /// White point in raw sensor units, for tone-mapping raw pixel values.
    public var whiteLevel: Int32? {
        guard present(SetupFieldLayout.whiteLevelOffset, SetupFieldLayout.whiteLevelSize) else { return nil }
        return reader.int32(SetupFieldLayout.whiteLevelOffset)
    }

    /// Best-effort black/white points: falls back to a `realBPP`-derived
    /// default (flat 10-bit assumption) when the explicit fields are
    /// absent.
    ///
    /// **Not the right values for a P10-packed file's decoded pixels** —
    /// the spec records these in the pre-linearization *packed* domain
    /// (64/1015 on every real P10 sample seen), while `decodeFrame(at:)`'s
    /// output is already linearized (see `P10Unpacker`). Use
    /// `CineFile.effectiveBlackWhiteLevels` for an actual pixel-domain
    /// stretch; this property is still correct for every other
    /// compression, and as "what SETUP literally records" in all cases.
    public var effectiveBlackWhiteLevels: (black: Int32, white: Int32) {
        let bpp = realBPP ?? 10
        let defaultWhite = Int32((1 << bpp) - 1)
        return (blackLevel ?? 0, whiteLevel ?? defaultWhite)
    }

    public var cameraModel: String? {
        guard present(SetupFieldLayout.cameraModelOffset, SetupFieldLayout.cameraModelSize) else { return nil }
        return reader.fixedString(SetupFieldLayout.cameraModelOffset, maxLength: SetupFieldLayout.cameraModelSize)
    }

    /// White-balance gain for the Red channel, head 0 (`WBGain[0].R`) — the
    /// gain for the whole image on a single-head camera, or the top-left
    /// head on a multihead (stereo/quad) camera. Relative to Green == 1.0.
    public var wbGainR: Float? {
        guard present(SetupFieldLayout.wbGain0ROffset, SetupFieldLayout.wbGain0RSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbGain0ROffset)
    }

    /// White-balance gain for the Blue channel, head 0 (`WBGain[0].B`).
    public var wbGainB: Float? {
        guard present(SetupFieldLayout.wbGain0BOffset, SetupFieldLayout.wbGain0BSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbGain0BOffset)
    }

    /// White-balance gain, Red, head 1 (`WBGain[1].R`, top-right on a
    /// multihead camera) — present on disk but meaningless on a
    /// single-head camera. See `wbGainR`.
    public var wbGain1R: Float? {
        guard present(SetupFieldLayout.wbGain1ROffset, SetupFieldLayout.wbGain1RSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbGain1ROffset)
    }

    /// White-balance gain, Blue, head 1 (`WBGain[1].B`).
    public var wbGain1B: Float? {
        guard present(SetupFieldLayout.wbGain1BOffset, SetupFieldLayout.wbGain1BSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbGain1BOffset)
    }

    /// White-balance gain, Red, head 2 (`WBGain[2].R`, bottom-left) — see
    /// `wbGain1R`.
    public var wbGain2R: Float? {
        guard present(SetupFieldLayout.wbGain2ROffset, SetupFieldLayout.wbGain2RSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbGain2ROffset)
    }

    /// White-balance gain, Blue, head 2 (`WBGain[2].B`).
    public var wbGain2B: Float? {
        guard present(SetupFieldLayout.wbGain2BOffset, SetupFieldLayout.wbGain2BSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbGain2BOffset)
    }

    /// White-balance gain, Red, head 3 (`WBGain[3].R`, bottom-right) — see
    /// `wbGain1R`.
    public var wbGain3R: Float? {
        guard present(SetupFieldLayout.wbGain3ROffset, SetupFieldLayout.wbGain3RSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbGain3ROffset)
    }

    /// White-balance gain, Blue, head 3 (`WBGain[3].B`).
    public var wbGain3B: Float? {
        guard present(SetupFieldLayout.wbGain3BOffset, SetupFieldLayout.wbGain3BSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbGain3BOffset)
    }

    /// Rotation to apply to the image, in degrees. `0` = do nothing, `90` =
    /// counterclockwise, `-90` = clockwise — see
    /// `SetupFieldLayout.rotateOffset`'s doc comment.
    public var rotationDegrees: Int32? {
        guard present(SetupFieldLayout.rotateOffset, SetupFieldLayout.rotateSize) else { return nil }
        return reader.int32(SetupFieldLayout.rotateOffset)
    }

    /// White-balance gain for the Red channel meant for the
    /// post-demosaic/interpolated pipeline stage (`WBView.R`) — distinct
    /// from `wbGainR`'s pre-interpolation, per-head gain; see
    /// `SetupFieldLayout.wbViewROffset`'s doc comment.
    public var wbViewR: Float? {
        guard present(SetupFieldLayout.wbViewROffset, SetupFieldLayout.wbViewRSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbViewROffset)
    }

    /// White-balance gain for the Blue channel meant for the
    /// post-demosaic/interpolated pipeline stage (`WBView.B`) — see
    /// `wbViewR`'s doc comment.
    public var wbViewB: Float? {
        guard present(SetupFieldLayout.wbViewBOffset, SetupFieldLayout.wbViewBSize) else { return nil }
        return reader.float32(SetupFieldLayout.wbViewBOffset)
    }

    /// Global display gamma (neutral at 1.0); see `SetupFieldLayout.fGammaOffset`'s
    /// doc comment for why this is applied at render time only.
    public var fGamma: Float? {
        guard present(SetupFieldLayout.fGammaOffset, SetupFieldLayout.fGammaSize) else { return nil }
        return reader.float32(SetupFieldLayout.fGammaOffset)
    }

    /// Video *playback* (review) rate in frames per second, `SETUP.fPbRate`
    /// — distinct from `effectiveFrameRate`, the sensor's *capture* rate. A
    /// camera's on-camera "video system" setting (e.g. VEO's 1080p24/25/30
    /// menu option) writes this human-authored review speed independent of
    /// capture rate; see `SetupFieldLayout.pbRateOffset` for sourcing. All 4
    /// real sample files read exactly 24.0 here despite different capture
    /// rates — but older/shorter SETUP blocks genuinely lack this field, so
    /// don't assume it's always present.
    public var pbRate: Float? {
        guard present(SetupFieldLayout.pbRateOffset, SetupFieldLayout.pbRateSize) else { return nil }
        return reader.float32(SetupFieldLayout.pbRateOffset)
    }

    /// The raw 3x3 (row-major, 9 floats) RGB color calibration matrix; see
    /// `SetupFieldLayout.cmCalibOffset`'s doc comment. Prefer
    /// `colorCalibration` in almost every case -- this decomposes the
    /// matrix into the white-balance/color-matrix pair the render pipeline
    /// actually needs.
    public var cmCalib: [Float]? {
        guard present(SetupFieldLayout.cmCalibOffset, SetupFieldLayout.cmCalibSize) else { return nil }
        return (0..<9).map { reader.float32(SetupFieldLayout.cmCalibOffset + $0 * 4) }
    }

    /// Decomposed white-balance gains + normalized color matrix, derived
    /// from `cmCalib` per Vision Research's documented split (see
    /// `ColorCalibration`'s doc comment). `nil` when `cmCalib` is absent
    /// (older firmware, or the untested VRI/VRI-v6 families), all-zero, or
    /// singular/undecomposable -- callers should fall back to
    /// `ColorCalibration.identity` in every such case.
    public var colorCalibration: ColorCalibration? {
        guard let cm = cmCalib, cm.contains(where: { $0 != 0 }) else { return nil }
        return ColorCalibration.decompose(cmCalib: cm)
    }
}
