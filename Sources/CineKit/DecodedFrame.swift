import Foundation

/// A fully-unpacked frame: one raw sensor `UInt16` value per pixel,
/// row-major, in the order it was stored on disk. No demosaicing and no
/// tone-mapping has been applied — that happens in the rendering layer so
/// exposure/LUT adjustments never require re-decoding.
public struct DecodedFrame: Sendable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let pixels: [UInt16]

    /// Whether the consumer must flip rows vertically before display.
    /// True for uncompressed frames (stored bottom-up); false for P10/P12L
    /// (stored top-down) — confirmed empirically, see `P10Unpacker`.
    public let needsVerticalFlip: Bool
}
