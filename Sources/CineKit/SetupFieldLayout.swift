import Foundation

/// Byte offsets (relative to the start of the `SETUP` block, i.e. relative to
/// `CineFileHeader.offSetup`) for every field in Vision Research's `SETUP`
/// struct, current through software release 771 (Dec 2017). The struct is
/// declared with 1-byte packing and has grown by simple append-only field
/// additions across two decades of camera software — these offsets are the
/// cumulative byte sum of every field declared before it, in original
/// declaration order, and have been cross-checked against a known-good
/// ctypes definition (matching offsets exactly, including a real-file
/// "Mark" == "ST" sanity check — see CineSetupTests).
///
/// Only fields actually used by CineKit have named constants below; the
/// rest of the struct's layout is implicitly encoded by leaving gaps, since
/// no downstream field depends on anything but its own absolute offset.
enum SetupFieldLayout {
    static let markOffset = 140
    static let markSize = 2

    static let lengthOffset = 142
    static let lengthSize = 2

    static let imWidthOffset = 737
    static let imWidthSize = 2

    static let imHeightOffset = 739
    static let imHeightSize = 2

    static let serialOffset = 743
    static let serialSize = 4

    static let frameRateOffset = 768
    static let frameRateSize = 4

    static let bEnableColorOffset = 788
    static let bEnableColorSize = 4

    static let cameraVersionOffset = 792
    static let cameraVersionSize = 4

    static let cfaOffset = 808
    static let cfaSize = 4

    static let realBPPOffset = 896
    static let realBPPSize = 4

    /// `WBGain` is an array of 4 `WBGAIN {R: float, B: float}` structs, one
    /// per camera head — per Vision Research's own field documentation (as
    /// transcribed in `pycine`'s struct comments): "index 0: all image for
    /// v4,5,7... and TL head for v6, v6.2 (multihead); index 1, 2, 3: TR,
    /// BL, BR for multihead." So on an ordinary single-head camera, only
    /// index 0 is meaningful — indices 1-3 are still present on disk (once
    /// `Length` reaches this far) but describe heads that don't exist.
    /// This offset itself is cross-checked against `pycine`'s `tagSETUP`
    /// ctypes definition (software release 792), whose `WBGain` field lands
    /// at this same offset given every other offset above/below it in this
    /// file — and directly against a real sample file's raw bytes, which
    /// decode here to R=1.4338/B=1.7335 (matching a plausible, non-identity
    /// white balance, not garbage).
    static let wbGain0ROffset = 852
    static let wbGain0RSize = 4

    static let wbGain0BOffset = 856
    static let wbGain0BSize = 4

    static let wbGain1ROffset = 860
    static let wbGain1RSize = 4

    static let wbGain1BOffset = 864
    static let wbGain1BSize = 4

    static let wbGain2ROffset = 868
    static let wbGain2RSize = 4

    static let wbGain2BOffset = 872
    static let wbGain2BSize = 4

    static let wbGain3ROffset = 876
    static let wbGain3RSize = 4

    static let wbGain3BOffset = 880
    static let wbGain3BSize = 4

    /// Rotation to apply to the image, in degrees — 0 = do nothing, +90 =
    /// counterclockwise, -90 = clockwise, per Vision Research's own field
    /// documentation (as transcribed in `pycine`'s struct comments).
    /// Immediately after the last `WBGain` entry (876 + 4 = 880... 880 + 4
    /// = 884), cross-checked the same way as `wbGain0ROffset` above.
    static let rotateOffset = 884
    static let rotateSize = 4

    /// A second, separate `WBGAIN {R, B}` — "White balance to apply on
    /// color interpolated Cines" per Vision Research's own field
    /// documentation, i.e. meant for the post-demosaic pipeline stage,
    /// distinct from `WBGain` above (which is pre-interpolation, per-head).
    /// Immediately after `Rotate`, cross-checked the same way as
    /// `wbGain0ROffset` above — and its own offset lands exactly where
    /// `realBPPOffset` below (896) is reached next (888 + 8 = 896),
    /// cross-validating this whole neighborhood's offset math.
    static let wbViewROffset = 888
    static let wbViewRSize = 4

