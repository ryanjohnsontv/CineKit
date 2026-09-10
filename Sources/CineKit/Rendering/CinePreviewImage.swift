import Foundation
@preconcurrency import Metal
import CoreGraphics

public enum CinePreviewImageError: Error, CustomStringConvertible {
    case noMetalDevice
    case textureCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case imageCreationFailed

    public var description: String {
        switch self {
        case .noMetalDevice:
            return "No Metal device is available in this process."
        case .textureCreationFailed:
            return "Failed to create the offscreen render-target texture."
        case .commandBufferCreationFailed:
            return "Failed to create a Metal command buffer."
        case .blitEncoderCreationFailed:
            return "Failed to create a blit encoder to synchronize the render target."
        case .imageCreationFailed:
            return "Failed to construct a CGImage from the rendered pixels."
        }
    }
}

/// Renders a single, representative frame of a `.cine` file into a `CGImage`
/// — the shared entry point for CinePlayer's two Quick Look app extensions
/// (`CineThumbnailExtension`'s `QLThumbnailProvider` and
/// `CinePreviewExtension`'s `QLPreviewingController`), so neither hand-rolls
/// its own copy of "decode a frame, run it through the GPU debayer/tonemap
/// pipeline, read the pixels back."
///
/// **Reuses the full GPU pipeline** (`CineRenderer`/`Tonemap.metal`) rather
/// than a simpler CPU-side render: this workload is a single static frame,
/// not sustained playback, so decode (sub-millisecond) plus one
/// full-screen-triangle draw stays comfortably inside a Quick Look
/// extension's time/memory budget even with Metal setup's tens-of-ms fixed
/// cost. Reusing the renderer already validated against every bundled
/// sample is far safer than a second debayer implementation that could
/// silently drift from the live app's picture.
///
/// **Fixed rendering parameters, no live-preference sync:** a Quick Look
/// extension is a separate process with no access to `CineDocumentModel`'s
/// in-memory state (last-selected debayer mode, "Color Matrix" toggle).
/// Instead this always renders High Quality (Malvar-He-Cutler) debayer with
/// white balance *and* the post-demosaic color matrix applied (subject to
/// the same `CalibrationPlausibility` veto the live app applies), matching
/// `CineDocumentModel.open(url:)`'s own default for a freshly-opened file —
/// so a preview is color-consistent with the app's default view. A user who
/// has manually toggled "Color Matrix" off in the live app won't see that
/// override reflected here.
public enum CinePreviewImage {
    /// - Parameters:
    ///   - cineFile: the already-opened file to render a frame from.
    ///   - frameIndex: which frame to decode and render. Both Quick Look
    ///     call sites pass `0` — a representative preview doesn't need to
    ///     seek, and frame 0 is always present.
    ///   - device: the Metal device to render with.
    ///   - rendererBundle: forwarded to `CineRenderer.init(device:bundle:)`
    ///     when this call builds its own renderer (`renderer` is `nil`).
    ///     Pass `Bundle.main` from an Xcode app-extension (or app) target —
    ///     unlike a SwiftPM target, it has no `Bundle.module` of its own
    ///     (see `CineMetalView`'s doc comment). `nil` (default) resolves to
    ///     this package's own `Bundle.module`, correct only for a caller
    ///     that links this package directly (`cine-diagnostic`/
    ///     `cine-scrub-bench`), never an Xcode app-extension target.
    ///   - renderer: an already-constructed `CineRenderer` to reuse, or
    ///     `nil` (default) to build a fresh one. Building one loads the
    ///     shader library and compiles two pipeline states — tens of ms,
    ///     trivial once but worth amortizing for a caller invoked once per
    ///     file in a burst (e.g. `ThumbnailProvider` over a whole folder),
    ///     which builds one lazily and passes it here on every call.
    public static func render(
        cineFile: CineFile,
        frameIndex: Int,
        device: MTLDevice,
        rendererBundle: Bundle? = nil,
        renderer: CineRenderer? = nil
    ) throws -> CGImage {
        let frame = try cineFile.decodeFrame(at: frameIndex)
        let rawTexture = try makeFrameTexture(device: device, frame: frame)
        let uniforms = previewUniforms(cineFile: cineFile, frame: frame)

        let renderer = try renderer ?? CineRenderer(device: device, bundle: rendererBundle)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .managed
        guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
            throw CinePreviewImageError.textureCreationFailed
        }

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw CinePreviewImageError.commandBufferCreationFailed
        }

        renderer.render(
            rawTexture: rawTexture,
            uniforms: uniforms,
            into: commandBuffer,
            colorAttachment: targetTexture
        )

        // .managed textures need an explicit synchronize before CPU readback.
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw CinePreviewImageError.blitEncoderCreationFailed
        }
        blitEncoder.synchronize(resource: targetTexture)
        blitEncoder.endEncoding()

        // Plain synchronous waitUntilCompleted(): this function is itself
        // synchronous, so it's callable equally from QLThumbnailProvider's
        // completion-handler API and from
        // QLPreviewingController.preparePreviewOfFile(at:) async throws.
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = frame.width * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * frame.height)
        pixelData.withUnsafeMutableBytes { buffer in
            targetTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0
            )
        }

        return try makeCGImage(bgraPixels: pixelData, width: frame.width, height: frame.height)
    }

    /// See this type's doc comment for the fixed debayer mode + calibration
    /// choice. Still runs the file's raw calibration through the same
    /// `CalibrationPlausibility.vetoedCalibration` veto the live app
    /// applies (with `cameraVersion`, so a vetoed file gets the right
    /// per-camera fallback), so this can't apply a calibration the live app
    /// itself would reject.
    private static func previewUniforms(cineFile: CineFile, frame: DecodedFrame) -> ExposureUniforms {
        let setup = cineFile.setup
        let levels = cineFile.effectiveBlackWhiteLevels
        let cfaPhase = CFAPhase.forCFAPattern(setup.cfa)
        let rawCalibration = setup.colorCalibration ?? .identity
        // Full white balance + color matrix — not forced to identity — the
        // same "Color Matrix on" state `CineDocumentModel.open(url:)` now
        // defaults every freshly-opened file to, subject to the same
        // plausibility veto it applies.
        let calibration = CalibrationPlausibility.vetoedCalibration(
            rawCalibration,
            frame: frame,
            cfaPhase: cfaPhase,
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            cameraVersion: setup.cameraVersion
        )
        return ExposureUniforms(
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            flipVertically: frame.needsVerticalFlip,
            debayerMode: .highQuality,
            cfaPhase: cfaPhase,
            colorCalibration: calibration,
            gamma: setup.fGamma ?? 2.2
        )
    }

    /// Render target is `.bgra8Unorm` (B, G, R, A byte order); `.noneSkipFirst`
    /// + `byteOrder32Little` describes exactly that, treating alpha as
    /// ignorable since output alpha is always 1.0. `shouldInterpolate: true`
    /// (unlike PNG-export call sites) since this image is likely drawn
    /// scaled down for a thumbnail, not written byte-for-byte to a file.
    private static func makeCGImage(bgraPixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        let bytesPerRow = width * 4

        guard let provider = CGDataProvider(data: Data(bgraPixels) as CFData) else {
            throw CinePreviewImageError.imageCreationFailed
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw CinePreviewImageError.imageCreationFailed
        }

        return cgImage
    }
}
