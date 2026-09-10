import Foundation

/// The video viewport's on-screen zoom/pan transform — a vertex-stage-only
/// concern, bound just to `tonemapVertex` at buffer index 2. Layout must
/// exactly mirror the struct of the same name in both copies of
/// `Shaders/Tonemap.metal` (three 4-byte fields, no padding, same order).
///
/// `.identity` is a true no-op: `tonemapVertex`'s UV remap
/// (`center + (uv - center) / scale`) is exactly `uv` at `scale == 1`
/// regardless of `center`, so existing call sites render unchanged by not
/// passing this parameter.
public struct ViewportUniforms: Equatable, Sendable {
    /// Zoom multiplier on top of "fit" (whole frame visible, `scale == 1`).
    /// `2` shows a quarter of the frame's area magnified to fill the
    /// viewport, and so on.
    public var scale: Float
    /// Zoom center, in the frame's normalized (0...1, 0...1) texture space
    /// — `(0.5, 0.5)` is the frame's center. Inert at `scale == 1`.
    public var centerX: Float
    public var centerY: Float

    public static let identity = ViewportUniforms(scale: 1, centerX: 0.5, centerY: 0.5)

    public init(scale: Float, centerX: Float, centerY: Float) {
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
    }
}