    static let wbViewBOffset = 892
    static let wbViewBSize = 4

    static let shutterNsOffset = 1568
    static let shutterNsSize = 4

    static let blackLevelOffset = 5732
    static let blackLevelSize = 4

    static let whiteLevelOffset = 5736
    static let whiteLevelSize = 4

    /// Global display gamma, neutral at 1.0. Vision Research's own public
    /// support documentation describes 2.2 as their software's *default*
    /// display transform for these linear raw files — applied at
    /// display/render time only, never baked into stored pixel data.
    /// Cross-checked the same way as `wbGain0ROffset` above (pycine
    /// `tagSETUP.fGamma` offset, and a real file decoding to a plausible
    /// 2.2, not garbage).
    static let fGammaOffset = 6024
    static let fGammaSize = 4

    /// Video *playback* (review) rate in frames per second, `SETUP.fPbRate`
    /// per Vision Research's own "Cine File Format" specification (June
    /// 2011), byte offset 6976 (0x1B40) relative to SETUP start — cross-
    /// checked against two independent open-source .cine parsers (pycine,
    /// pims), which agree on both the name and offset. A sibling field,
    /// `fTcRate` (SMPTE timecode-generation rate), immediately follows at
    /// offset 6980; it serves a narrower purpose and is intentionally not
    /// exposed here.
    ///
    /// This is *not* the sensor's capture rate (see `frameRateOffset` /
    /// `effectiveFrameRate`) -- it's the rate a camera's on-camera "video
    /// system" review setting (e.g. VEO cameras' 1080p24/25/30 menu option)
    /// writes into the file, describing how the footage should be played
    /// back for review, independent of how fast it was actually captured.
    /// Empirically confirmed against this project's own 4 real sample
    /// files: every one reads exactly 24.0 here despite having very
    /// different capture rates (1000/240/1536/1536fps).
    static let pbRateOffset = 6976
    static let pbRateSize = 4

    static let frameRate16Offset = 0
    static let frameRate16Size = 2

    static let shutter16Offset = 2
    static let shutter16Size = 2

    /// The RGB color calibration matrix (3x3, row-major, 9 floats) that
    /// "brings camera pixels to rec 709" per Vision Research's own field
    /// documentation — it bundles the white balance and a normalized color
    /// matrix together; `ColorCalibration.decompose(cmCalib:)` splits the
    /// two back apart. Cross-checked the same way as `wbGain0ROffset`
    /// above.
    static let cmCalibOffset = 7252
    static let cmCalibSize = 36

    static let cameraModelOffset = 12432
    static let cameraModelSize = 1024

    static let dFrameRateOffset = 13472
    static let dFrameRateSize = 8

    /// Size of the full struct in the newest known schema (software release
    /// 771, Dec 2017) — an upper bound on how many bytes of SETUP could
    /// possibly be present in any real file, used when deciding how much to
    /// read off disk before `Setup.Length` itself is known.
    static let maxKnownSize = 13484
}

/// The Color Filter Array pattern of the sensor, from `SETUP.CFA`.
public enum CFAPattern: UInt32, Equatable {
    case none = 0        // monochrome sensor
    case vri = 1         // gbrg / rggb depending on orientation
    case vriV6 = 2        // bggr / grbg
    case bayer = 3        // gbrg
    case bayerFlip = 4    // rggb

    /// Masks off the high-byte multi-head gray/color bits (v6/v6.2 cameras)
    /// before interpreting the low byte as a pattern.
    public init?(rawValue: UInt32) {
        switch rawValue & 0xFF {
        case 0: self = .none
        case 1: self = .vri
        case 2: self = .vriV6
        case 3: self = .bayer
        case 4: self = .bayerFlip
        default: return nil
        }
    }
}
