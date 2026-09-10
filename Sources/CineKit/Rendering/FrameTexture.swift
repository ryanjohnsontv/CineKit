import Metal

public enum FrameTextureError: Error, CustomStringConvertible {
    case textureCreationFailed

    public var description: String {
        switch self {
        case .textureCreationFailed:
            return "Failed to create an MTLTexture for the decoded frame."
        }
    }
}

/// Uploads raw `UInt16` sensor pixels (row-major, one value per pixel) into
/// a fresh `.r16Uint` `MTLTexture`, width x height — a raw upload only;
/// tone-mapping happens later, in `CineRenderer`.
///
/// The shared primitive behind both a `.cine` file's own `decodeFrame(at:)`
/// result (via `makeFrameTexture(device:frame:)` below) and a live
/// camera-control client's downloaded-over-the-wire pixel buffer (a plain
/// `[UInt16]`, no `.cine` file involved) — a raw sensor buffer is a raw
/// sensor buffer regardless of where its bytes came from.
public func makeFrameTexture(device: MTLDevice, pixels: [UInt16], width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r16Uint,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared

    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw FrameTextureError.textureCreationFailed
    }

    pixels.withUnsafeBytes { rawBuffer in
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: rawBuffer.baseAddress!,
            bytesPerRow: width * MemoryLayout<UInt16>.size
        )
    }

    return texture
}

/// Convenience overload for a `.cine` file's own decoded frame.
public func makeFrameTexture(device: MTLDevice, frame: DecodedFrame) throws -> MTLTexture {
    try makeFrameTexture(device: device, pixels: frame.pixels, width: frame.width, height: frame.height)
}
